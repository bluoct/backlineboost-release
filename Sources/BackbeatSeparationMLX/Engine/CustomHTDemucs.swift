import Foundation
import MLX
import MLXNN

/// The custom HTDemucs model graph (custom-engine charter Phase 2, D1-A) —
/// purpose-written for the one architecture this app ships (the `955717e8`
/// htdemucs checkpoint): 4-layer frequency + time encoders/decoders with DConv
/// residuals, frequency embedding, 512-channel bottleneck up/downsampling, and
/// the 5-layer cross-domain transformer.
///
/// Scope boundary (charter): this type is the segment-level forward pass ONLY —
/// STFT/iSTFT and CaC packing live in `BackbeatCore.HTDemucsDSP` (Phase 1), and
/// segmentation/overlap-add scheduling, cancellation, and `StemSeparating`
/// integration are Phase 3. Inputs and outputs use torch layouts at the
/// boundary so they compose directly with `HTDemucsDSP`'s packed buffers and
/// the Phase 0 reference activations:
///
///   forward(magnitude: (B, 2·audioChannels, 2048, T)   // packCaC output
///           waveform:  (B, audioChannels, L))          // the raw segment
///   → (spectral: (B, sources·2·audioChannels, 2048, T) // mask, unpackCaC-ready
///      waveform: (B, sources·audioChannels, L))        // time-branch estimate
///
/// The model's normalization/denormalization (mean/std of each branch input,
/// torch's unbiased std) happens INSIDE forward, exactly like upstream.
public final class CustomHTDemucs {
    // htdemucs hyperparameters, pinned by the Phase 0 reference manifest.
    public static let sources = 4
    public static let audioChannels = 2
    public static let frequencyBins = 2048  // nfft 4096 → 2048 after Nyquist drop
    static let channelWidths = [48, 96, 192, 384]
    static let bottomChannels = 512
    static let transformerLayers = 5
    static let transformerHeads = 8
    static let transformerHidden = 2048  // hidden_scale 4
    static let freqEmbScale: Float = 0.2
    static let freqEmbBoost: Float = 10  // emb_scale, applied in ScaledEmbedding.forward
    static let normStdEps: Float = 1e-5  // the `1e-5 + std` in upstream forward

    private let encoders: [CustomHTDemucsEncoderLayer]
    private let timeEncoders: [CustomHTDemucsEncoderLayer]
    private let decoders: [CustomHTDemucsDecoderLayer]
    private let timeDecoders: [CustomHTDemucsDecoderLayer]
    private let frequencyEmbedding: MLXArray  // (512, 48), already ×emb_scale
    private let upsampler: (weight: MLXArray, bias: MLXArray)
    private let upsamplerTime: (weight: MLXArray, bias: MLXArray)
    private let downsampler: (weight: MLXArray, bias: MLXArray)
    private let downsamplerTime: (weight: MLXArray, bias: MLXArray)
    private let transformer: CustomHTDemucsCrossTransformer

    /// Builds the graph from a converter-schema-v3 weight map
    /// (`HTDemucsWeightAdapter.convertForCustomEngine`): torch parameter names
    /// verbatim, conv weights in MLX channels-last layout, fp32. Every tensor is
    /// shape-checked and the map must be consumed exactly (533 tensors).
    public init(weights: [String: MLXArray]) throws {
        let store = CustomHTDemucsWeightStore(weights)
        let widths = Self.channelWidths

        encoders = try (0..<widths.count).map { index in
            try CustomHTDemucsEncoderLayer(
                store: store, name: "encoder.\(index)", freq: true,
                from: index == 0 ? 2 * Self.audioChannels : widths[index - 1],
                to: widths[index])
        }
        timeEncoders = try (0..<widths.count).map { index in
            try CustomHTDemucsEncoderLayer(
                store: store, name: "tencoder.\(index)", freq: false,
                from: index == 0 ? Self.audioChannels : widths[index - 1],
                to: widths[index])
        }
        decoders = try (0..<widths.count).map { index in
            let last = index == widths.count - 1
            return try CustomHTDemucsDecoderLayer(
                store: store, name: "decoder.\(index)", freq: true, last: last,
                from: widths[widths.count - 1 - index],
                to: last ? Self.sources * 2 * Self.audioChannels : widths[widths.count - 2 - index])
        }
        timeDecoders = try (0..<widths.count).map { index in
            let last = index == widths.count - 1
            return try CustomHTDemucsDecoderLayer(
                store: store, name: "tdecoder.\(index)", freq: false, last: last,
                from: widths[widths.count - 1 - index],
                to: last ? Self.sources * Self.audioChannels : widths[widths.count - 2 - index])
        }

        // ScaledEmbedding.forward is `embedding(frs) * scale`, and the graph
        // always looks up every row in order (frs = arange(Fr)), so the module
        // output IS the boosted table.
        frequencyEmbedding = try store.take(
            "freq_emb.embedding.weight", [Self.frequencyBins / 4, widths[0]]) * Self.freqEmbBoost

        func sampler(_ name: String, from cIn: Int, to cOut: Int) throws -> (MLXArray, MLXArray) {
            (
                try store.takeMatmul1x1("\(name).weight", from: cIn, to: cOut, spatialRank: 1),
                try store.take("\(name).bias", [cOut])
            )
        }
        let top = widths[widths.count - 1]
        upsampler = try sampler("channel_upsampler", from: top, to: Self.bottomChannels)
        upsamplerTime = try sampler("channel_upsampler_t", from: top, to: Self.bottomChannels)
        downsampler = try sampler("channel_downsampler", from: Self.bottomChannels, to: top)
        downsamplerTime = try sampler("channel_downsampler_t", from: Self.bottomChannels, to: top)

        transformer = try CustomHTDemucsCrossTransformer(
            store: store, dim: Self.bottomChannels, hidden: Self.transformerHidden,
            heads: Self.transformerHeads, layerCount: Self.transformerLayers)

        try store.finish()
    }

