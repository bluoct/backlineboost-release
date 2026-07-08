import XCTest
@testable import BackbeatCore

/// Adversarial / robustness coverage for `TorchCheckpointReader` — the paths a
/// well-formed happy checkpoint never exercises but a corrupt or hostile input can.
/// The contract is "treat the input as hostile": every one of these must produce a
/// typed `TorchCheckpointError` (or the correct bytes), NEVER a crash, silent byte
/// corruption, or code execution. These pin the fixes from the adversarial audit.
final class TorchCheckpointReaderHardeningTests: XCTestCase {

    // MARK: - dtype breadth (byteWidth + storage-type map for the untested types)

    func testDecodesInt64Float64AndBoolStorageTypes() throws {
        // int64 (LongStorage, 8-byte), float64 (DoubleStorage, 8-byte), bool (1-byte)
        // — a wrong byteWidth or storage-type mapping would slice the wrong bytes.
        let cases: [(storageType: String, dtype: TorchTensor.DType, width: Int, bytes: [UInt8], shape: [Int])] = [
            ("LongStorage",   .int64,   8, [0x01, 0, 0, 0, 0, 0, 0, 0,  0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], [2]),
            ("DoubleStorage", .float64, 8, [0, 0, 0, 0, 0, 0, 0xF0, 0x3F], [1]),   // 1.0
            ("BoolStorage",   .bool,    1, [0x01, 0x00, 0x01], [3]),
        ]
        for c in cases {
            let numel = c.shape.reduce(1, *)
            let pkl = Pkl.oneTensor(name: "t", storageType: c.storageType, key: "0",
                                    numel: numel, size: c.shape, stride: Pkl.contiguousStride(c.shape), offset: 0)
            let zip = Zip.store(prefix: "archive", entries: [("archive/data.pkl", pkl), ("archive/data/0", c.bytes)])
            let tensor = try XCTUnwrap(try TorchCheckpointReader().read(zip).tensors["t"], c.storageType)
            XCTAssertEqual(tensor.dtype, c.dtype, c.storageType)
            XCTAssertEqual(tensor.dtype.byteWidth, c.width, c.storageType)
            XCTAssertEqual(tensor.shape, c.shape, c.storageType)
            XCTAssertEqual(tensor.data, Data(c.bytes), c.storageType)
        }
    }

    func testUnsupportedStorageTypeThrows() throws {
        let pkl = Pkl.oneTensor(name: "t", storageType: "ComplexFloatStorage", key: "0",
                                numel: 1, size: [1], stride: [1], offset: 0)
        let zip = Zip.store(prefix: "archive", entries: [("archive/data.pkl", pkl), ("archive/data/0", [0, 0, 0, 0])])
        XCTAssertThrowsError(try TorchCheckpointReader().read(zip)) {
            guard case TorchCheckpointError.unsupportedStorageType = torchError($0) else {
                return XCTFail("expected unsupportedStorageType, got \($0)")
            }
        }
    }

    // MARK: - storage_offset > 0 (shared/sliced storage) — the offset slice math

    func testStorageOffsetSlicesTheCorrectSubWindow() throws {
        // A tensor that views elements [2,5) of a 6-element f16 storage (offset > 0).
        // The reader must emit exactly that window, not the whole blob.
        let blob: [UInt8] = [0x00, 0x3c, 0x00, 0x40, 0x00, 0x42, 0x00, 0x44, 0x00, 0x45, 0x00, 0x46] // 6 f16
        let pkl = Pkl.oneTensor(name: "w", storageType: "HalfStorage", key: "0",
                                numel: 6, size: [3], stride: [1], offset: 2)
        let zip = Zip.store(prefix: "archive", entries: [("archive/data.pkl", pkl), ("archive/data/0", blob)])
        let tensor = try XCTUnwrap(try TorchCheckpointReader().read(zip).tensors["w"])
        XCTAssertEqual(tensor.shape, [3])
        XCTAssertEqual(tensor.data, Data([0x00, 0x42, 0x00, 0x44, 0x00, 0x45])) // elements 2,3,4
    }

