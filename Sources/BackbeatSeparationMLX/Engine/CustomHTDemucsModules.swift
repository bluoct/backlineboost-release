import Foundation
import MLX
import MLXNN

// Custom HTDemucs engine — model-graph building blocks (custom-engine charter
// Phase 2; architecture D1-A/G6).
//
// Written for this app from the documented contract: the upstream demucs 4.0.1
// architecture semantics (read as the reference spec), the Phase 0 activation
// contract (docs/native-engine/baseline-2026-07-07.md — 63 entries named by
// upstream `named_modules()`), and the hyperparameters pinned in the reference
// manifest. HTDemucs-only: everything the htdemucs checkpoint cannot exercise
// (empty/merge layers, MultiWrap bands, Wiener filtering, LSTM/attention DConv
// modes, non-CaC masking) is omitted by construction, not ported.
//
// Layout convention: MLX convolutions are channels-LAST, so the engine keeps
//   freq branch   (B, Fr, T, C)  — conv2d over (H = frequency, W = STFT frames)
//   time branch   (B, L, C)      — conv1d over samples
//   transformer   (B, tokens, C)
// end to end, and produces torch-layout tensors only inside parity taps (a nil
// tap costs nothing — charter efficiency rule). A pleasant consequence: the
// freq-branch DConv batching (torch permute+reshape to [B·Fr, C, T]) is a plain
// contiguous reshape here, with no data movement.
//
// Weights are keyed by torch `named_parameters()` names verbatim (converter
// schema v3, `HTDemucsWeightAdapter.convertForCustomEngine`): fp32 values with
// 3-D/4-D conv weights pre-permuted to MLX layout, no renames.

/// Instrumentation hook for the layer-parity harness: receives each contract
/// entry's name (upstream demucs 4.0.1 `named_modules()` naming, tuple outputs
/// as `<name>.out<i>`) and its value in torch layout.
public typealias CustomHTDemucsTap = (String, MLXArray) -> Void

public enum CustomHTDemucsError: Error, LocalizedError {
    case missingTensor(String)
    case shapeMismatch(name: String, expected: [Int], got: [Int])
    case unconsumedTensors([String])
    case truncatingGEMMSubstrate(measured: Float, expected: Float)

    public var errorDescription: String? {
        switch self {
        case .missingTensor(let name):
            return "custom HTDemucs build: required tensor '\(name)' is missing from the converted weights"
        case let .shapeMismatch(name, expected, got):
            return "custom HTDemucs build: tensor '\(name)' has shape \(got), expected \(expected)"
        case .unconsumedTensors(let names):
            return "custom HTDemucs build: \(names.count) converted tensor(s) were never consumed "
                + "(schema drift?): \(names.prefix(8).joined(separator: ", "))\(names.count > 8 ? ", …" : "")"
        case let .truncatingGEMMSubstrate(measured, expected):
            return "custom HTDemucs build: the GPU GEMM substrate is truncating fp32 inputs "
                + "(canary measured \(measured), expected \(expected)) — the MLX_ENABLE_TF32=0 pin "
                + "did not take effect before the first GEMM dispatch"
        }
    }
}

/// Consumes a `[torch name: MLXArray]` weight map, validating the shape of every
/// pull and requiring the map to be fully consumed once the graph is built — a
/// renamed, missing, or leftover tensor is a loud build error naming the tensor
/// (review R4/R12 lesson), never a silent numeric drift.
final class CustomHTDemucsWeightStore {
    private var remaining: [String: MLXArray]

    init(_ tensors: [String: MLXArray]) {
        remaining = tensors
    }

    func take(_ name: String, _ shape: [Int]) throws -> MLXArray {
        guard let tensor = remaining.removeValue(forKey: name) else {
            throw CustomHTDemucsError.missingTensor(name)
        }
        guard tensor.shape == shape else {
            throw CustomHTDemucsError.shapeMismatch(name: name, expected: shape, got: tensor.shape)
        }
        return tensor
    }

    /// A 1×1 convolution used as a channel mix: validate the conv-layout shape,
    /// then squeeze the singleton spatial axes and pre-transpose once so the
    /// forward pass is a single `matmul(x, w)` in channels-last layout.
    func takeMatmul1x1(_ name: String, from cIn: Int, to cOut: Int, spatialRank: Int) throws -> MLXArray {
        let shape = [cOut] + Array(repeating: 1, count: spatialRank) + [cIn]
        return try take(name, shape).reshaped([cOut, cIn]).transposed(1, 0)
    }

