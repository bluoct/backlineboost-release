import Foundation
import MLX
import MLXNN

// Custom HTDemucs engine — the 5-layer cross-domain transformer (upstream
// `CrossTransformerEncoder`, htdemucs configuration: dim 512, 8 heads, FFN 2048,
// norm_first, layer_scale, GELU, sin embeddings, norm_out; `cross_first=false`
// so even layers are self-attention and odd layers cross-attend the branches).
//
// Everything runs batch-first `(B, tokens, C)` — matching upstream, which
// constructs its layers with `batch_first=True`. Two contract-critical layout
// facts, both pinned by the Phase 0 activations:
//  - the freq branch flattens tokens TIME-major (`b c fr t → b (t fr) c`), while
//    the channel up/downsamplers outside this module flatten FREQ-major;
//  - `norm_out` is upstream `MyGroupNorm(1, C)` on batch-first input, i.e. each
//    batch element is normalized over ALL tokens and channels jointly (biased
//    variance) — NOT a per-token LayerNorm.

/// Multi-head attention with torch `nn.MultiheadAttention` semantics: fused
/// `in_proj` weights split into pre-transposed q/k/v projections (kept fused in
/// the checkpoint — converter schema v3 does no splitting), scaled dot-product
/// attention over 8 heads, then `out_proj`.
struct CustomHTDemucsAttention {
    let queryTransposed: MLXArray  // (E, E)
    let keyTransposed: MLXArray
    let valueTransposed: MLXArray
    let queryBias: MLXArray
    let keyBias: MLXArray
    let valueBias: MLXArray
    let outTransposed: MLXArray  // (E, E)
    let outBias: MLXArray
    let heads: Int

    init(store: CustomHTDemucsWeightStore, prefix: String, dim: Int, heads: Int) throws {
        self.heads = heads
        let inWeight = try store.take("\(prefix).in_proj_weight", [3 * dim, dim])
        let inBias = try store.take("\(prefix).in_proj_bias", [3 * dim])
        let weights = split(inWeight, parts: 3, axis: 0)  // torch rows: q, k, v
        queryTransposed = weights[0].transposed(1, 0)
        keyTransposed = weights[1].transposed(1, 0)
        valueTransposed = weights[2].transposed(1, 0)
        let biases = split(inBias, parts: 3, axis: 0)
        queryBias = biases[0]
        keyBias = biases[1]
        valueBias = biases[2]
        outTransposed = try store.takeLinear("\(prefix).out_proj.weight", from: dim, to: dim)
        outBias = try store.take("\(prefix).out_proj.bias", [dim])
    }

    /// `query` (B, Lq, E) attends over `keyValue` (B, Lkv, E); self-attention
    /// passes the same tensor for both. Attention runs through
    /// `preciseAttention` — the fused exact-fp32 `steel_attention` kernel under
    /// the pinned substrate (see `CustomHTDemucsSubstrate`); softmax inside it
    /// runs fp32, matching torch.
    func callAsFunction(query: MLXArray, keyValue: MLXArray) -> MLXArray {
        let (b, lq, e) = (query.dim(0), query.dim(1), query.dim(2))
        let lkv = keyValue.dim(1)
        let headDim = e / heads
        let q = preciseMatmulAdd(query, queryTransposed, queryBias)
            .reshaped([b, lq, heads, headDim]).transposed(0, 2, 1, 3)
        let k = preciseMatmulAdd(keyValue, keyTransposed, keyBias)
            .reshaped([b, lkv, heads, headDim]).transposed(0, 2, 1, 3)
        let v = preciseMatmulAdd(keyValue, valueTransposed, valueBias)
            .reshaped([b, lkv, heads, headDim]).transposed(0, 2, 1, 3)
        let scale = 1.0 / Float(headDim).squareRoot()
        let out = preciseAttention(queries: q, keys: k, values: v, scale: scale)
            .transposed(0, 2, 1, 3).reshaped([b, lq, e])
        return preciseMatmulAdd(out, outTransposed, outBias)
    }
}

private func customLayerNorm(_ x: MLXArray, _ weight: MLXArray, _ bias: MLXArray) -> MLXArray {
    MLXFast.layerNorm(x, weight: weight, bias: bias, eps: customHTDemucsNormEps)
}

