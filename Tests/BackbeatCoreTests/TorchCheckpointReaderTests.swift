import XCTest
@testable import BackbeatCore

/// Contract for the pure-Swift Torch checkpoint reader that replaces any Python /
/// torch dependency for loading the htdemucs `.th` weights. It parses a store-only
/// ZIP + a non-executing, allowlisted protocol-2 pickle VM into a backend-neutral
/// tensor map `name -> (dtype, shape, little-endian bytes)`.
///
/// Two fixture families:
///   • **authentic** `*.pt` files produced by real `torch.save` (see
///     `script/make_checkpoint_fixtures.py`) — parsing these proves the reader
///     agrees with PyTorch's own encoder, not merely with a hand-rolled one;
///   • **hermetic** ZIP/pickle byte streams built in-test (`TorchZip`/`Pickle`)
///     for format variants real `torch.save` (2.8) won't emit but the pinned
///     htdemucs file uses (the older `archive/` prefix, no `byteorder` marker),
///     plus the negative/security cases.
final class TorchCheckpointReaderTests: XCTestCase {

    // MARK: - Authentic torch.save fixtures

    func testReadsFlatFloat32StateDict() throws {
        let checkpoint = try TorchCheckpointReader().read(contentsOf: fixture("flat_f32.pt"))

        // a.weight = [[0,1,2],[3,4,5]] float32 (row-major LE); b.bias = [1.5,-2.5,3.25].
        let weight = try XCTUnwrap(checkpoint.tensors["a.weight"])
        XCTAssertEqual(weight.dtype, .float32)
        XCTAssertEqual(weight.shape, [2, 3])
        XCTAssertEqual(weight.data, Data(hex: "000000000000803f0000004000004040000080400000a040"))

        let bias = try XCTUnwrap(checkpoint.tensors["b.bias"])
        XCTAssertEqual(bias.dtype, .float32)
        XCTAssertEqual(bias.shape, [3])
        XCTAssertEqual(bias.data, Data(hex: "0000c03f000020c000005040"))

        XCTAssertEqual(Set(checkpoint.tensors.keys), ["a.weight", "b.bias"])
    }

    func testReadsFlatFloat16StateDict() throws {
        let checkpoint = try TorchCheckpointReader().read(contentsOf: fixture("flat_f16.pt"))

        let weight = try XCTUnwrap(checkpoint.tensors["a.weight"])
        XCTAssertEqual(weight.dtype, .float16)
        XCTAssertEqual(weight.shape, [2, 3])
        XCTAssertEqual(weight.data, Data(hex: "0000003c0040004200440045"))
        XCTAssertEqual(weight.data.count, weight.elementCount * 2)

        let bias = try XCTUnwrap(checkpoint.tensors["b.bias"])
        XCTAssertEqual(bias.dtype, .float16)
        XCTAssertEqual(bias.shape, [3])
        XCTAssertEqual(bias.data, Data(hex: "003e00c18042"))
    }

    /// The real htdemucs shape: tensors live under a nested `state` dict, alongside
    /// a `klass` global and a `training_args` blob carrying foreign objects (numpy
    /// scalars). The reader must recover the state tensors AND stay inert on the
    /// foreign reducers — never importing/calling them.
    func testNestedBagExposesStateTensorsAndStaysInertOnForeignReduces() throws {
        let checkpoint = try TorchCheckpointReader().read(contentsOf: fixture("nested_bag.pt"))

        // Convenience: the state sub-dict, names stripped of the `state.` prefix.
        let state = checkpoint.tensors(under: "state")
        XCTAssertEqual(Set(state.keys), ["enc.0.conv.weight", "enc.0.conv.bias"])

        let weight = try XCTUnwrap(state["enc.0.conv.weight"])
        XCTAssertEqual(weight.dtype, .float16)
        XCTAssertEqual(weight.shape, [2, 2])
        XCTAssertEqual(weight.data, Data(hex: "003c004000420044"))

        let bias = try XCTUnwrap(state["enc.0.conv.bias"])
        XCTAssertEqual(bias.shape, [2])
        XCTAssertEqual(bias.data, Data(hex: "00bc0038"))

        // The flat map dotted-paths the same tensors under `state.`.
        XCTAssertNotNil(checkpoint.tensors["state.enc.0.conv.weight"])

        // The top-level `klass` resolves to an inert symbolic global, never a call.
        let klass = try XCTUnwrap(checkpoint.root["klass"])
        guard case .global = klass else { return XCTFail("klass should be an inert global, got \(klass)") }

        // `training_args` decodes structurally (a dict) with its numpy scalars left
        // opaque — the reader walked the whole stream without executing anything.
        let trainingArgs = try XCTUnwrap(checkpoint.root["training_args"])
        guard case .dictionary = trainingArgs else { return XCTFail("training_args should be a dict") }
        XCTAssertEqual(checkpoint.root["training_args"]?["flag"]?.boolValue, true)
    }

