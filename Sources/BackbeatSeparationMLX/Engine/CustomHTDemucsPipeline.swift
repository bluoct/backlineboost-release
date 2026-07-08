import Accelerate
import BackbeatCore
import Foundation
import MLX
import MLXFFT

/// The window-level composition of the custom engine (charter Phase 3): raw
/// centered windows → `CustomHTDemucs.forward` → combined stems, i.e. the
/// upstream `HTDemucs.forward` seam epilogue written from the demucs 4.0.1
/// Python reference (G6):
///
///   z = _spec(mix); mag = _magnitude(z)            // HTDemucsDSP, CPU/vDSP
///   (mask, xt) = graph forward                     // CustomHTDemucs, MLX
///   zout = _mask(z, mask)   // cac=true: pure CaC reassembly, z unused
///   x = _ispec(zout, L); out = xt + x              // HTDemucsDSP, CPU/vDSP
///
/// Both the `CustomHTDemucsSeparator` segment loop and the `BackbeatLayerParity`
/// harness run THIS type, so the 62-block parity contract exercises the
/// production composition path, not a harness-only copy of it.
///
/// Batching: every scheduled window is exactly `HTDemucsScheduler.segmentLength`
/// samples (the centered-padding pin), so windows stack into one uniform
/// `(B, C, L)` batch — one MLX upload and one copy-out per output head per
/// batch. Not `Sendable`: MLX arrays are confined to the owning actor (§2.2/A3);
/// only `[Float]` crosses.
public final class CustomHTDemucsPipeline {
    public typealias SeamTap = (_ name: String, _ shape: [Int], _ values: [Float]) -> Void

    public let model: CustomHTDemucs

    /// Phase 6 dev-only profiling sink (`BACKBEAT_PROFILE_STAGES=1`): receives
    /// (stage, seconds) for every stage of every `separateWindows` call. Set by
    /// the owning separator; nil in production (a nil sink costs one branch).
    var profileSink: ((String, Double) -> Void)?

    private func timed<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        guard let profileSink else { return try body() }
        let clock = ContinuousClock()
        let start = clock.now
        let result = try body()
        let elapsed = clock.now - start
        profileSink(
            stage,
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        return result
    }

    /// Pins the exact-fp32 substrate and runs the truncation canary before the
    /// model sees a single GEMM (see `CustomHTDemucsSubstrate`): a truncating
    /// substrate is a loud build error, never silent numeric drift.
    public init(model: CustomHTDemucs) throws {
        CustomHTDemucsSubstrate.pinExactFP32()
        try CustomHTDemucsSubstrate.verifyExactGEMM()
        self.model = model
    }

    /// The production (tap-free) forward + epilogue, MLX-compiled: fuses the
    /// graph's many elementwise kernels (norms, GELU, GLU, residuals,
    /// LayerScale, the normalize/denormalize scalars) AND runs the whole
    /// `_ispec` epilogue on the GPU — Nyquist re-pad, iSTFT, window²-envelope
    /// division, center trim, `out = xt + x` — returning the final combined
    /// stems `(B, S·C, L)` so the CPU touches one small tensor per batch.
    /// Every scheduled window has the same shape (the centered-padding pin),
    /// so this compiles exactly once per process (mlx retraces on a shape
    /// change). The parity harness's tapped forward stays eager (taps cannot
    /// cross a compile boundary) and keeps the CPU epilogue for the
    /// `_mask`/`_ispec` seam entries; the production path's final output is
    /// checked against the same `output` contract entry by `BackbeatLayerParity`
    /// and end to end by the bench's SI-SDR record.
    private lazy var compiledProduction: @Sendable ([MLXArray]) -> [MLXArray] =
        MLX.compile { [self] inputs in
            let waveform = inputs[0]
            let magnitude = gpuSpectrogram(waveform: waveform)
            let (spectral, timeEstimate) = model.forward(
                magnitude: magnitude, waveform: waveform, tap: nil)
            return [gpuEpilogue(spectral: spectral, timeEstimate: timeEstimate)]
        }