/// The shared pre-norm feed-forward block: `linear2(gelu(linear1(x)))`
/// (dropout is inert at inference and omitted).
struct CustomHTDemucsFeedForward {
    let linear1Transposed: MLXArray  // (E, hidden)
    let linear1Bias: MLXArray
    let linear2Transposed: MLXArray  // (hidden, E)
    let linear2Bias: MLXArray

    init(store: CustomHTDemucsWeightStore, prefix: String, dim: Int, hidden: Int) throws {
        linear1Transposed = try store.takeLinear("\(prefix).linear1.weight", from: dim, to: hidden)
        linear1Bias = try store.take("\(prefix).linear1.bias", [hidden])
        linear2Transposed = try store.takeLinear("\(prefix).linear2.weight", from: hidden, to: dim)
        linear2Bias = try store.take("\(prefix).linear2.bias", [dim])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        preciseMatmulAdd(
            gelu(preciseMatmulAdd(x, linear1Transposed, linear1Bias)), linear2Transposed,
            linear2Bias)
    }
}

/// Upstream `MyTransformerEncoderLayer` (norm_first): pre-norm self-attention
/// and feed-forward residuals, each scaled by a LayerScale gamma, then the
/// whole-sequence `norm_out` GroupNorm.
struct CustomHTDemucsSelfLayer {
    let norm1Weight: MLXArray
    let norm1Bias: MLXArray
    let norm2Weight: MLXArray
    let norm2Bias: MLXArray
    let attention: CustomHTDemucsAttention
    let feedForward: CustomHTDemucsFeedForward
    let gamma1: MLXArray
    let gamma2: MLXArray
    let normOutWeight: MLXArray
    let normOutBias: MLXArray

    init(store: CustomHTDemucsWeightStore, prefix: String, dim: Int, hidden: Int, heads: Int) throws {
        norm1Weight = try store.take("\(prefix).norm1.weight", [dim])
        norm1Bias = try store.take("\(prefix).norm1.bias", [dim])
        norm2Weight = try store.take("\(prefix).norm2.weight", [dim])
        norm2Bias = try store.take("\(prefix).norm2.bias", [dim])
        attention = try CustomHTDemucsAttention(
            store: store, prefix: "\(prefix).self_attn", dim: dim, heads: heads)
        feedForward = try CustomHTDemucsFeedForward(
            store: store, prefix: prefix, dim: dim, hidden: hidden)
        gamma1 = try store.take("\(prefix).gamma_1.scale", [dim])
        gamma2 = try store.take("\(prefix).gamma_2.scale", [dim])
        normOutWeight = try store.take("\(prefix).norm_out.weight", [dim])
        normOutBias = try store.take("\(prefix).norm_out.bias", [dim])
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = x
        let h = customLayerNorm(x, norm1Weight, norm1Bias)
        x = x + gamma1 * attention(query: h, keyValue: h)
        x = x + gamma2 * feedForward(customLayerNorm(x, norm2Weight, norm2Bias))
        return customGroupNorm1(x, weight: normOutWeight, bias: normOutBias)
    }
}

/// Upstream `CrossTransformerEncoderLayer` (norm_first): the query branch is
/// normed by `norm1`, the OTHER branch by `norm2` and used as both key and
/// value; `norm3` fronts the feed-forward.
struct CustomHTDemucsCrossLayer {
    let norm1Weight: MLXArray
    let norm1Bias: MLXArray
    let norm2Weight: MLXArray
    let norm2Bias: MLXArray
    let norm3Weight: MLXArray
    let norm3Bias: MLXArray
    let attention: CustomHTDemucsAttention
    let feedForward: CustomHTDemucsFeedForward
    let gamma1: MLXArray
    let gamma2: MLXArray
    let normOutWeight: MLXArray
    let normOutBias: MLXArray

