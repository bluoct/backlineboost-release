import BackbeatCore
import Foundation
import MLX

// HTDemucsWeightAdapter — converts Meta's official htdemucs `.th` state dict
// (read by BackbeatCore's `TorchCheckpointReader` into a backend-neutral
// `[name: TorchTensor]` map) into the custom engine's `[name: MLXArray]` map
// (converter schema v3, charter Phase 2): torch `named_parameters()` names
// VERBATIM (533 → 533 — no bag prefix, no `.conv.` wrappers, no fused
// `in_proj` splits), fp32 values, with only the 3-D/4-D conv weights permuted
// to MLX channels-last layout. Weight names, reference-activation names, and
// upstream module names all coincide, so parity work maps 1:1. Weights are
// emitted as float32 (the `.th` stores float16; fp32 maximizes parity —
// architecture G1).
//
// (Task 7, amendment D1↔D2 coupling: the reader is backend-neutral; only this
// adapter is backend-specific. The vendored port's v2 layout — `model_0.` bag
// prefix, `.conv.` wrappers, fused-`in_proj` splits, embedded config JSON —
// died with the port at the Phase 5 cut-over.)
enum HTDemucsWeightAdapter {
    /// The htdemucs `.th` for the `955717e8` bag holds 533 float16 tensors.
    static let expectedSourceTensorCount = 533

    enum AdapterError: Error, CustomStringConvertible {
        case unexpectedDType(name: String, dtype: String)
        case tensorCountMismatch(expected: Int, got: Int)

        var description: String {
            switch self {
            case let .unexpectedDType(name, dtype):
                return "htdemucs weight '\(name)' has unexpected dtype \(dtype) (expected float16/float32)"
            case let .tensorCountMismatch(expected, got):
                return "converted \(got) MLX tensors, expected \(expected) — the .th layout does not match htdemucs"
            }
        }
    }

    // MARK: - Custom-engine layout (converter schema v3)

    /// Convert the torch state dict into the custom engine's layout: identical
    /// tensor names, fp32, 3-D/4-D conv weights permuted to MLX channels-last
    /// (`.conv_tr.` transposed-conv weights use the transposed-conv permutation).
    /// The htdemucs checkpoint has no non-conv tensors of rank ≥ 3, so the rank
    /// test is exact. Consumed by `CustomHTDemucs.init(weights:)`, which
    /// shape-checks every tensor against the graph.
    static func convertForCustomEngine(state: [String: TorchTensor]) throws -> [String: MLXArray] {
        var out = [String: MLXArray](minimumCapacity: state.count)
        for (name, tensor) in state {
            let shape = tensor.shape
            let values = try floats(from: tensor, name: name)
            if name.hasSuffix(".weight"), shape.count == 3 || shape.count == 4 {
                let isConvTranspose = name.contains(".conv_tr.")
                let perm: [Int] = shape.count == 3
                    ? (isConvTranspose ? [1, 2, 0] : [0, 2, 1])
                    : (isConvTranspose ? [1, 2, 3, 0] : [0, 2, 3, 1])
                let (data, outShape) = transpose(values, shape: shape, perm: perm)
                out[name] = MLXArray(data, outShape)
            } else {
                out[name] = MLXArray(values, shape)
            }
        }
        guard out.count == expectedSourceTensorCount else {
            throw AdapterError.tensorCountMismatch(expected: expectedSourceTensorCount, got: out.count)
        }
        return out
    }

    // MARK: - Helpers

    /// The tensor `name` is threaded through so a bad-dtype failure identifies
    /// which of the 533 tensors is wrong (review finding R12).
    private static func floats(from tensor: TorchTensor, name: String) throws -> [Float] {
        switch tensor.dtype {
        case .float16:
            return tensor.data.withUnsafeBytes { raw in
                raw.bindMemory(to: Float16.self).map { Float($0) }
            }
        case .float32:
            return tensor.data.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float32.self))
            }
        default:
            throw AdapterError.unexpectedDType(name: name, dtype: tensor.dtype.rawValue)
        }
    }

    /// Row-major strided transpose: `out` has shape `perm.map { shape[$0] }`.
    private static func transpose(
        _ data: [Float], shape: [Int], perm: [Int]
    ) -> (data: [Float], shape: [Int]) {
        let rank = shape.count
        let outShape = perm.map { shape[$0] }
        var inStride = [Int](repeating: 1, count: rank)
        for i in stride(from: rank - 2, through: 0, by: -1) { inStride[i] = inStride[i + 1] * shape[i + 1] }
        var outStride = [Int](repeating: 1, count: rank)
        for i in stride(from: rank - 2, through: 0, by: -1) { outStride[i] = outStride[i + 1] * outShape[i + 1] }
        var out = [Float](repeating: 0, count: data.count)
        out.withUnsafeMutableBufferPointer { dst in
            data.withUnsafeBufferPointer { src in
                var idx = [Int](repeating: 0, count: rank)
                for o in 0 ..< data.count {
                    var rem = o
                    for i in 0 ..< rank { idx[i] = rem / outStride[i]; rem %= outStride[i] }
                    var inOff = 0
                    for i in 0 ..< rank { inOff += idx[i] * inStride[perm[i]] }
                    dst[o] = src[inOff]
                }
            }
        }
        return (out, outShape)
    }
}