    /// Shape-keyed constants for the GPU input spectrogram: the Core-owned
    /// gather-index matrix (reflect pads + frame trim + hop framing as ONE
    /// `take`) and the 1/√nfft-scaled analysis window (torch stft
    /// normalized=true; mlx rfft is the plain unnormalized sum).
    private var spectrogramCache: (length: Int, indices: MLXArray, window: MLXArray)?

    private func spectrogramConstants(length: Int) -> (indices: MLXArray, window: MLXArray) {
        if let cached = spectrogramCache, cached.length == length {
            return (cached.indices, cached.window)
        }
        let nfft = HTDemucsDSP.nfft
        let le = (length + HTDemucsDSP.hopLength - 1) / HTDemucsDSP.hopLength
        let scale = Float(1.0 / Double(nfft).squareRoot())
        let window = HTDemucsDSP.periodicHannWindow(nfft).map { $0 * scale }
        let cache = (
            length: length,
            indices: MLXArray(
                HTDemucsDSP.spectrogramGatherIndices(length: length), [le, nfft]),
            window: MLXArray(window, [nfft])
        )
        spectrogramCache = cache
        return (cache.indices, cache.window)
    }

    /// The upstream `_spec` + `_magnitude` input path as MLX graph ops (runs
    /// inside `compiledProduction`): one gather frames the reflect-padded
    /// signal, then windowed rfft, Nyquist drop, and the CaC channel packing —
    /// `(B, C, L)` waveform → `(B, 2C, Fr, T)` packed magnitude, matching
    /// `HTDemucsDSP.spectrogram` + `packCaC` (the eager parity path keeps the
    /// CPU pair; the production output is gate-checked against the same
    /// contract).
    private func gpuSpectrogram(waveform: MLXArray) -> MLXArray {
        let bins = HTDemucsDSP.bins
        let b = waveform.dim(0)
        let channels = waveform.dim(1)
        let length = waveform.dim(2)
        let constants = spectrogramConstants(length: length)
        let frames = take(waveform, constants.indices, axis: -1)  // (B, C, T, nfft)
        let spectra = MLXFFT.rfft(frames * constants.window, axis: -1)  // (B, C, T, bins+1)
        let cac = spectra.view(dtype: .float32)  // (B, C, T, 2·(bins+1)) interleaved re/im
            .reshaped([b, channels, frames.dim(2), bins + 1, 2])[
                0..., 0..., 0..., 0 ..< bins]  // Nyquist drop, torch `_spec` semantics
        // (B, C, T, Fr, 2) → (B, C, 2, Fr, T) → (B, 2C, Fr, T): packCaC's
        // [channel][re, im] plane order.
        return cac.transposed(0, 1, 4, 3, 2).reshaped([b, 2 * channels, bins, frames.dim(2)])
    }

    /// Shape-keyed constants for the GPU epilogue, mirrored from the CPU path
    /// (`HTDemucsDSP` owns the numeric knowledge): the √nfft-scaled periodic
    /// Hann synthesis window, the DC-imaginary kill mask, and the
    /// `inverseEnvelope` divisor slice.
    private var epilogueCache:
        (frames: Int, length: Int, window: MLXArray, dcMask: MLXArray, envelope: MLXArray)?

    private func epilogueConstants(
        frames: Int, length: Int
    ) -> (window: MLXArray, dcMask: MLXArray, envelope: MLXArray) {
        if let cached = epilogueCache, cached.frames == frames, cached.length == length {
            return (cached.window, cached.dcMask, cached.envelope)
        }
        let nfft = HTDemucsDSP.nfft
        // vDSP's packed inverse computes the plain Hermitian sum (N× numpy's
        // backward-normalized irfft), so the CPU path scales by 1/√N; mlx irfft
        // IS backward-normalized, so the GPU path scales by N·(1/√N) = √N —
        // folded into the synthesis window exactly like the CPU path folds its
        // 1/√N.
        let scale = Float(Double(nfft).squareRoot())
        let window = HTDemucsDSP.periodicHannWindow(nfft).map { $0 * scale }
        var dcMask = [Float](repeating: 1, count: HTDemucsDSP.bins)
        dcMask[0] = 0  // c2r ignores DC.im (torch/vDSP semantics) — kill it explicitly.
        let cache = (
            frames: frames, length: length,
            window: MLXArray(window, [nfft]),
            dcMask: MLXArray(dcMask, [HTDemucsDSP.bins, 1]),
            envelope: MLXArray(HTDemucsDSP.inverseEnvelope(frames: frames, length: length), [length])
        )
        epilogueCache = cache
        return (cache.window, cache.dcMask, cache.envelope)
    }