    func testStorageOffsetPlusExtentBeyondStorageThrows() throws {
        // offset 4 + 3 elements = 7 > numel 6 -> out of bounds, must reject not read past.
        let blob = [UInt8](repeating: 0, count: 12) // 6 f16
        let pkl = Pkl.oneTensor(name: "w", storageType: "HalfStorage", key: "0",
                                numel: 6, size: [3], stride: [1], offset: 4)
        let zip = Zip.store(prefix: "archive", entries: [("archive/data.pkl", pkl), ("archive/data/0", blob)])
        XCTAssertThrowsError(try TorchCheckpointReader().read(zip)) {
            guard case TorchCheckpointError.unsupportedTensorLayout = torchError($0) else {
                return XCTFail("expected unsupportedTensorLayout, got \($0)")
            }
        }
    }

    // MARK: - Non-contiguous stride must be rejected (never naive-sliced)

    func testNonContiguousStrideIsRejected() throws {
        // size [2,3] with a transposed stride [1,2] is non-contiguous; a naive slice
        // would emit wrong bytes, so the reader must reject it.
        let blob = [UInt8](repeating: 0, count: 12) // 6 f16
        let pkl = Pkl.oneTensor(name: "w", storageType: "HalfStorage", key: "0",
                                numel: 6, size: [2, 3], stride: [1, 2], offset: 0)
        let zip = Zip.store(prefix: "archive", entries: [("archive/data.pkl", pkl), ("archive/data/0", blob)])
        XCTAssertThrowsError(try TorchCheckpointReader().read(zip)) {
            guard case TorchCheckpointError.unsupportedTensorLayout = torchError($0) else {
                return XCTFail("expected unsupportedTensorLayout, got \($0)")
            }
        }
    }

    // MARK: - Hostile size/numel arithmetic throws instead of trapping

    func testHugeNumelThrowsInsteadOfOverflowTrap() throws {
        // numel = Int64.max via LONG1; a `numel * elementSize` trap would crash.
        let pkl = Pkl.oneTensor(name: "w", storageType: "HalfStorage", key: "0",
                                numel: Int.max, size: [2], stride: [1], offset: 0)
        let zip = Zip.store(prefix: "archive", entries: [("archive/data.pkl", pkl), ("archive/data/0", [0, 0, 0, 0])])
        XCTAssertThrowsError(try TorchCheckpointReader().read(zip)) {
            switch torchError($0) {
            case .unsupportedTensorLayout, .storageSizeMismatch: break // either is a clean rejection
            default: XCTFail("expected a typed size error, got \($0)")
            }
        }
    }

    func testNegativeDimensionThrowsInsteadOfInvertedRangeTrap() throws {
        // A negative dim makes elementCount negative; the reader must reject it before
        // it can bypass the guards and form an inverted Range in subdata.
        let pkl = Pkl.oneTensor(name: "w", storageType: "HalfStorage", key: "0",
                                numel: 4, size: [-1, 2], stride: [2, 1], offset: 0)
        let zip = Zip.store(prefix: "archive", entries: [("archive/data.pkl", pkl), ("archive/data/0", [0, 0, 0, 0, 0, 0, 0, 0])])
        XCTAssertThrowsError(try TorchCheckpointReader().read(zip)) {
            guard case TorchCheckpointError.unsupportedTensorLayout = torchError($0) else {
                return XCTFail("expected unsupportedTensorLayout, got \($0)")
            }
        }
    }

    // MARK: - Integer opcodes: LONG1 / LONG4 / signed BININT