    // MARK: - Store-only ZIP central-directory walk

    /// torch pads each storage blob to a 64-byte boundary by inflating the LOCAL
    /// file header's extra field. The data offset must therefore come from the
    /// local header, not the central directory (whose extra length differs). A
    /// reader that trusts the central-directory extra length reads from the wrong
    /// offset and silently corrupts every tensor — this pins the local-header path.
    func testExtractsStorageBlobsByCentralDirectoryWalkWithAlignmentPadding() throws {
        let payload0: [UInt8] = [0x00, 0x3c, 0x00, 0x40, 0x00, 0x42, 0x00, 0x44] // [1,2,3,4] f16
        let payload1: [UInt8] = [0x00, 0xbc, 0x00, 0x38]                         // [-1,0.5] f16
        let pkl = Pickle.flatHalfStateDict([
            ("w", key: "0", numel: 4, size: [2, 2]),
            ("b", key: "1", numel: 2, size: [2]),
        ])
        let zip = TorchZip.archive(prefix: "archive", includeByteOrder: true, localExtraPadding: 40, entries: [
            ("archive/data.pkl", pkl),
            ("archive/data/0", payload0),
            ("archive/data/1", payload1),
        ])

        let checkpoint = try TorchCheckpointReader().read(zip)
        XCTAssertEqual(checkpoint.tensors["w"]?.data, Data(payload0))
        XCTAssertEqual(checkpoint.tensors["w"]?.shape, [2, 2])
        XCTAssertEqual(checkpoint.tensors["b"]?.data, Data(payload1))
        XCTAssertEqual(checkpoint.tensors["b"]?.shape, [2])
    }

    /// The pinned htdemucs `.th` uses the older container: the `archive/` prefix and
    /// NO `byteorder` marker. The reader must not depend on the save-path stem prefix
    /// nor require a byteorder entry (little-endian is assumed on the LE-only targets).
    func testHandlesArchivePrefixAndMissingByteOrderMarker() throws {
        let payload: [UInt8] = [0x00, 0x3c, 0x00, 0x40, 0x00, 0x42, 0x00, 0x44]
        let pkl = Pickle.flatHalfStateDict([("w", key: "0", numel: 4, size: [2, 2])])
        let zip = TorchZip.archive(prefix: "archive", includeByteOrder: false, localExtraPadding: 0, entries: [
            ("archive/data.pkl", pkl),
            ("archive/data/0", payload),
        ])

        let checkpoint = try TorchCheckpointReader().read(zip)
        XCTAssertEqual(checkpoint.tensors["w"]?.dtype, .float16)
        XCTAssertEqual(checkpoint.tensors["w"]?.shape, [2, 2])
        XCTAssertEqual(checkpoint.tensors["w"]?.data, Data(payload))
    }

    // MARK: - Error taxonomy

    func testThrowsNotAZipForNonZipMagic() throws {
        let garbage = Data("this is definitely not a zip archive".utf8)
        XCTAssertThrowsError(try TorchCheckpointReader().read(garbage)) { error in
            XCTAssertEqual(error as? TorchCheckpointError, .notAZipArchive)
        }
    }

    func testThrowsForUnsupportedOpcode() throws {
        // PROTO 2, then PERSID ('P' = 0x50), the text persistent-id op the allowlist
        // does not include (only the binary BINPERSID). Must be a clear typed error,
        // never a best-effort guess.
        let badPickle: [UInt8] = [0x80, 0x02, 0x50, 0x0a, 0x2e]
        let zip = TorchZip.archive(prefix: "archive", includeByteOrder: false, localExtraPadding: 0, entries: [
            ("archive/data.pkl", badPickle),
        ])
        XCTAssertThrowsError(try TorchCheckpointReader().read(zip)) { error in
            guard case TorchCheckpointError.unsupportedOpcode(let op) = (error as? TorchCheckpointError ?? .missingPickle) else {
                return XCTFail("expected unsupportedOpcode, got \(error)")
            }
            XCTAssertEqual(op, 0x50)
        }
    }

    func testThrowsMissingStorageWhenBlobAbsent() throws {
        // A pickle that references storage key "7", but no `archive/data/7` entry.
        let pkl = Pickle.flatHalfStateDict([("w", key: "7", numel: 4, size: [2, 2])])
        let zip = TorchZip.archive(prefix: "archive", includeByteOrder: false, localExtraPadding: 0, entries: [
            ("archive/data.pkl", pkl),
        ])
        XCTAssertThrowsError(try TorchCheckpointReader().read(zip)) { error in
            guard case TorchCheckpointError.missingStorage = (error as? TorchCheckpointError ?? .missingPickle) else {
                return XCTFail("expected missingStorage, got \(error)")
            }
        }
    }