    /// The upstream `_ispec` + `out = xt + x` epilogue as MLX graph ops (runs
    /// inside `compiledProduction`): CaC mask `(B, S·2C, Fr, T)` → complex
    /// spectra → irfft (whose 2048 → 2049 zero-pad IS the Nyquist re-append) →
    /// ×synthesis window → overlap-add (nfft = 4·hop, so a frame decomposes
    /// into 4 hop-groups that tile without self-overlap — 4 padded adds, no
    /// scatter) → the same `inverseOutputStart` trim and window²-envelope
    /// division as `HTDemucsDSP.inverseSpectrogram` → + the time-branch
    /// estimate.
    private func gpuEpilogue(spectral: MLXArray, timeEstimate: MLXArray) -> MLXArray {
        let sources = CustomHTDemucs.sources
        let channels = CustomHTDemucs.audioChannels
        let bins = HTDemucsDSP.bins
        let nfft = HTDemucsDSP.nfft
        let hop = HTDemucsDSP.hopLength
        let b = spectral.dim(0)
        let frames = spectral.dim(3)
        let length = timeEstimate.dim(2)
        let constants = epilogueConstants(frames: frames, length: length)

        // (B, S·2C, Fr, T) → (B, S, C, 2, Fr, T) → complex (B, S, C, T, Fr).
        let cac = spectral.reshaped([b, sources, channels, 2, bins, frames])
        let re = cac[0..., 0..., 0..., 0]
        let im = cac[0..., 0..., 0..., 1] * constants.dcMask
        let interleaved = stacked([re, im], axis: -1)  // (B, S, C, Fr, T, 2)
            .transposed(0, 1, 2, 4, 3, 5)  // (B, S, C, T, Fr, 2)
        let spectra = interleaved.contiguous().view(dtype: .complex64).squeezed(axis: -1)

        // iSTFT frames: irfft(n: nfft) zero-pads the dropped Nyquist bin back
        // (2048 → 2049), then the scaled synthesis window applies.
        let timeFrames = MLXFFT.irfft(spectra, n: nfft, axis: -1) * constants.window  // (B,S,C,T,nfft)

        // Overlap-add. Source frame f lands at (f+2)·hop (two zero frames pad
        // each side upstream; they carry no signal — only envelope energy,
        // already baked into the divisor). Hop-group c of all frames tiles
        // [(2+c)·hop, (2+c)·hop + frames·hop) without self-overlap.
        let olaLength = (frames + 5) * hop
        let groups = timeFrames.reshaped([b, sources, channels, frames, 4, hop])
        var ola: MLXArray?
        for c in 0..<4 {
            let group = groups[0..., 0..., 0..., 0..., c].reshaped(
                [b, sources, channels, frames * hop])
            let shifted = padded(
                group,
                widths: [
                    [0, 0], [0, 0], [0, 0],
                    [(2 + c) * hop, olaLength - (2 + c) * hop - frames * hop],
                ])
            ola = ola.map { $0 + shifted } ?? shifted
        }

        let start = HTDemucsDSP.inverseOutputStart
        let emitted = ola![0..., 0..., 0..., start ..< (start + length)] / constants.envelope
        return (emitted + timeEstimate.reshaped([b, sources, channels, length]))
            .reshaped([b, sources * channels, length])
    }