    func testDecodesLongAndNegativeIntegerOpcodes() throws {
        // Put int values behind LONG1 (0x8a), LONG4 (0x8b) and signed BININT (0x4a)
        // in a dict, and read them back to pin the decode + two's-complement sign paths.
        var p = Pkl()
        p.proto(); p.emptyDict(); p.mark()
        p.binunicode("neg_long1"); p.long1(-1234)
        p.binunicode("big_long1"); p.long1(9_000_000_000)          // > Int32, exercises multi-byte
        p.binunicode("neg_long4"); p.long4(-70000)
        p.binunicode("neg_binint"); p.binint(-5)
        p.setitems(); p.stop()
        let zip = Zip.store(prefix: "archive", entries: [("archive/data.pkl", p.bytes)])
        let root = try TorchCheckpointReader().read(zip).root
        XCTAssertEqual(root["neg_long1"]?.intValue, -1234)
        XCTAssertEqual(root["big_long1"]?.intValue, 9_000_000_000)
        XCTAssertEqual(root["neg_long4"]?.intValue, -70000)
        XCTAssertEqual(root["neg_binint"]?.intValue, -5)
    }

    // MARK: - Truncated / oversized pickle -> typed error, no crash

    func testTruncatedPickleThrowsTruncated() throws {
        // GLOBAL with no terminating newline -> the reader runs off the end.
        let pkl: [UInt8] = [0x80, 0x02, 0x63, 0x61, 0x62] // PROTO 2, GLOBAL "ab"...(no \n)
        let zip = Zip.store(prefix: "archive", entries: [("archive/data.pkl", pkl)])
        XCTAssertThrowsError(try TorchCheckpointReader().read(zip)) {
            guard case TorchCheckpointError.truncatedPickle = torchError($0) else {
                return XCTFail("expected truncatedPickle, got \($0)")
            }
        }
    }

    func testOversizedStringLengthThrowsInsteadOfAllocatingOrCrashing() throws {
        // BINUNICODE claiming 0x7FFFFFFF bytes with only a few present.
        let pkl: [UInt8] = [0x80, 0x02, 0x58, 0xFF, 0xFF, 0xFF, 0x7F, 0x41, 0x42, 0x2e]
        let zip = Zip.store(prefix: "archive", entries: [("archive/data.pkl", pkl)])
        XCTAssertThrowsError(try TorchCheckpointReader().read(zip)) {
            guard case TorchCheckpointError.truncatedPickle = torchError($0) else {
                return XCTFail("expected truncatedPickle, got \($0)")
            }
        }
    }

    // MARK: - Deep nesting / exponential DAG -> bounded, thrown, never a crash

    func testDeepNestingIsStackSafeAndBoundedOnA512KBStack() {
        // The depth cap must sit BELOW the stack-overflow threshold of a 512 KB stack —
        // Swift cooperative-pool / dispatch threads (where the weights pipeline runs
        // off-main) get 512 KB, not the 8 MB main/XCTest stack. So exercise the cap on
        // an actual 512 KB thread: nesting to cap-1 must decode without a SIGBUS, and
        // deeper input must throw `malformedPickle` (never crash). Raising the cap above
        // the stack-safe threshold would make the accept case crash the whole process.
        let cap = TorchCheckpointReader.maxNestingDepth

        let acceptZip = Zip.store(prefix: "archive", entries: [("archive/data.pkl", nestedTuples(depth: cap - 1))])
        switch onSmallStack({ Result { try TorchCheckpointReader().read(acceptZip) } }) {
        case .success(let checkpoint): XCTAssertNotNil(checkpoint.root)
        case .failure(let error): XCTFail("cap-1 nesting should decode on a 512 KB stack, got \(error)")
        }

        let rejectZip = Zip.store(prefix: "archive", entries: [("archive/data.pkl", nestedTuples(depth: cap + 64))])
        switch onSmallStack({ Result { try TorchCheckpointReader().read(rejectZip) } }) {
        case .success: XCTFail("over-cap nesting should throw, not decode")
        case .failure(let error):
            guard case TorchCheckpointError.malformedPickle = torchError(error) else {
                return XCTFail("expected malformedPickle (too deep), got \(error)")
            }
        }
    }