    init(store: CustomHTDemucsWeightStore, prefix: String, dim: Int, hidden: Int, heads: Int) throws {
        norm1Weight = try store.take("\(prefix).norm1.weight", [dim])
        norm1Bias = try store.take("\(prefix).norm1.bias", [dim])
        norm2Weight = try store.take("\(prefix).norm2.weight", [dim])
        norm2Bias = try store.take("\(prefix).norm2.bias", [dim])
        norm3Weight = try store.take("\(prefix).norm3.weight", [dim])
        norm3Bias = try store.take("\(prefix).norm3.bias", [dim])
        attention = try CustomHTDemucsAttention(
            store: store, prefix: "\(prefix).cross_attn", dim: dim, heads: heads)
        feedForward = try CustomHTDemucsFeedForward(
            store: store, prefix: prefix, dim: dim, hidden: hidden)
        gamma1 = try store.take("\(prefix).gamma_1.scale", [dim])
        gamma2 = try store.take("\(prefix).gamma_2.scale", [dim])
        normOutWeight = try store.take("\(prefix).norm_out.weight", [dim])
        normOutBias = try store.take("\(prefix).norm_out.bias", [dim])
    }

    func callAsFunction(_ q: MLXArray, _ k: MLXArray) -> MLXArray {
        var x = q + gamma1
            * attention(
                query: customLayerNorm(q, norm1Weight, norm1Bias),
                keyValue: customLayerNorm(k, norm2Weight, norm2Bias))
        x = x + gamma2 * feedForward(customLayerNorm(x, norm3Weight, norm3Bias))
        return customGroupNorm1(x, weight: normOutWeight, bias: normOutBias)
    }
}

/// The full cross-domain transformer. A class so the (shape-keyed) positional
/// embeddings are computed once and reused across segments.
final class CustomHTDemucsCrossTransformer {
    enum Layer {
        case selfAttention(CustomHTDemucsSelfLayer)
        case cross(CustomHTDemucsCrossLayer)
    }

    let normInWeight: MLXArray
    let normInBias: MLXArray
    let normInTimeWeight: MLXArray
    let normInTimeBias: MLXArray
    let freqLayers: [Layer]
    let timeLayers: [Layer]
    let dim: Int

    private var cachedFreqEmbedding: (height: Int, width: Int, embedding: MLXArray)?
    private var cachedTimeEmbedding: (length: Int, embedding: MLXArray)?

    init(store: CustomHTDemucsWeightStore, dim: Int, hidden: Int, heads: Int, layerCount: Int) throws {
        self.dim = dim
        normInWeight = try store.take("crosstransformer.norm_in.weight", [dim])
        normInBias = try store.take("crosstransformer.norm_in.bias", [dim])
        normInTimeWeight = try store.take("crosstransformer.norm_in_t.weight", [dim])
        normInTimeBias = try store.take("crosstransformer.norm_in_t.bias", [dim])

        func build(_ listName: String) throws -> [Layer] {
            try (0..<layerCount).map { index in
                let prefix = "crosstransformer.\(listName).\(index)"
                // cross_first = false: even layers self-attend, odd layers cross.
                if index % 2 == 0 {
                    return .selfAttention(
                        try CustomHTDemucsSelfLayer(
                            store: store, prefix: prefix, dim: dim, hidden: hidden, heads: heads))
                } else {
                    return .cross(
                        try CustomHTDemucsCrossLayer(
                            store: store, prefix: prefix, dim: dim, hidden: hidden, heads: heads))
                }
            }
        }
        freqLayers = try build("layers")
        timeLayers = try build("layers_t")
    }