    func testThrowsStorageSizeMismatchWhenBlobTooSmall() throws {
        // persid claims numel=4 (8 bytes f16) but the blob only holds 4 bytes.
        let pkl = Pickle.flatHalfStateDict([("w", key: "0", numel: 4, size: [2, 2])])
        let zip = TorchZip.archive(prefix: "archive", includeByteOrder: false, localExtraPadding: 0, entries: [
            ("archive/data.pkl", pkl),
            ("archive/data/0", [0x00, 0x3c, 0x00, 0x40]),
        ])
        XCTAssertThrowsError(try TorchCheckpointReader().read(zip)) { error in
            guard case TorchCheckpointError.storageSizeMismatch = (error as? TorchCheckpointError ?? .missingPickle) else {
                return XCTFail("expected storageSizeMismatch, got \(error)")
            }
        }
    }

    // MARK: - Security: the VM never executes a reducer

    /// A hostile pickle whose top-level value is `os.system("<touch sentinel>")`.
    /// A naive `pickle.loads` would run the command. The allowlisted, non-executing
    /// VM must instead treat the unknown global+reduce as an inert opaque value,
    /// leave no side effect on disk, and still recover the sibling tensor.
    func testDoesNotExecuteHostileGlobalReduce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sentinel = dir.appendingPathComponent("pwned")

        // { "payload": os.system("touch <sentinel>"), "w": <half tensor> }
        var p = Pickle()
        p.proto()
        p.emptyDict()
        p.mark()
        p.binunicode("payload")
        p.global("os", "system")
        p.mark()
        p.binunicode("/bin/sh -c 'touch \(sentinel.path)'")
        p.tuple()
        p.reduce()                       // <- must NOT invoke os.system
        p.binunicode("w")
        Pickle.appendHalfTensor(&p, key: "0", numel: 4, size: [2, 2])
        p.setitems()
        p.stop()

        let payload0: [UInt8] = [0x00, 0x3c, 0x00, 0x40, 0x00, 0x42, 0x00, 0x44]
        let zip = TorchZip.archive(prefix: "archive", includeByteOrder: false, localExtraPadding: 0, entries: [
            ("archive/data.pkl", p.bytes),
            ("archive/data/0", payload0),
        ])

        let checkpoint = try TorchCheckpointReader().read(zip)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path),
                       "the reader executed a pickled reducer — non-executing invariant violated")
        // The hostile value is inert/opaque; the real tensor is still recovered.
        guard case .opaque = try XCTUnwrap(checkpoint.root["payload"]) else {
            return XCTFail("hostile reduce should decode to an inert opaque value")
        }
        XCTAssertEqual(checkpoint.tensors["w"]?.data, Data(payload0))
    }

    // MARK: - Fixture location

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
    }
}

// MARK: - Hermetic ZIP writer (store-only)

/// Builds a minimal store-only ZIP the way `torch.save` lays one out, with control
/// over the archive prefix, the presence of a `byteorder` marker, and — crucially —
/// per-entry LOCAL-header extra padding (torch's 64-byte data alignment), so the
/// reader's local-header offset handling is exercised.
private enum TorchZip {
    static func archive(prefix: String, includeByteOrder: Bool, localExtraPadding: Int,
                        entries: [(name: String, data: [UInt8])]) -> Data {
        var all = entries
        if includeByteOrder { all.append(("\(prefix)/byteorder", Array("little".utf8))) }

        var out = [UInt8]()
        var central = [UInt8]()
        var offsets = [Int]()

        for (name, data) in all {
            let isStorage = name.contains("/data/") || name.hasSuffix("data.pkl")
            let extra = isStorage ? [UInt8](repeating: 0, count: localExtraPadding) : []
            offsets.append(out.count)
            let fn = Array(name.utf8)
            // Local file header.
            out += le32(0x04034b50)
            out += le16(20)            // version needed
            out += le16(0)             // flags
            out += le16(0)             // method: stored
            out += le16(0) + le16(0)   // modtime/date
            out += le32(0)             // crc32 (reader ignores it)
            out += le32(UInt32(data.count)) // compressed size
            out += le32(UInt32(data.count)) // uncompressed size
            out += le16(UInt16(fn.count))
            out += le16(UInt16(extra.count))
            out += fn
            out += extra
            out += data
        }

        var cdSize = 0
        for (index, entry) in all.enumerated() {
            let fn = Array(entry.name.utf8)
            let start = central.count
            central += le32(0x02014b50)
            central += le16(20) + le16(20) // version made by / needed
            central += le16(0)             // flags
            central += le16(0)             // method: stored
            central += le16(0) + le16(0)   // modtime/date
            central += le32(0)             // crc32
            central += le32(UInt32(entry.data.count))
            central += le32(UInt32(entry.data.count))
            central += le16(UInt16(fn.count))
            central += le16(0)             // extra len (0 in the central dir — differs from local)
            central += le16(0)             // comment len
            central += le16(0)             // disk number start
            central += le16(0)             // internal attrs
            central += le32(0)             // external attrs
            central += le32(UInt32(offsets[index]))
            central += fn
            cdSize += central.count - start
        }

        let cdOffset = out.count
        out += central
        // End of central directory.
        out += le32(0x06054b50)
        out += le16(0) + le16(0)                  // disk numbers
        out += le16(UInt16(all.count)) + le16(UInt16(all.count))
        out += le32(UInt32(cdSize))
        out += le32(UInt32(cdOffset))
        out += le16(0)                            // comment length
        return Data(out)
    }

    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
    static func le32(_ v: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) }
    }
}

