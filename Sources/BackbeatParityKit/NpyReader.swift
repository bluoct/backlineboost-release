import Foundation
import CryptoKit

/// Dev-only NPY/reference-activation support (`script/export_reference_activations.py`
/// → `.build/reference-activations/…`) shared by the test target and the
/// `BackbeatLayerParity` harness. Reads the float32 `.npy` tensors and the
/// `manifest.json` that pins their shapes and SHA-256 digests. Production targets
/// never depend on this — production code never touches NPY.

public struct NpyTensor {
    public let shape: [Int]
    public let data: [Float]
    /// SHA-256 of the raw payload (the tensor's contiguous row-major little-endian
    /// bytes — the same convention the reference manifest hashes).
    public let payloadSHA256: String
}

public enum NpyReaderError: Error, CustomStringConvertible {
    case notNpy(URL)
    case unsupportedVersion(UInt8)
    case badHeader(String)
    case unsupportedDType(String)
    case fortranOrder
    case truncated(URL)

    public var description: String {
        switch self {
        case .notNpy(let url): return "not an NPY file: \(url.path)"
        case .unsupportedVersion(let v): return "unsupported NPY major version \(v)"
        case .badHeader(let detail): return "malformed NPY header: \(detail)"
        case .unsupportedDType(let d): return "unsupported NPY dtype \(d) (only '<f4' is supported)"
        case .fortranOrder: return "Fortran-ordered NPY tensors are not supported"
        case .truncated(let url): return "NPY payload shorter than its declared shape: \(url.path)"
        }
    }
}

public enum NpyReader {
    /// Parses an NPY v1/v2/v3 file holding a C-ordered little-endian float32 tensor.
    public static func read(_ url: URL) throws -> NpyTensor {
        let raw = try Data(contentsOf: url)
        let magic: [UInt8] = [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59] // \x93NUMPY
        guard raw.count >= 10, Array(raw.prefix(6)) == magic else { throw NpyReaderError.notNpy(url) }

        let major = raw[6]
        let headerStart: Int
        let headerLength: Int
        switch major {
        case 1:
            headerLength = Int(raw[8]) | (Int(raw[9]) << 8)
            headerStart = 10
        case 2, 3:
            guard raw.count >= 12 else { throw NpyReaderError.truncated(url) }
            headerLength = Int(raw[8]) | (Int(raw[9]) << 8) | (Int(raw[10]) << 16) | (Int(raw[11]) << 24)
            headerStart = 12
        default:
            throw NpyReaderError.unsupportedVersion(major)
        }
        guard raw.count >= headerStart + headerLength else { throw NpyReaderError.truncated(url) }
        guard let header = String(data: raw[headerStart..<(headerStart + headerLength)], encoding: .ascii) else {
            throw NpyReaderError.badHeader("header is not ASCII")
        }

        let descr = try quotedValue(after: "'descr':", in: header)
        guard descr == "<f4" else { throw NpyReaderError.unsupportedDType(descr) }
        if header.contains("'fortran_order': True") { throw NpyReaderError.fortranOrder }
        guard header.contains("'fortran_order': False") else {
            throw NpyReaderError.badHeader("missing fortran_order")
        }
        let shape = try shapeValue(in: header)

        let count = shape.reduce(1, *)
        let payloadStart = headerStart + headerLength
        guard raw.count - payloadStart >= count * 4 else { throw NpyReaderError.truncated(url) }
        let payload = raw[payloadStart..<(payloadStart + count * 4)]

        let data = [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            payload.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
            initialized = count
        }
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return NpyTensor(shape: shape, data: data, payloadSHA256: digest)
    }

    private static func quotedValue(after key: String, in header: String) throws -> String {
        guard let keyRange = header.range(of: key) else {
            throw NpyReaderError.badHeader("missing \(key)")
        }
        let tail = header[keyRange.upperBound...]
        guard let open = tail.firstIndex(of: "'") else { throw NpyReaderError.badHeader("unquoted \(key)") }
        let afterOpen = tail.index(after: open)
        guard let close = tail[afterOpen...].firstIndex(of: "'") else {
            throw NpyReaderError.badHeader("unterminated \(key)")
        }
        return String(tail[afterOpen..<close])
    }

    private static func shapeValue(in header: String) throws -> [Int] {
        guard let keyRange = header.range(of: "'shape':") else {
            throw NpyReaderError.badHeader("missing 'shape':")
        }
        let tail = header[keyRange.upperBound...]
        guard let open = tail.firstIndex(of: "("), let close = tail.firstIndex(of: ")"), open < close else {
            throw NpyReaderError.badHeader("missing shape tuple")
        }
        let inner = tail[tail.index(after: open)..<close]
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return try parts.map {
            guard let value = Int($0), value >= 0 else { throw NpyReaderError.badHeader("bad shape element '\($0)'") }
            return value
        }
    }
}

/// The Phase 0 reference-activation tree, resolved from the env gate. Mirrors the
/// `TorchCheckpointReaderParityTests` convention: unset env → the test SKIPS (the
/// default suite stays artifact-free); set-but-broken → hard failure with the
/// regeneration hint (docs/native-engine/baseline-2026-07-07.md §Regeneration).
public struct ReferenceActivations {
    struct Entry: Decodable {
        let complex: Bool
        let dtype: String
        let file: String
        let sha256: String
        let shape: [Int]
    }

    private struct Manifest: Decodable {
        let schema: String
        let activations: [String: Entry]
    }

    public static let environmentKey = "BACKBEAT_REFERENCE_ACTIVATIONS"
    private static let expectedSchema = "htdemucs-activations-v1"

    private let directory: URL
    private let activations: [String: Entry]

    public enum ReferenceError: Error, CustomStringConvertible {
        case missing(String)
        case corrupt(String)

        public var description: String {
            switch self {
            case .missing(let detail), .corrupt(let detail):
                return detail + " — regenerate with: .venv/bin/python script/export_reference_activations.py"
            }
        }
    }

    /// Loads and validates the reference tree at `directory`. Throws (never skips) —
    /// XCTest-side skip semantics live in the test target's `loadOrSkip()` extension;
    /// the BackbeatLayerParity harness calls this directly.
    public static func load(directory: URL) throws -> ReferenceActivations {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ReferenceError.missing("reference manifest \(manifestURL.path) does not exist")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schema == expectedSchema else {
            throw ReferenceError.corrupt("manifest schema '\(manifest.schema)' != '\(expectedSchema)'")
        }
        return ReferenceActivations(directory: directory, activations: manifest.activations)
    }

    /// Every activation name the manifest records — the BackbeatLayerParity harness
    /// uses this for its coverage check (no contract entry may be silently skipped).
    public var activationNames: [String] {
        Array(activations.keys)
    }

    /// Loads a named activation and verifies its shape and SHA-256 against the manifest
    /// before returning it — a silently-corrupt reference must fail loudly, not skew parity.
    public func tensor(_ name: String) throws -> NpyTensor {
        guard let entry = activations[name] else {
            throw ReferenceError.missing("manifest has no activation named '\(name)'")
        }
        let tensor = try NpyReader.read(directory.appendingPathComponent(entry.file))
        guard tensor.shape == entry.shape else {
            throw ReferenceError.corrupt("'\(name)' shape \(tensor.shape) != manifest \(entry.shape)")
        }
        guard tensor.payloadSHA256 == entry.sha256 else {
            throw ReferenceError.corrupt("'\(name)' SHA-256 mismatch (reference bytes corrupted)")
        }
        return tensor
    }
}