    /// x `(B, Fr, T, C)`, xt `(B, L, C)` → same shapes out. Taps fire per layer
    /// (`crosstransformer.layers[_t].<i>`, batch-first token layout — the
    /// contract layout) and for the module's tuple output (`.out0`/`.out1`,
    /// torch layout).
    func callAsFunction(
        x: MLXArray, xt: MLXArray, tap: CustomHTDemucsTap?
    ) -> (x: MLXArray, xt: MLXArray) {
        let (b, fr, t1, c) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3))
        // Tokens flatten TIME-major: "b c fr t -> b (t fr) c" upstream.
        var q = x.transposed(0, 2, 1, 3).reshaped([b, t1 * fr, c])
        q = customLayerNorm(q, normInWeight, normInBias)
        q = q + freqEmbedding(height: fr, width: t1)

        var qt = customLayerNorm(xt, normInTimeWeight, normInTimeBias)
        qt = qt + timeEmbedding(length: xt.dim(1))

        for index in 0..<freqLayers.count {
            switch (freqLayers[index], timeLayers[index]) {
            case let (.selfAttention(freqLayer), .selfAttention(timeLayer)):
                q = freqLayer(q)
                tap?("crosstransformer.layers.\(index)", q)
                qt = timeLayer(qt)
                tap?("crosstransformer.layers_t.\(index)", qt)
            case let (.cross(freqLayer), .cross(timeLayer)):
                // The time branch attends the PRE-update freq tokens (upstream
                // `old_x`), not the tokens the freq layer just produced.
                let previousFreqTokens = q
                q = freqLayer(q, qt)
                tap?("crosstransformer.layers.\(index)", q)
                qt = timeLayer(qt, previousFreqTokens)
                tap?("crosstransformer.layers_t.\(index)", qt)
            default:
                preconditionFailure("freq/time transformer layers must alternate in lockstep")
            }
        }

        let outX = q.reshaped([b, t1, fr, c]).transposed(0, 2, 1, 3)
        tap?("crosstransformer.out0", outX.transposed(0, 3, 1, 2))
        tap?("crosstransformer.out1", xtOut(qt))
        return (outX, qt)
    }

    private func xtOut(_ qt: MLXArray) -> MLXArray {
        qt.transposed(0, 2, 1)
    }

    // MARK: - Positional embeddings (upstream `create_2d_sin_embedding` /
    // `create_sin_embedding`, weight_pos_embed = 1, sin_random_shift = 0).
    // Computed once per shape on the CPU (setup-time, cached — never an
    // audio-length per-sample path) in Double, rounded once to Float.

    private static let maxPeriod = 10000.0

    /// 2-D embedding in flattened `(1, (t fr), C)` token order. First half of
    /// the channels embeds the time position, second half the frequency
    /// position, each interleaved sin (even channel) / cos (odd channel).
    func freqEmbedding(height: Int, width: Int) -> MLXArray {
        if let cached = cachedFreqEmbedding,
            cached.height == height, cached.width == width {
            return cached.embedding
        }
        let half = dim / 2
        let pairCount = half / 2
        // div_term = exp(arange(0, half, 2) * -(log(maxPeriod) / half))
        let div = (0..<pairCount).map { exp(Double(2 * $0) * -(log(Self.maxPeriod) / Double(half))) }
        var data = [Float](repeating: 0, count: width * height * dim)
        for t in 0..<width {
            for i in 0..<pairCount {
                let angle = Double(t) * div[i]
                let (sinT, cosT) = (Float(sin(angle)), Float(cos(angle)))
                for f in 0..<height {
                    let base = (t * height + f) * dim
                    data[base + 2 * i] = sinT
                    data[base + 2 * i + 1] = cosT
                }
            }
            for f in 0..<height {
                let base = (t * height + f) * dim + half
                for i in 0..<pairCount {
                    let angle = Double(f) * div[i]
                    data[base + 2 * i] = Float(sin(angle))
                    data[base + 2 * i + 1] = Float(cos(angle))
                }
            }
        }
        let embedding = MLXArray(data, [1, width * height, dim])
        cachedFreqEmbedding = (height, width, embedding)
        return embedding
    }

    /// 1-D embedding `(1, L, C)`: `cat([cos(phase), sin(phase)])` — cos in the
    /// FIRST half — with `phase = pos / maxPeriod^(j / (half - 1))`.
    func timeEmbedding(length: Int) -> MLXArray {
        if let cached = cachedTimeEmbedding, cached.length == length {
            return cached.embedding
        }
        let half = dim / 2
        let scales = (0..<half).map { pow(Self.maxPeriod, Double($0) / Double(half - 1)) }
        var data = [Float](repeating: 0, count: length * dim)
        for p in 0..<length {
            let base = p * dim
            for j in 0..<half {
                let phase = Double(p) / scales[j]
                data[base + j] = Float(cos(phase))
                data[base + half + j] = Float(sin(phase))
            }
        }
        let embedding = MLXArray(data, [1, length, dim])
        cachedTimeEmbedding = (length, embedding)
        return embedding
    }
}