// MARK: - Hermetic protocol-2 pickle writer

/// A tiny emitter for the exact protocol-2 opcodes the reader must handle. Globals
/// are repeated rather than memoized (the authentic fixtures cover the BINGET memo
/// path), keeping these streams readable.
private struct Pickle {
    var bytes = [UInt8]()

    mutating func proto() { bytes += [0x80, 0x02] }
    mutating func stop() { bytes += [0x2e] }
    mutating func mark() { bytes += [0x28] }
    mutating func tuple() { bytes += [0x74] }
    mutating func tuple2() { bytes += [0x86] }
    mutating func reduce() { bytes += [0x52] }
    mutating func binpersid() { bytes += [0x51] }
    mutating func emptyTuple() { bytes += [0x29] }
    mutating func emptyDict() { bytes += [0x7d] }
    mutating func setitems() { bytes += [0x75] }
    mutating func newfalse() { bytes += [0x89] }

    mutating func binint1(_ n: Int) { bytes += [0x4b, UInt8(n)] }

    mutating func binunicode(_ s: String) {
        let u = Array(s.utf8)
        bytes += [0x58] + TorchZip.le32(UInt32(u.count)) + u
    }

    mutating func global(_ module: String, _ name: String) {
        bytes += [0x63] + Array(module.utf8) + [0x0a] + Array(name.utf8) + [0x0a]
    }

    /// A contiguous `torch._utils._rebuild_tensor_v2(HalfStorage(key,numel), 0, size, stride, False, OrderedDict())`.
    static func appendHalfTensor(_ p: inout Pickle, key: String, numel: Int, size: [Int]) {
        p.global("torch._utils", "_rebuild_tensor_v2")
        p.mark()
        //   persistent-id tuple: ('storage', HalfStorage, key, 'cpu', numel)
        p.mark()
        p.binunicode("storage")
        p.global("torch", "HalfStorage")
        p.binunicode(key)
        p.binunicode("cpu")
        p.binint1(numel)
        p.tuple()
        p.binpersid()
        p.binint1(0)                       // storage_offset
        p.intTuple(size)                   // size
        p.intTuple(contiguousStride(size)) // stride (row-major)
        p.newfalse()                       // requires_grad
        p.global("collections", "OrderedDict"); p.emptyTuple(); p.reduce() // backward hooks
        p.tuple()
        p.reduce()
    }

    mutating func intTuple(_ values: [Int]) {
        if values.count == 2 { binint1(values[0]); binint1(values[1]); tuple2(); return }
        mark(); for v in values { binint1(v) }; tuple()
    }

    /// `collections.OrderedDict()` filled with `name -> half tensor` pairs.
    static func flatHalfStateDict(_ entries: [(name: String, key: String, numel: Int, size: [Int])]) -> [UInt8] {
        var p = Pickle()
        p.proto()
        p.global("collections", "OrderedDict"); p.emptyTuple(); p.reduce()
        p.mark()
        for e in entries {
            p.binunicode(e.name)
            appendHalfTensor(&p, key: e.key, numel: e.numel, size: e.size)
        }
        p.setitems()
        p.stop()
        return p.bytes
    }

    private static func contiguousStride(_ size: [Int]) -> [Int] {
        var stride = [Int](repeating: 1, count: size.count)
        for i in stride.indices.dropLast().reversed() { stride[i] = stride[i + 1] * size[i + 1] }
        return stride
    }
}

// MARK: - Hex helper

private extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