    /// One segment-level forward pass. `magnitude` is `HTDemucsDSP.packCaC`
    /// output shaped `(B, 4, 2048, T)`; `waveform` is the matching raw segment
    /// `(B, 2, L)`. Returns the CaC mask `(B, 16, 2048, T)` (feed to
    /// `HTDemucsDSP.unpackCaC` → `inverseSpectrogram`) and the time-branch
    /// estimate `(B, 8, L)`; the final stems are their sum, computed by the
    /// caller. `tap` receives every Phase 0 contract activation when set.
    public func forward(
        magnitude: MLXArray, waveform: MLXArray, tap: CustomHTDemucsTap? = nil
    ) -> (spectral: MLXArray, waveform: MLXArray) {
        // To channels-last, then normalize per batch element over all other
        // axes — torch `std` is UNBIASED (ddof 1), and epsilon is added to the
        // deviation, not the variance.
        var x = magnitude.transposed(0, 2, 3, 1)  // (B, Fr, T, 4)
        let specAxes = [1, 2, 3]
        let specMean = mean(x, axes: specAxes, keepDims: true)
        let specStd = sqrt(variance(x, axes: specAxes, keepDims: true, ddof: 1))
        x = (x - specMean) / (specStd + Self.normStdEps)

        var xt = waveform.transposed(0, 2, 1)  // (B, L, 2)
        let timeAxes = [1, 2]
        let timeMean = mean(xt, axes: timeAxes, keepDims: true)
        let timeStd = sqrt(variance(xt, axes: timeAxes, keepDims: true, ddof: 1))
        xt = (xt - timeMean) / (timeStd + Self.normStdEps)

        var saved: [MLXArray] = []
        var savedTime: [MLXArray] = []
        var timeLengths: [Int] = []
        for index in 0..<encoders.count {
            timeLengths.append(xt.dim(1))
            xt = timeEncoders[index](xt, tap: tap)
            savedTime.append(xt)
            x = encoders[index](x, tap: tap)
            if index == 0 {
                // The contract's `encoder.0` entry (tapped inside the layer) is
                // PRE-embedding; the skip connection carries the composed value.
                tap?("freq_emb", frequencyEmbedding)
                x = x + Self.freqEmbScale
                    * frequencyEmbedding.reshaped(
                        [1, frequencyEmbedding.dim(0), 1, frequencyEmbedding.dim(1)])
            }
            saved.append(x)
        }

        // 1×1 channel bottleneck resampling. The torch-layout taps flatten
        // FREQ-major ("b c f t -> b c (f t)"), unlike the transformer's
        // time-major tokens — both pinned by the Phase 0 activations.
        x = preciseMatmulAdd(x, upsampler.weight, upsampler.bias)
        tap?("channel_upsampler", Self.torchFlattened(x))
        xt = preciseMatmulAdd(xt, upsamplerTime.weight, upsamplerTime.bias)
        tap?("channel_upsampler_t", xt.transposed(0, 2, 1))

        (x, xt) = transformer(x: x, xt: xt, tap: tap)

        x = preciseMatmulAdd(x, downsampler.weight, downsampler.bias)
        tap?("channel_downsampler", Self.torchFlattened(x))
        xt = preciseMatmulAdd(xt, downsamplerTime.weight, downsamplerTime.bias)
        tap?("channel_downsampler_t", xt.transposed(0, 2, 1))

        for index in 0..<decoders.count {
            (x, _) = decoders[index](x, skip: saved.removeLast(), length: 0, tap: tap)
            (xt, _) = timeDecoders[index](
                xt, skip: savedTime.removeLast(), length: timeLengths.removeLast(), tap: tap)
        }

        // Denormalize with the input statistics (scalar per batch element) and
        // return torch layouts for the DSP seam.
        let spectral = (x * specStd + specMean).transposed(0, 3, 1, 2)
        let timeEstimate = (xt * timeStd + timeMean).transposed(0, 2, 1)
        return (spectral, timeEstimate)
    }

    /// `(B, Fr, T, C)` → torch `(B, C, Fr·T)` (freq-major flatten).
    private static func torchFlattened(_ x: MLXArray) -> MLXArray {
        x.transposed(0, 3, 1, 2).reshaped([x.dim(0), x.dim(3), x.dim(1) * x.dim(2)])
    }
}