    /// A torch `nn.Linear` weight (`[out, in]`, untouched by the converter),
    /// pre-transposed once for `matmul(x, w)`.
    func takeLinear(_ name: String, from cIn: Int, to cOut: Int) throws -> MLXArray {
        try take(name, [cOut, cIn]).transposed(1, 0)
    }

    func finish() throws {
        guard remaining.isEmpty else {
            throw CustomHTDemucsError.unconsumedTensors(remaining.keys.sorted())
        }
    }
}

/// torch's default norm epsilon (GroupNorm and LayerNorm alike).
let customHTDemucsNormEps: Float = 1e-5

// MARK: - The exact-fp32 substrate contract (Phase 6)
//
// **Recorded measurement (Phase 2, 2026-07-07, M5 Pro, mlx-swift 0.30.6):**
// MLX's default GPU GEMM truncates its *inputs* to ≈11 mantissa bits
// (TF32-style NAX tensor-core path; fp32 accumulation) — measured relL2 ≈ 4e-4
// vs the CPU stream across all probed shapes, far outside the layer-parity
// gates. Phase 2 compensated with Veltkamp-split GEMM trios (`A·B ≈ Ah·Bh +
// (Ah·Bl + Al·Bh)`), a measured ~3.2× cost on every GEMM-bound op.
//
// **Recorded measurement (Phase 6, 2026-07-07, same machine/pin):** the
// truncating path is *opt-out*. mlx-swift 0.30.6 gates every NAX kernel family
// (steel_gemm, steel_attention, quantized) on `env::enable_tf32()`
// (`mlx/utils.h`, env var `MLX_ENABLE_TF32`, default ON); with it OFF, fp32
// matmul/SDPA take the classic exact simdgroup kernels, and the conv family
// either routes through the same steel_matmul (explicit/im2col paths) or was
// exact already (there are no NAX conv kernels). Under the pinned-off substrate,
// single raw ops reproduce full fp32 quality end to end: LayerParity 62/62 PASS
// with worst max|Δ| = 8.68e-5 at `crosstransformer.layers.3` (the compensated
// record was 8.0e-5), per-stem SI-SDR unchanged, and the 105 s fixture's
// wall-clock drops 9.03 s → 2.98 s (batch 1, release). The Veltkamp stack is
// therefore deleted; `CustomHTDemucsSubstrate` pins the env var and the model
// build verifies the substrate with a truncation canary so a regression (an
// mlx upgrade, a dispatch change, a caller racing the env latch) fails loudly
// at build, never as silent numeric drift.
//
// The `precise*` functions remain the engine's ONLY numeric entry points
// (standing rule): they now document + enforce the exact-substrate contract
// rather than compensate for its absence.

enum CustomHTDemucsSubstrate {
    /// Route fp32 GEMM/SDPA to the exact (non-truncating) kernels. mlx-swift
    /// latches `MLX_ENABLE_TF32` on the first GEMM dispatch (a C++ function
    /// static), so this must run before any matmul in the process — it is
    /// called from `CustomHTDemucsSeparator.init` and
    /// `CustomHTDemucsPipeline.init`, which front every engine path (app,
    /// bench, parity harness). `verifyExactGEMM()` backstops the ordering.
    static func pinExactFP32() {
        setenv("MLX_ENABLE_TF32", "0", 1)
    }

    /// Truncation canary: a 64×64 fp32 GEMM whose inputs need more than 11
    /// mantissa bits. Exact kernels return 64·(1 + 2⁻¹⁶) = 64 + 2⁻¹⁰ exactly
    /// (every term and the sum are fp32-representable); the truncating NAX path
    /// rounds the inputs to 1.0 and returns 64. Throws if the substrate
    /// truncates, so a build can never silently produce ~4e-4 numerics.
    static func verifyExactGEMM() throws {
        let k = 64
        let element: Float = 1 + 0x1p-16
        let a = MLXArray([Float](repeating: element, count: k * k), [k, k])
        let b = MLXArray([Float](repeating: 1, count: k * k), [k, k])
        let got = matmul(a, b)[0, 0].item(Float.self)
        let expected = Float(k) * element
        guard abs(got - expected) <= expected * 1e-6 else {
            throw CustomHTDemucsError.truncatingGEMMSubstrate(measured: got, expected: expected)
        }
    }
}

/// Exact fp32 matrix multiply — the engine's ONLY matmul entry point
/// (see the substrate contract above).
func preciseMatmul(_ a: MLXArray, _ b: MLXArray) -> MLXArray {
    matmul(a, b)
}