    func testLargeListDecodesWithoutQuadraticGrowth() throws {
        // 40 000 individual APPENDs to one list. The naive `existing + items` rebuild
        // per opcode is O(N²) (CPU-pinning DoS on a crafted pickle); the linearized
        // in-place growth keeps it quick and — pinned here — correct.
        var p = Pkl()
        p.proto(); p.emptyList()
        for i in 0..<40_000 { p.binint1(i % 128); p.raw([0x61]) } // APPEND
        p.stop()
        let zip = Zip.store(prefix: "archive", entries: [("archive/data.pkl", p.bytes)])
        guard case .list(let items) = try TorchCheckpointReader().read(zip).root else {
            return XCTFail("expected a list root")
        }
        XCTAssertEqual(items.count, 40_000)
        XCTAssertEqual(items.last?.intValue, Int64((40_000 - 1) % 128))
    }

    func testExponentialSharedMemoGraphThrowsInsteadOfHanging() throws {
        // "Billion laughs": each level is a list holding the previous level twice via a
        // memo reference. 25 doublings = 2^25 logical nodes, far over the node budget,
        // but a tiny byte stream — must throw quickly, never expand/OOM.
        var p = Pkl()
        p.proto()
        p.emptyList(); p.binput(0)                 // memo[0] = []
        for level in 1...25 {
            p.emptyList(); p.binput(level)
            p.mark(); p.binget(level - 1); p.binget(level - 1); p.appends()
        }
        p.stop()
        let zip = Zip.store(prefix: "archive", entries: [("archive/data.pkl", p.bytes)])
        XCTAssertThrowsError(try TorchCheckpointReader().read(zip)) {
            guard case TorchCheckpointError.malformedPickle = torchError($0) else {
                return XCTFail("expected malformedPickle (graph too large), got \($0)")
            }
        }
    }

    // MARK: - Corrupt / malformed ZIP containers -> typed errors

    func testMissingDataPickleThrowsMissingPickle() throws {
        let zip = Zip.store(prefix: "archive", entries: [("archive/version", Array("3".utf8))])
        XCTAssertThrowsError(try TorchCheckpointReader().read(zip)) {
            XCTAssertEqual(torchError($0), .missingPickle)
        }
    }

    func testCorruptCentralDirectorySignatureThrows() throws {
        var zip = [UInt8](Zip.store(prefix: "archive", entries: [("archive/data.pkl", [0x80, 0x02, 0x4e, 0x2e])]))
        // Corrupt the central-directory signature (find 0x02014b50 and flip a byte).
        for i in 0..<(zip.count - 4) where zip[i] == 0x50 && zip[i + 1] == 0x4b && zip[i + 2] == 0x01 && zip[i + 3] == 0x02 {
            zip[i + 3] = 0xFF; break
        }
        XCTAssertThrowsError(try TorchCheckpointReader().read(Data(zip))) {
            switch torchError($0) {
            case .corruptedZip, .notAZipArchive: break
            default: XCTFail("expected corruptedZip/notAZipArchive, got \($0)")
            }
        }
    }

    // MARK: - ZIP64 round-trip + malformed extra

    func testDecodesTensorThroughZip64Path() throws {
        let payload: [UInt8] = [0x00, 0x3c, 0x00, 0x40, 0x00, 0x42, 0x00, 0x44] // 4 f16
        let pkl = Pkl.oneTensor(name: "w", storageType: "HalfStorage", key: "0",
                                numel: 4, size: [2, 2], stride: [2, 1], offset: 0)
        let zip = Zip.zip64(prefix: "archive", entries: [("archive/data.pkl", pkl), ("archive/data/0", payload)])
        let tensor = try XCTUnwrap(try TorchCheckpointReader().read(zip).tensors["w"])
        XCTAssertEqual(tensor.shape, [2, 2])
        XCTAssertEqual(tensor.data, Data(payload))
    }

    func testZip64ExtraTooShortForItsSentinelsThrows() throws {
        // Both size and offset are sentinels but the 0x0001 extra only carries the
        // size field (8 bytes) — reading the offset would cross the block boundary.
        let zip = Zip.zip64ShortExtra(prefix: "archive", pickle: [0x80, 0x02, 0x4e, 0x2e])
        XCTAssertThrowsError(try TorchCheckpointReader().read(zip)) {
            guard case TorchCheckpointError.corruptedZip = torchError($0) else {
                return XCTFail("expected corruptedZip, got \($0)")
            }
        }
    }