    /// Production entry: separate a batch of raw windows staged as ONE flat
    /// `[window][channel][sample]` buffer (the separator extracts windows
    /// straight into it — no per-window arrays, no re-flatten), handing each
    /// window's combined stems to `consume` as a zero-copy view of the
    /// evaluated GPU output (valid only inside the callback) — the caller
    /// accumulates straight from it, so a window's stems never round-trip
    /// through an intermediate `[Float]`. The raw waveform is the only upload:
    /// the analysis spectrogram is computed on the GPU inside the compiled
    /// production function (Phase 6).
    public func separateWindows(
        flat: [Float], windowCount: Int, channels: Int, sampleLength: Int,
        consume: (_ window: Int, _ combined: UnsafeBufferPointer<Float>) -> Void
    ) throws {
        guard windowCount > 0, channels > 0, sampleLength > 0,
              flat.count == windowCount * channels * sampleLength else {
            throw HTDemucsDSPError.invalidShape(
                "flat window buffer count \(flat.count) for "
                    + "\(windowCount)×\(channels)×\(sampleLength)")
        }
        let waveform = timed("upload") {
            MLXArray(flat, [windowCount, channels, sampleLength])
        }
        runCompiledProduction(waveform: waveform, windowCount: windowCount, consume: consume)
    }

    /// Run the compiled graph and hand each window's combined stems to
    /// `consume` as a zero-copy view. The per-window SLICE before the view is
    /// load-bearing (recorded measurement, 2026-07-07): compiled functions
    /// recycle their output buffers across calls, and a zero-copy CPU view of
    /// the compiled output itself measured 3.22 s / +41 MB peak vs 2.38 s —
    /// the small slice decouples the CPU consumer from the recycled buffer.
    private func runCompiledProduction(
        waveform: MLXArray, windowCount: Int,
        consume: (_ window: Int, _ combined: UnsafeBufferPointer<Float>) -> Void
    ) {
        let combined = timed("graph-build") { compiledProduction([waveform])[0] }
        timed("gpu-eval") { MLX.eval(combined) }
        timed("collect") {
            for window in 0..<windowCount {
                let slice = combined[window]
                let view = slice.asData(access: .noCopyIfContiguous)
                view.data.withUnsafeBytes { raw in
                    consume(window, raw.bindMemory(to: Float.self))
                }
            }
        }
    }

    /// The FULL production path on a raw window (the `BackbeatLayerParity`
    /// production check): the same compiled GPU-spectrogram + forward +
    /// GPU-epilogue the segment loop runs, on the parity contract's input —
    /// its return is compared against the `output` contract entry.
    public func productionWindow(waveform: [Float], sampleLength: Int) throws -> [Float] {
        let channels = CustomHTDemucs.audioChannels
        guard waveform.count == channels * sampleLength else {
            throw HTDemucsDSPError.invalidShape(
                "waveform count \(waveform.count) for \(sampleLength) samples")
        }
        let waveformArray = MLXArray(waveform, [1, channels, sampleLength])
        var result: [Float] = []
        runCompiledProduction(waveform: waveformArray, windowCount: 1) { _, buffer in
            result = Array(buffer)
        }
        return result
    }

    /// Parity entry (`BackbeatLayerParity`): one window whose packed magnitude is
    /// supplied externally — the harness feeds the reference `_magnitude` so
    /// per-block graph parity is isolated from DSP fp-noise. `graphTap` receives
    /// every module activation; `seamTap` receives the `_mask` and `_ispec` seam
    /// values (torch layouts); the return value is the `output` contract entry.
    public func separateWindow(
        packedMagnitude: [Float], frames: Int,
        waveform: [Float], sampleLength: Int,
        graphTap: CustomHTDemucsTap? = nil,
        seamTap: SeamTap? = nil
    ) throws -> [Float] {
        let channels = CustomHTDemucs.audioChannels
        guard packedMagnitude.count == 2 * channels * HTDemucsDSP.bins * frames else {
            throw HTDemucsDSPError.invalidShape(
                "packed magnitude count \(packedMagnitude.count) for \(frames) frames")
        }
        guard waveform.count == channels * sampleLength else {
            throw HTDemucsDSPError.invalidShape(
                "waveform count \(waveform.count) for \(sampleLength) samples")
        }
        let magnitude = MLXArray(packedMagnitude, [1, 2 * channels, HTDemucsDSP.bins, frames])
        let waveformArray = MLXArray(waveform, [1, channels, sampleLength])
        return try compose(
            magnitude: magnitude, waveform: waveformArray, windowCount: 1,
            frames: frames, sampleLength: sampleLength, graphTap: graphTap, seamTap: seamTap)[0]
    }