/// `x·W + bias` fused into the GEMM epilogue (`addmm` — the same TF32-gated
/// steel path as `preciseMatmul`, exact under the pinned substrate): one
/// kernel instead of GEMM + a broadcast elementwise add over the output.
func preciseMatmulAdd(_ a: MLXArray, _ b: MLXArray, _ bias: MLXArray) -> MLXArray {
    addMM(bias, a, b)
}

/// Fused scaled-dot-product attention — the engine's ONLY attention entry
/// point. Under the pinned substrate this is the classic (exact) fp32
/// `steel_attention` kernel; the (B, heads, Lq, Lkv) score tensor never
/// materializes. Input `(B, heads, L, headDim)`; output the same layout
/// (the mlx-swift doc comment's `(B, L, heads, headDim)` claim is stale —
/// measured 2026-07-07, a layout scramble that LayerParity catches at 17.96
/// max|Δ| if trusted).
func preciseAttention(
    queries: MLXArray, keys: MLXArray, values: MLXArray, scale: Float
) -> MLXArray {
    MLX.scaledDotProductAttention(queries: queries, keys: keys, values: values, scale: scale, mask: nil)
}

// Exact fp32 convolutions — the conv-family entry points (substrate contract
// above; the direct 3×3 — Winograd-eligible — decoder rewrites measured at
// fp-noise under the pinned substrate, so the Phase 2 row decomposition that
// dodged the truncating Winograd GEMM stage is gone with the Veltkamp stack).

func preciseConv1d(
    _ x: MLXArray, _ w: MLXArray, stride: Int = 1, padding: Int = 0, dilation: Int = 1
) -> MLXArray {
    conv1d(x, w, stride: stride, padding: padding, dilation: dilation)
}

func preciseConv2d(
    _ x: MLXArray, _ w: MLXArray, stride: IntOrPair = 1, padding: IntOrPair = 0
) -> MLXArray {
    conv2d(x, w, stride: stride, padding: padding)
}

func preciseConvTransposed1d(_ x: MLXArray, _ w: MLXArray, stride: Int) -> MLXArray {
    convTransposed1d(x, w, stride: stride)
}

func preciseConvTransposed2d(_ x: MLXArray, _ w: MLXArray, stride: IntOrPair) -> MLXArray {
    convTransposed2d(x, w, stride: stride)
}

/// `nn.GroupNorm(num_groups: 1)` in channels-last layout: per batch element,
/// normalize over ALL non-batch axes with the biased variance (torch GroupNorm
/// semantics), then apply the per-channel affine. Serves both the DConv norms
/// (input `(N, L, C)`) and the transformer's `norm_out` (`MyGroupNorm` on
/// batch-first tokens — same reduction set).
func customGroupNorm1(_ x: MLXArray, weight: MLXArray, bias: MLXArray) -> MLXArray {
    let axes = Array(1..<x.ndim)
    let mu = mean(x, axes: axes, keepDims: true)
    let v = variance(x, axes: axes, keepDims: true)
    return (x - mu) * rsqrt(v + customHTDemucsNormEps) * weight + bias
}

/// One DConv residual sub-layer (upstream `DConv`, htdemucs configuration:
/// kernel 3, compress 8, GroupNorm(1), GELU, GLU, LayerScale; dilation 2^d).
/// Sequential slot indices match the checkpoint names:
/// `.0` dilated conv, `.1` GroupNorm, `.3` 1×1 expansion, `.4` GroupNorm,
/// `.6` LayerScale (`.2` GELU and `.5` GLU carry no weights).
struct CustomHTDemucsDConvLayer {
    let conv1Weight: MLXArray  // (hidden, 3, C)
    let conv1Bias: MLXArray
    let gn1Weight: MLXArray
    let gn1Bias: MLXArray
    let conv2Transposed: MLXArray  // (hidden, 2C) — 1×1 expansion as matmul
    let conv2Bias: MLXArray
    let gn2Weight: MLXArray
    let gn2Bias: MLXArray
    let layerScale: MLXArray  // (C)
    let dilation: Int