    // MARK: - Byte-order marker

    func testBigEndianByteOrderMarkerIsRejected() throws {
        let pkl = Pkl.oneTensor(name: "w", storageType: "HalfStorage", key: "0",
                                numel: 4, size: [2, 2], stride: [2, 1], offset: 0)
        let zip = Zip.store(prefix: "archive", entries: [
            ("archive/data.pkl", pkl),
            ("archive/data/0", [0, 0, 0, 0, 0, 0, 0, 0]),
            ("archive/byteorder", Array("big".utf8)),
        ])
        XCTAssertThrowsError(try TorchCheckpointReader().read(zip)) {
            guard case TorchCheckpointError.unsupportedByteOrder(let order) = torchError($0) else {
                return XCTFail("expected unsupportedByteOrder, got \($0)")
            }
            XCTAssertEqual(order, "big")
        }
    }
}

private func torchError(_ error: Error) -> TorchCheckpointError {
    (error as? TorchCheckpointError) ?? .malformedPickle("non-torch error: \(error)")
}

/// A pickle whose value is `depth` nested 1-tuples around a scalar — the deepest
/// `convert` call reaches nesting level `depth`.
private func nestedTuples(depth: Int) -> [UInt8] {
    var p = Pkl()
    p.proto(); p.binint1(0)
    for _ in 0..<depth { p.raw([0x85]) } // TUPLE1
    p.stop()
    return p.bytes
}