    // MARK: - Shared composition

    private func compose(
        magnitude: MLXArray, waveform: MLXArray, windowCount: Int,
        frames: Int, sampleLength: Int,
        graphTap: CustomHTDemucsTap?, seamTap: SeamTap?
    ) throws -> [[Float]] {
        precondition(seamTap == nil || windowCount == 1, "seam taps are a single-window facility")
        // Eager forward + CPU epilogue: the parity path (taps fire per block;
        // the `_mask`/`_ispec` seams come from the CPU DSP). Production runs
        // `runCompiledProduction` instead.
        let (spectral, timeEstimate) = timed("graph-build") {
            model.forward(magnitude: magnitude, waveform: waveform, tap: graphTap)
        }

        // MLX.eval materializes the lazy tensor graph (NOT code evaluation):
        // one fused GPU evaluation for the whole batch. The copy-out below is
        // then per WINDOW (GPU-side slice), so the CPU transient is one
        // window's tensors, never the whole batch's (the G3 memory shape).
        timed("gpu-eval") { MLX.eval(spectral, timeEstimate) }

        let sources = CustomHTDemucs.sources
        let channels = CustomHTDemucs.audioChannels
        let bins = HTDemucsDSP.bins
        var results: [[Float]] = []
        results.reserveCapacity(windowCount)
        var seamMask: [Float] = []
        var seamFreq: [Float] = []

        let plane = bins * frames
        for window in 0..<windowCount {
            // Zero-copy views into the evaluated GPU output buffers (unified
            // memory): no [Float] materialization of the window's tensors at
            // all. Valid while the slice arrays stay alive (this block). A
            // non-contiguous slice would silently degrade to a copy — same
            // semantics, so correctness never depends on the view.
            let spectralSlice = spectral[window]  // (S·2C, Fr, T)
            let timeSlice = timeEstimate[window]  // (S·C, L)
            let (spectralData, timeData) = timed("view") {
                (
                    spectralSlice.asData(access: .noCopyIfContiguous),
                    timeSlice.asData(access: .noCopyIfContiguous)
                )
            }
            var combined = [Float](repeating: 0, count: sources * channels * sampleLength)
            try spectralData.data.withUnsafeBytes { rawSpectral in
                try timeData.data.withUnsafeBytes { rawTime in
                    let spectralAll = rawSpectral.bindMemory(to: Float.self)
                    let timeAll = rawTime.bindMemory(to: Float.self)
                    for source in 0..<sources {
                        // Per-source unpack: the CPU transient is one source's
                        // planes, not the whole window's.
                        let sourceBase = source * channels * 2 * plane
                        let sourceView = UnsafeBufferPointer(
                            rebasing: spectralAll[sourceBase ..< sourceBase + channels * 2 * plane])
                        let sourceSpectrogram = try timed("unpack") {
                            try HTDemucsDSP.unpackCaC(
                                sourceView, sources: 1, channels: channels, bins: bins, frames: frames)[0]
                        }
                        if seamTap != nil {
                            seamMask += sourceSpectrogram.data
                        }
                        let freqChannels = try timed("istft") {
                            try HTDemucsDSP.inverseSpectrogram(sourceSpectrogram, length: sampleLength)
                        }
                        for (channelIndex, freqChannel) in freqChannels.enumerated() {
                            if seamTap != nil {
                                seamFreq += freqChannel
                            }
                            // out = xt + x, one bulk add per (source, channel) row.
                            let row = source * channels + channelIndex
                            combined.withUnsafeMutableBufferPointer { out in
                                freqChannel.withUnsafeBufferPointer { freq in
                                    vDSP_vadd(
                                        freq.baseAddress!, 1,
                                        timeAll.baseAddress! + row * sampleLength, 1,
                                        out.baseAddress! + row * sampleLength, 1,
                                        vDSP_Length(sampleLength))
                                }
                            }
                        }
                    }
                }
            }
            results.append(combined)
        }

        if let seamTap {
            seamTap("_mask", [windowCount, sources, channels, bins, frames, 2], seamMask)
            seamTap("_ispec", [windowCount, sources, channels, sampleLength], seamFreq)
        }
        return results
    }
}