    init(store: CustomHTDemucsWeightStore, prefix: String, channels: Int, depthIndex: Int) throws {
        let hidden = channels / 8  // dconv_comp 8
        dilation = 1 << depthIndex
        conv1Weight = try store.take("\(prefix).\(depthIndex).0.weight", [hidden, 3, channels])
        conv1Bias = try store.take("\(prefix).\(depthIndex).0.bias", [hidden])
        gn1Weight = try store.take("\(prefix).\(depthIndex).1.weight", [hidden])
        gn1Bias = try store.take("\(prefix).\(depthIndex).1.bias", [hidden])
        conv2Transposed = try store.takeMatmul1x1(
            "\(prefix).\(depthIndex).3.weight", from: hidden, to: 2 * channels, spatialRank: 1)
        conv2Bias = try store.take("\(prefix).\(depthIndex).3.bias", [2 * channels])
        gn2Weight = try store.take("\(prefix).\(depthIndex).4.weight", [2 * channels])
        gn2Bias = try store.take("\(prefix).\(depthIndex).4.bias", [2 * channels])
        layerScale = try store.take("\(prefix).\(depthIndex).6.scale", [channels])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var y = preciseConv1d(x, conv1Weight, padding: dilation, dilation: dilation) + conv1Bias
        y = customGroupNorm1(y, weight: gn1Weight, bias: gn1Bias)
        y = gelu(y)
        y = preciseMatmulAdd(y, conv2Transposed, conv2Bias)
        y = customGroupNorm1(y, weight: gn2Weight, bias: gn2Bias)
        y = glu(y, axis: -1)  // torch GLU dim=1 (channels) == last axis here
        return x + y * layerScale
    }
}

/// The 2-deep DConv residual branch. Input/output `(N, L, C)`; freq layers pass
/// `(B·Fr, T, C)` (the torch permute+reshape collapses to a contiguous reshape
/// in channels-last layout).
struct CustomHTDemucsDConv {
    let layers: [CustomHTDemucsDConvLayer]

    init(store: CustomHTDemucsWeightStore, prefix: String, channels: Int) throws {
        layers = try (0..<2).map {
            try CustomHTDemucsDConvLayer(
                store: store, prefix: prefix + ".layers", channels: channels, depthIndex: $0)
        }
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = x
        for layer in layers { x = layer(x) }
        return x
    }
}

/// Upstream `HEncLayer` in the htdemucs configuration: conv (kernel 8, stride 4,
/// pad 2 on the convolved axis) → GELU → DConv residual → 1×1 rewrite + GLU.
/// `norm_starts=4` with depth 4 makes every norm Identity, and no layer is
/// `empty`, so neither exists here (HTDemucs-only). The tap fires on the module
/// output — for `encoder.0` that is PRE-frequency-embedding, exactly like the
/// reference hook (the embedding is composed outside, in the graph forward).
struct CustomHTDemucsEncoderLayer {
    let name: String
    let freq: Bool
    let convWeight: MLXArray  // freq (C, 8, 1, Cin) / time (C, 8, Cin)
    let convBias: MLXArray
    let dconv: CustomHTDemucsDConv
    let rewriteTransposed: MLXArray  // (C, 2C)
    let rewriteBias: MLXArray

    init(store: CustomHTDemucsWeightStore, name: String, freq: Bool, from cIn: Int, to cOut: Int) throws {
        self.name = name
        self.freq = freq
        convWeight = try store.take(
            "\(name).conv.weight", freq ? [cOut, 8, 1, cIn] : [cOut, 8, cIn])
        convBias = try store.take("\(name).conv.bias", [cOut])
        dconv = try CustomHTDemucsDConv(store: store, prefix: "\(name).dconv", channels: cOut)
        // context_enc = 0 → the encoder rewrite is a genuine 1×1.
        rewriteTransposed = try store.takeMatmul1x1(
            "\(name).rewrite.weight", from: cOut, to: 2 * cOut, spatialRank: freq ? 2 : 1)
        rewriteBias = try store.take("\(name).rewrite.bias", [2 * cOut])
    }