/// Runs `body` on a thread with a 512 KB stack (the size Swift cooperative-pool and
/// dispatch threads get) and returns its result. A stack overflow inside `body`
/// crashes the process — which is exactly the regression this makes observable.
private func onSmallStack<T: Sendable>(_ body: @escaping @Sendable () -> Result<T, Error>) -> Result<T, Error> {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread { box.result = body(); done.signal() }
    thread.stackSize = 512 * 1024
    thread.start()
    done.wait()
    return box.result!
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

// MARK: - Flexible protocol-2 pickle builder

private struct Pkl {
    var bytes = [UInt8]()

    mutating func raw(_ b: [UInt8]) { bytes += b }
    mutating func proto() { bytes += [0x80, 0x02] }
    mutating func stop() { bytes += [0x2e] }
    mutating func mark() { bytes += [0x28] }
    mutating func tuple() { bytes += [0x74] }
    mutating func reduce() { bytes += [0x52] }
    mutating func binpersid() { bytes += [0x51] }
    mutating func emptyTuple() { bytes += [0x29] }
    mutating func emptyDict() { bytes += [0x7d] }
    mutating func emptyList() { bytes += [0x5d] }
    mutating func appends() { bytes += [0x65] }
    mutating func setitems() { bytes += [0x75] }
    mutating func falseValue() { bytes += [0x89] }
    mutating func binput(_ i: Int) { bytes += [0x71, UInt8(i)] }
    mutating func binget(_ i: Int) { bytes += [0x68, UInt8(i)] }
    mutating func binint1(_ n: Int) { bytes += [0x4b, UInt8(n)] }
    mutating func binint(_ n: Int32) { bytes += [0x4a] + le32(UInt32(bitPattern: n)) }

    /// LONG1 with a minimal little-endian two's-complement body.
    mutating func long1(_ n: Int64) { bytes += [0x8a] + longBody(n) }
    /// LONG4 (4-byte length prefix) with the same body.
    mutating func long4(_ n: Int64) {
        let body = longBody(n)
        bytes += [0x8b] + le32(UInt32(body.count - 1)) + body.dropFirst() // drop the 1-byte len from longBody
    }

    private func longBody(_ n: Int64) -> [UInt8] {
        if n == 0 { return [0x00] }
        var v = n
        var out = [UInt8]()
        while true {
            let byte = UInt8(truncatingIfNeeded: v)
            out.append(byte)
            v >>= 8
            if (v == 0 && byte & 0x80 == 0) || (v == -1 && byte & 0x80 != 0) { break }
        }
        return [UInt8(out.count)] + out
    }

    mutating func binunicode(_ s: String) {
        let u = Array(s.utf8)
        bytes += [0x58] + le32(UInt32(u.count)) + u
    }

    mutating func global(_ module: String, _ name: String) {
        bytes += [0x63] + Array(module.utf8) + [0x0a] + Array(name.utf8) + [0x0a]
    }

    /// An int chosen so any Int64 encodes (signed BININT when it fits, else LONG1).
    mutating func intItem(_ n: Int) {
        if let small = Int32(exactly: n) { binint(small) } else { long1(Int64(n)) }
    }

    mutating func intSeq(_ values: [Int]) {
        mark(); for v in values { intItem(v) }; tuple()
    }

    /// `torch._utils._rebuild_tensor_v2(<StorageType>(key, numel), offset, size, stride, False, OrderedDict())`.
    mutating func tensor(storageType: String, key: String, numel: Int, size: [Int], stride: [Int], offset: Int) {
        global("torch._utils", "_rebuild_tensor_v2")
        mark()
        mark()
        binunicode("storage"); global("torch", storageType); binunicode(key); binunicode("cpu"); intItem(numel)
        tuple(); binpersid()
        intItem(offset)
        intSeq(size)
        intSeq(stride)
        falseValue()
        global("collections", "OrderedDict"); emptyTuple(); reduce()
        tuple(); reduce()
    }

    static func oneTensor(name: String, storageType: String, key: String,
                          numel: Int, size: [Int], stride: [Int], offset: Int) -> [UInt8] {
        var p = Pkl()
        p.proto()
        p.global("collections", "OrderedDict"); p.emptyTuple(); p.reduce()
        p.mark()
        p.binunicode(name)
        p.tensor(storageType: storageType, key: key, numel: numel, size: size, stride: stride, offset: offset)
        p.setitems()
        p.stop()
        return p.bytes
    }

    static func contiguousStride(_ size: [Int]) -> [Int] {
        guard !size.isEmpty else { return [] }
        var stride = [Int](repeating: 1, count: size.count)
        for i in stride.indices.dropLast().reversed() { stride[i] = stride[i + 1] * size[i + 1] }
        return stride
    }
}

// MARK: - Flexible store-only ZIP builder (standard + ZIP64)

private enum Zip {
    /// A standard store-only ZIP (32-bit records).
    static func store(prefix: String, entries: [(name: String, data: [UInt8])]) -> Data {
        var out = [UInt8](), central = [UInt8](), offsets = [Int]()
        for (name, data) in entries {
            offsets.append(out.count)
            out += localHeader(name: name, size: data.count, extra: []) + Array(name.utf8) + data
        }
        for (i, e) in entries.enumerated() {
            central += centralHeader(name: e.name, size: e.data.count, localOffset: offsets[i], extra: [])
        }
        return Data(out + central + eocd(count: entries.count, cdSize: central.count, cdOffset: out.count))
    }

    /// A ZIP64 archive: every entry's size + local-header offset are 0xFFFFFFFF
    /// sentinels resolved via a 0x0001 extra, with a ZIP64 EOCD + locator and a
    /// standard EOCD carrying 0xFFFF / 0xFFFFFFFF sentinels (forcing the ZIP64 path).
    static func zip64(prefix: String, entries: [(name: String, data: [UInt8])]) -> Data {
        var out = [UInt8](), central = [UInt8](), offsets = [Int]()
        for (name, data) in entries {
            offsets.append(out.count)
            // Local ZIP64 extra: original + compressed size (both stored == data.count).
            let localExtra = extra64(fields: [UInt64(data.count), UInt64(data.count)])
            out += localHeader(name: name, size: 0xFFFF_FFFF, extra: localExtra) + Array(name.utf8) + localExtra + data
        }
        for (i, e) in entries.enumerated() {
            // Central ZIP64 extra: original size, compressed size, local-header offset.
            let cdExtra = extra64(fields: [UInt64(e.data.count), UInt64(e.data.count), UInt64(offsets[i])])
            central += centralHeader(name: e.name, size: 0xFFFF_FFFF, localOffset: 0xFFFF_FFFF, extra: cdExtra)
        }
        let cdOffset = out.count
        out += central
        let z64EOCD = out.count
        out += zip64EOCD(count: entries.count, cdSize: central.count, cdOffset: cdOffset)
        out += zip64Locator(z64EOCDOffset: z64EOCD)
        out += eocd(count: 0xFFFF, cdSize: central.count, cdOffset: 0xFFFF_FFFF)
        return Data(out)
    }

    /// A single-entry ZIP64 archive whose 0x0001 extra declares both size + offset
    /// sentinels but only supplies the 8-byte size field (block too short).
    static func zip64ShortExtra(prefix: String, pickle: [UInt8]) -> Data {
        let name = "\(prefix)/data.pkl"
        var out = [UInt8]()
        let localExtra = extra64(fields: [UInt64(pickle.count), UInt64(pickle.count)])
        out += localHeader(name: name, size: 0xFFFF_FFFF, extra: localExtra) + Array(name.utf8) + localExtra + pickle
        let cdOffset = out.count
        // Central extra: sentinels for size AND offset, but only the size field present.
        let shortExtra = extra64(fields: [UInt64(pickle.count)]) // 8 bytes, no offset field
        var central = centralHeader(name: name, size: 0xFFFF_FFFF, localOffset: 0xFFFF_FFFF, extra: shortExtra)
        let z64EOCD = out.count + central.count
        out += central
        out += zip64EOCD(count: 1, cdSize: central.count, cdOffset: cdOffset)
        out += zip64Locator(z64EOCDOffset: z64EOCD)
        out += eocd(count: 0xFFFF, cdSize: central.count, cdOffset: 0xFFFF_FFFF)
        _ = central
        return Data(out)
    }

    // MARK: byte-level record builders

    private static func localHeader(name: String, size: Int, extra: [UInt8]) -> [UInt8] {
        le32(0x04034b50) + le16(45) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            + le32(UInt32(truncatingIfNeeded: size)) + le32(UInt32(truncatingIfNeeded: size))
            + le16(UInt16(name.utf8.count)) + le16(UInt16(extra.count))
    }

    private static func centralHeader(name: String, size: Int, localOffset: Int, extra: [UInt8]) -> [UInt8] {
        le32(0x02014b50) + le16(45) + le16(45) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            + le32(UInt32(truncatingIfNeeded: size)) + le32(UInt32(truncatingIfNeeded: size))
            + le16(UInt16(name.utf8.count)) + le16(UInt16(extra.count)) + le16(0)
            + le16(0) + le16(0) + le32(0) + le32(UInt32(truncatingIfNeeded: localOffset))
            + Array(name.utf8) + extra
    }

    private static func eocd(count: Int, cdSize: Int, cdOffset: Int) -> [UInt8] {
        le32(0x06054b50) + le16(0) + le16(0)
            + le16(UInt16(truncatingIfNeeded: count)) + le16(UInt16(truncatingIfNeeded: count))
            + le32(UInt32(cdSize)) + le32(UInt32(truncatingIfNeeded: cdOffset)) + le16(0)
    }

    private static func extra64(fields: [UInt64]) -> [UInt8] {
        var body = [UInt8]()
        for f in fields { body += le64(f) }
        return le16(0x0001) + le16(UInt16(body.count)) + body
    }

    private static func zip64EOCD(count: Int, cdSize: Int, cdOffset: Int) -> [UInt8] {
        le32(0x06064b50) + le64(44) + le16(45) + le16(45) + le32(0) + le32(0)
            + le64(UInt64(count)) + le64(UInt64(count)) + le64(UInt64(cdSize)) + le64(UInt64(cdOffset))
    }

    private static func zip64Locator(z64EOCDOffset: Int) -> [UInt8] {
        le32(0x07064b50) + le32(0) + le64(UInt64(z64EOCDOffset)) + le32(1)
    }
}

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
private func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xff) } }
