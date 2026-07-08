import XCTest
import CryptoKit
@testable import BackbeatCore

/// Gated end-to-end parity: prove the pure-Swift `TorchCheckpointReader` extracts
/// the real htdemucs weights **byte-identically** to PyTorch. This is the gate that
/// retires the task's core risk — silent byte-level weight corruption — because a
/// hand-built fixture can only prove the reader agrees with itself.
///
/// Opt-in (skipped by default, so `swift test` stays weights-free):
///   1. download the pinned `.th` (Task 5 does this; or `curl` it dev-side);
///   2. `.venv/bin/python script/export_weights_reference.py <weights.th>`
///      writes `<weights.th>.reference.json` (per-tensor dtype/shape/sha256);
///   3. run with the weights path exported:
///      `BACKBEAT_WEIGHTS="<weights.th>" swift test --filter TorchCheckpointReaderParityTests`
///
/// `BACKBEAT_WEIGHTS_REF` overrides the reference path (default: `<weights>.reference.json`).
final class TorchCheckpointReaderParityTests: XCTestCase {

    func testReaderIsByteIdenticalToPyTorchOnRealWeights() throws {
        let env = ProcessInfo.processInfo.environment
        guard let weightsPath = env["BACKBEAT_WEIGHTS"], !weightsPath.isEmpty else {
            throw XCTSkip("Set BACKBEAT_WEIGHTS to the htdemucs .th to run the gated parity test.")
        }
        let weightsURL = URL(fileURLWithPath: weightsPath)

        let referencePath = env["BACKBEAT_WEIGHTS_REF"] ?? (weightsPath + ".reference.json")
        guard FileManager.default.fileExists(atPath: referencePath) else {
            return XCTFail("""
                BACKBEAT_WEIGHTS is set but the byte-level reference is missing at \(referencePath).
                Generate it first: .venv/bin/python script/export_weights_reference.py "\(weightsPath)"
                """)
        }
        let reference = try JSONDecoder().decode(Reference.self,
                                                 from: Data(contentsOf: URL(fileURLWithPath: referencePath)))

        let checkpoint = try TorchCheckpointReader().read(contentsOf: weightsURL)
        let state = checkpoint.tensors(under: "state")

        XCTAssertEqual(state.count, reference.tensor_count, "tensor count differs from PyTorch")
        XCTAssertEqual(Set(state.keys), Set(reference.tensors.keys), "tensor name set differs from PyTorch")

        var mismatches: [String] = []
        for (name, expected) in reference.tensors {
            guard let tensor = state[name] else {
                mismatches.append("\(name): missing from reader output"); continue
            }
            if tensor.dtype.rawValue != expected.dtype {
                mismatches.append("\(name): dtype \(tensor.dtype.rawValue) != \(expected.dtype)")
            }
            if tensor.shape != expected.shape {
                mismatches.append("\(name): shape \(tensor.shape) != \(expected.shape)")
            }
            if tensor.data.count != expected.nbytes {
                mismatches.append("\(name): nbytes \(tensor.data.count) != \(expected.nbytes)")
            }
            let digest = SHA256.hash(data: tensor.data).map { String(format: "%02x", $0) }.joined()
            if digest != expected.sha256 {
                mismatches.append("\(name): sha256 mismatch (byte-level corruption)")
            }
        }
        XCTAssertTrue(mismatches.isEmpty,
                      "reader diverged from PyTorch on \(mismatches.count) tensor(s):\n"
                        + mismatches.prefix(20).joined(separator: "\n"))
    }

    private struct Reference: Decodable {
        let tensor_count: Int
        let tensors: [String: Entry]
        struct Entry: Decodable {
            let dtype: String
            let shape: [Int]
            let nbytes: Int
            let sha256: String
        }
    }
}