    /// Freq: `(B, Fr, T, C)`. Time: `(B, L, C)`, right-padded with zeros to a
    /// stride multiple first (upstream `HEncLayer.forward`).
    func callAsFunction(_ x: MLXArray, tap: CustomHTDemucsTap?) -> MLXArray {
        var y: MLXArray
        if freq {
            y = preciseConv2d(x, convWeight, stride: [4, 1], padding: [2, 0]) + convBias
        } else {
            var x = x
            let remainder = x.dim(1) % 4
            if remainder != 0 {
                x = padded(x, widths: [[0, 0], [0, 4 - remainder], [0, 0]])
            }
            y = preciseConv1d(x, convWeight, stride: 4, padding: 2) + convBias
        }
        y = gelu(y)
        if freq {
            let (b, fr, t, c) = (y.dim(0), y.dim(1), y.dim(2), y.dim(3))
            var yd = y.reshaped([b * fr, t, c])
            yd = dconv(yd)
            tap?("\(name).dconv", yd.transposed(0, 2, 1))
            y = yd.reshaped([b, fr, t, c])
        } else {
            y = dconv(y)
            tap?("\(name).dconv", y.transposed(0, 2, 1))
        }
        let z = glu(preciseMatmulAdd(y, rewriteTransposed, rewriteBias), axis: -1)
        tap?(name, freq ? z.transposed(0, 3, 1, 2) : z.transposed(0, 2, 1))
        return z
    }
}

/// Upstream `HDecLayer` in the htdemucs configuration: skip add → rewrite + GLU
/// (context 1 → a 3×3 conv in the freq branch, a 3-tap conv in the time branch)
/// → DConv residual → transposed conv (kernel 8, stride 4) → pad trim → GELU
/// unless `last`. Returns `(z, pre)` exactly like upstream; the taps mirror the
/// contract's `<name>.out0` / `<name>.out1` tuple entries.
struct CustomHTDemucsDecoderLayer {
    let name: String
    let freq: Bool
    let last: Bool
    let rewriteWeight: MLXArray  // freq (2C, 3, 3, C) / time (2C, 3, C)
    let rewriteBias: MLXArray
    let dconv: CustomHTDemucsDConv
    let convTrWeight: MLXArray  // freq (Cout, 8, 1, Cin) / time (Cout, 8, Cin)
    let convTrBias: MLXArray

    /// `pad = kernel_size // 4` — the amount trimmed back off after the
    /// transposed conv (frequency axis) or used as the output offset (time).
    private static let pad = 2

    init(
        store: CustomHTDemucsWeightStore, name: String, freq: Bool, last: Bool,
        from cIn: Int, to cOut: Int
    ) throws {
        self.name = name
        self.freq = freq
        self.last = last
        rewriteWeight = try store.take(
            "\(name).rewrite.weight", freq ? [2 * cIn, 3, 3, cIn] : [2 * cIn, 3, cIn])
        rewriteBias = try store.take("\(name).rewrite.bias", [2 * cIn])
        dconv = try CustomHTDemucsDConv(store: store, prefix: "\(name).dconv", channels: cIn)
        convTrWeight = try store.take(
            "\(name).conv_tr.weight", freq ? [cOut, 8, 1, cIn] : [cOut, 8, cIn])
        convTrBias = try store.take("\(name).conv_tr.bias", [cOut])
    }

    /// Freq: `(B, Fr, T, C)`, `length` unused (the trim is the fixed frequency
    /// pad). Time: `(B, L, C)`, trimmed to `[pad, pad + length)`.
    func callAsFunction(
        _ x: MLXArray, skip: MLXArray, length: Int, tap: CustomHTDemucsTap?
    ) -> (z: MLXArray, pre: MLXArray) {
        var y = x + skip
        if freq {
            y = glu(preciseConv2d(y, rewriteWeight, padding: [1, 1]) + rewriteBias, axis: -1)
            let (b, fr, t, c) = (y.dim(0), y.dim(1), y.dim(2), y.dim(3))
            var yd = y.reshaped([b * fr, t, c])
            yd = dconv(yd)
            tap?("\(name).dconv", yd.transposed(0, 2, 1))
            y = yd.reshaped([b, fr, t, c])
        } else {
            y = glu(preciseConv1d(y, rewriteWeight, padding: 1) + rewriteBias, axis: -1)
            y = dconv(y)
            tap?("\(name).dconv", y.transposed(0, 2, 1))
        }
        var z: MLXArray
        if freq {
            z = preciseConvTransposed2d(y, convTrWeight, stride: [4, 1]) + convTrBias
            z = z[0..., Self.pad ..< (z.dim(1) - Self.pad)]
        } else {
            z = preciseConvTransposed1d(y, convTrWeight, stride: 4) + convTrBias
            z = z[0..., Self.pad ..< (Self.pad + length)]
        }
        if !last {
            z = gelu(z)
        }
        tap?("\(name).out0", freq ? z.transposed(0, 3, 1, 2) : z.transposed(0, 2, 1))
        tap?("\(name).out1", freq ? y.transposed(0, 3, 1, 2) : y.transposed(0, 2, 1))
        return (z, y)
    }
}
