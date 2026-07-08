import Foundation

/// A pure-Swift reader for PyTorch `.th`/`.pt` checkpoints (the `torch.save`
/// zip-archive format), built so the app can load the htdemucs weights with **no
/// Python and no torch dependency** — the native engine's weights pipeline. It
/// parses the two layers `torch.save` produces:
///
///   1. a **store-only ZIP** (`data.pkl`, `data/<N>` raw storage blobs, plus
///      metadata entries the reader ignores), and
///   2. a **protocol-2 pickle** describing the object graph, walked by a
///      deliberately small, **allowlisted, non-executing** stack VM.
///
/// The output is backend-neutral: every tensor becomes `(dtype, shape,
/// little-endian bytes)` with the raw storage bytes untouched, so a later layout
/// adapter (MLX channels-last, MPSGraph, …) can transpose without this layer
/// caring which backend wins the engine spike.
///
/// ## Security posture
/// A pickle is an instruction stream that, under `pickle.load`, can execute
/// arbitrary code (the classic `GLOBAL 'os system' … REDUCE`). This VM **never
/// imports a module or calls a callable.** `GLOBAL` pushes an inert symbolic
/// reference; `REDUCE` is interpreted only for the handful of allowlisted,
/// data-only reducers this format needs (`collections.OrderedDict`,
/// `torch._utils._rebuild_tensor_v2`/`_rebuild_parameter`) and produces an inert
/// `.opaque` value for everything else. Any opcode outside the allowlist is a hard
/// error. The bundled checkpoint is also SHA-256-verified at build time (see
/// `WeightsIdentity` + `script/build_and_run.sh`), but this layer treats the input as
/// hostile regardless.
public struct TorchCheckpointReader: Sendable {
    /// Maximum object-graph nesting depth accepted during decode. Kept small enough
    /// that the bounded recursion is stack-safe even on a 512 KB stack — Swift
    /// cooperative-pool and dispatch threads get 512 KB, and the weights pipeline runs
    /// off-main (`@concurrent`). htdemucs nests ~5 deep, so this is ample headroom.
    static let maxNestingDepth = 128

    public init() {}

    /// Reads and decodes the checkpoint at `url`.
    public func read(contentsOf url: URL) throws -> TorchCheckpoint {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw TorchCheckpointError.notAZipArchive
        }
        return try read(data)
    }

    /// Reads and decodes a checkpoint already resident in memory.
    public func read(_ data: Data) throws -> TorchCheckpoint {
        let archive = try ZipArchive(data)
        guard let pickleName = archive.entryNames.first(where: { $0.hasSuffix("data.pkl") }) else {
            throw TorchCheckpointError.missingPickle
        }
        // The storage blobs live under "<prefix>/data/<key>" next to "<prefix>/data.pkl".
        let prefix = String(pickleName.dropLast("data.pkl".count)) // includes the trailing "/"

        // The raw storage bytes are emitted verbatim as little-endian. Newer torch
        // archives record a `byteorder` marker; reject a big-endian one rather than
        // silently mis-reading it. (The pinned htdemucs file omits the marker — it
        // predates it — so absence means little-endian, the only order the targets use.)
        let byteOrderName = "\(prefix)byteorder"
        if archive.contains(byteOrderName) {
            let marker = String(decoding: try archive.data(for: byteOrderName), as: UTF8.self)
            guard marker == "little" else {
                throw TorchCheckpointError.unsupportedByteOrder(marker)
            }
        }

        let pickleBytes = [UInt8](try archive.data(for: pickleName))
        let machine = PickleMachine(bytes: pickleBytes) { key in
            let name = "\(prefix)data/\(key)"
            guard archive.contains(name) else { throw TorchCheckpointError.missingStorage(key) }
            return try archive.data(for: name)
        }
        let root = try machine.run()
        return TorchCheckpoint(root: root)
    }
}

// MARK: - Public value model

/// One tensor lifted out of a checkpoint: its dtype, shape, and the raw,
/// contiguous, row-major, little-endian storage bytes (`data.count ==
/// elementCount * dtype.byteWidth`).
public struct TorchTensor: Sendable, Equatable {
    public enum DType: String, Sendable, Equatable {
        case float16, float32, float64, bfloat16
        case int64, int32, int16, int8, uint8, bool

        /// Bytes per element in the raw storage.
        public var byteWidth: Int {
            switch self {
            case .float64, .int64: return 8
            case .float32, .int32: return 4
            case .float16, .bfloat16, .int16: return 2
            case .int8, .uint8, .bool: return 1
            }
        }
    }

    public let dtype: DType
    public let shape: [Int]
    public let data: Data

    public init(dtype: DType, shape: [Int], data: Data) {
        self.dtype = dtype
        self.shape = shape
        self.data = data
    }

    /// Product of the shape dimensions (1 for a scalar tensor).
    public var elementCount: Int { shape.reduce(1, *) }
}

/// The decoded pickle object graph, restricted to the inert value kinds this
/// format produces. Foreign classes/functions survive as `.global`; any object
/// built from an unrecognized reducer is `.opaque` (its contents intentionally
/// discarded — nothing outside the tensor tree is needed).
public indirect enum TorchValue: Sendable {
    case tensor(TorchTensor)
    case dictionary([(key: TorchValue, value: TorchValue)])
    case list([TorchValue])
    case tuple([TorchValue])
    case string(String)
    case integer(Int64)
    case double(Double)
    case boolean(Bool)
    case none
    /// An inert symbolic reference to a class/function — never imported or called.
    case global(module: String, name: String)
    /// An object produced by a reducer the reader does not interpret. Inert.
    case opaque

    /// The tensor payload, if this value is a tensor.
    public var tensorValue: TorchTensor? {
        if case .tensor(let t) = self { return t }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int64? {
        if case .integer(let i) = self { return i }
        return nil
    }

    public var doubleValue: Double? {
        if case .double(let d) = self { return d }
        return nil
    }

    public var boolValue: Bool? {
        if case .boolean(let b) = self { return b }
        return nil
    }

    /// Looks up a value by string key when this value is a dictionary.
    public subscript(_ key: String) -> TorchValue? {
        guard case .dictionary(let pairs) = self else { return nil }
        return pairs.first(where: { $0.key.stringValue == key })?.value
    }
}

/// A decoded checkpoint: the full object tree plus a flattened, dotted-path map of
/// every tensor found anywhere in it.
public struct TorchCheckpoint: Sendable {
    /// The root of the decoded object graph.
    public let root: TorchValue
    /// Every tensor keyed by dotted path (string dict keys and list/tuple indices
    /// joined by "."). For a flat state dict the key is just the tensor's name; for
    /// the htdemucs "bag" the keys are prefixed by `state.`.
    public let tensors: [String: TorchTensor]
    /// Tensor paths in traversal (pickle/insertion) order — state dicts are ordered.
    public let orderedTensorNames: [String]

    init(root: TorchValue) {
        self.root = root
        var flat: [String: TorchTensor] = [:]
        var ordered: [String] = []
        TorchCheckpoint.collectTensors(root, path: "", into: &flat, ordered: &ordered)
        self.tensors = flat
        self.orderedTensorNames = ordered
    }

    /// The tensors under a dotted `prefix`, with the prefix (and its dot) stripped
    /// from the keys — e.g. `tensors(under: "state")` yields the htdemucs state dict
    /// keyed by bare parameter names.
    public func tensors(under prefix: String) -> [String: TorchTensor] {
        let dotted = prefix + "."
        var result: [String: TorchTensor] = [:]
        for (key, tensor) in tensors where key.hasPrefix(dotted) {
            result[String(key.dropFirst(dotted.count))] = tensor
        }
        return result
    }

    private static func collectTensors(_ value: TorchValue, path: String,
                                       into flat: inout [String: TorchTensor],
                                       ordered: inout [String]) {
        switch value {
        case .tensor(let tensor):
            flat[path] = tensor
            ordered.append(path)
        case .dictionary(let pairs):
            for pair in pairs {
                guard let key = pair.key.stringValue else { continue }
                collectTensors(pair.value, path: path.isEmpty ? key : "\(path).\(key)",
                               into: &flat, ordered: &ordered)
            }
        case .list(let items), .tuple(let items):
            for (index, item) in items.enumerated() {
                collectTensors(item, path: path.isEmpty ? "\(index)" : "\(path).\(index)",
                               into: &flat, ordered: &ordered)
            }
        default:
            break
        }
    }
}

public enum TorchCheckpointError: Error, Equatable {
    case notAZipArchive
    case corruptedZip(String)
    case missingPickle
    case missingStorage(String)
    case unsupportedOpcode(UInt8)
    case truncatedPickle
    case malformedPickle(String)
    case unsupportedStorageType(String)
    case unsupportedTensorLayout(String)
    case storageSizeMismatch(String)
    case unsupportedByteOrder(String)
}

// MARK: - Store-only ZIP reader

/// A minimal reader for the store-only (uncompressed) ZIP that `torch.save`
/// writes. It walks the central directory for the authoritative entry list and
/// local-header offsets, then reads each entry's data offset from its **local**
/// header — torch inflates the local extra field to 64-byte-align storage blobs,
/// so the local extra length differs from the central one and must not be assumed.
/// Standard ZIP and ZIP64 (per-entry 64-bit sizes/offsets, ZIP64 end-of-central-
/// directory) are both handled; compressed entries are rejected.
private struct ZipArchive {
    private let view: ByteView
    /// name -> (localHeaderOffset, uncompressedSize)
    private let entries: [String: (localHeaderOffset: Int, size: Int)]
    let entryNames: [String]

    init(_ data: Data) throws {
        let view = ByteView(data)
        // Fast reject: every ZIP starts with a "PK" signature.
        guard view.count >= 22, view.byte(0) == 0x50, view.byte(1) == 0x4b else {
            throw TorchCheckpointError.notAZipArchive
        }
        self.view = view

        let eocd = try ZipArchive.findEndOfCentralDirectory(view)
        var offset = eocd.centralDirectoryOffset
        var names: [String] = []
        var map: [String: (localHeaderOffset: Int, size: Int)] = [:]

        for _ in 0..<eocd.entryCount {
            guard view.bounds(offset, 46), view.u32(offset) == 0x02014b50 else {
                throw TorchCheckpointError.corruptedZip("central directory entry signature")
            }
            let method = view.u16(offset + 10)
            let compressedSize = Int(view.u32(offset + 20))
            var uncompressedSize = Int(view.u32(offset + 24))
            let nameLength = view.u16(offset + 28)
            let extraLength = view.u16(offset + 30)
            let commentLength = view.u16(offset + 32)
            var localHeaderOffset = Int(view.u32(offset + 42))

            guard view.bounds(offset + 46, nameLength + extraLength + commentLength) else {
                throw TorchCheckpointError.corruptedZip("central directory entry overruns file")
            }
            let name = view.string(offset + 46, nameLength)

            // ZIP64 extra: 32-bit sentinels defer to a 0x0001 extra block.
            if uncompressedSize == 0xFFFF_FFFF || localHeaderOffset == 0xFFFF_FFFF {
                (uncompressedSize, localHeaderOffset) = try ZipArchive.readZip64Extra(
                    view, at: offset + 46 + nameLength, length: extraLength,
                    uncompressedSizeSentinel: uncompressedSize == 0xFFFF_FFFF,
                    compressedSizeSentinel: compressedSize == 0xFFFF_FFFF,
                    offsetSentinel: localHeaderOffset == 0xFFFF_FFFF,
                    uncompressedSize: uncompressedSize, localHeaderOffset: localHeaderOffset)
            }

            // Only the blobs the reader actually reads must be stored (uncompressed).
            let isRead = name.hasSuffix("data.pkl") || name.contains("/data/")
            if isRead && method != 0 {
                throw TorchCheckpointError.corruptedZip("entry \(name) is compressed (method \(method))")
            }

            names.append(name)
            map[name] = (localHeaderOffset, uncompressedSize)
            offset += 46 + nameLength + extraLength + commentLength
        }

        self.entryNames = names
        self.entries = map
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    /// The uncompressed bytes of `name`, as a fresh zero-based `Data`.
    func data(for name: String) throws -> Data {
        guard let entry = entries[name] else { throw TorchCheckpointError.missingStorage(name) }
        let header = entry.localHeaderOffset
        guard view.bounds(header, 30), view.u32(header) == 0x04034b50 else {
            throw TorchCheckpointError.corruptedZip("local header signature for \(name)")
        }
        // Re-check the compression method at the local header (not just the central
        // directory), so a central/local mismatch can't smuggle compressed bytes
        // through as raw storage.
        guard view.u16(header + 8) == 0 else {
            throw TorchCheckpointError.corruptedZip("entry \(name) is compressed (local method)")
        }
        // The local extra length (torch's alignment padding) generally differs from
        // the central one, so the data offset is derived here, from the local header.
        let localNameLength = view.u16(header + 26)
        let localExtraLength = view.u16(header + 28)
        let dataStart = header + 30 + localNameLength + localExtraLength
        guard view.bounds(dataStart, entry.size) else {
            throw TorchCheckpointError.corruptedZip("data for \(name) overruns file")
        }
        return view.slice(dataStart, entry.size)
    }

    private struct EndOfCentralDirectory {
        let entryCount: Int
        let centralDirectoryOffset: Int
    }

    private static func findEndOfCentralDirectory(_ view: ByteView) throws -> EndOfCentralDirectory {
        // The EOCD sits at the end, optionally followed by a <=65535-byte comment.
        let maxScan = min(view.count, 22 + 65_535)
        var eocd = -1
        var probe = view.count - 22
        let limit = view.count - maxScan
        while probe >= limit && probe >= 0 {
            if view.u32(probe) == 0x06054b50 { eocd = probe; break }
            probe -= 1
        }
        guard eocd >= 0 else { throw TorchCheckpointError.notAZipArchive }

        var entryCount = view.u16(eocd + 10)
        var cdOffset = Int(view.u32(eocd + 16))

        // ZIP64: a locator (0x07064b50) 20 bytes before the EOCD points at the ZIP64
        // EOCD record, which carries the true 64-bit count/offset.
        let locator = eocd - 20
        if entryCount == 0xFFFF || cdOffset == 0xFFFF_FFFF,
           locator >= 0, view.bounds(locator, 20), view.u32(locator) == 0x07064b50 {
            let z64 = try Self.clampedOffset(view.u64(locator + 8), view: view, what: "zip64 EOCD locator")
            guard view.bounds(z64, 56), view.u32(z64) == 0x06064b50 else {
                throw TorchCheckpointError.corruptedZip("zip64 end-of-central-directory")
            }
            let count = view.u64(z64 + 32)
            guard count <= UInt64(Int.max) else { throw TorchCheckpointError.corruptedZip("zip64 entry count overflow") }
            entryCount = Int(count)
            cdOffset = try Self.clampedOffset(view.u64(z64 + 48), view: view, what: "zip64 central directory offset")
        } else if entryCount == 0xFFFF || cdOffset == 0xFFFF_FFFF {
            throw TorchCheckpointError.corruptedZip("zip64 required but locator missing")
        }

        guard cdOffset >= 0, cdOffset <= view.count else {
            throw TorchCheckpointError.corruptedZip("central directory offset out of range")
        }
        return EndOfCentralDirectory(entryCount: entryCount, centralDirectoryOffset: cdOffset)
    }

    /// Parses the ZIP64 (0x0001) extra block. Its 8-byte fields appear in the fixed
    /// order — original size, compressed size, local-header offset — and each is
    /// present ONLY when its 32-bit central-directory counterpart is the 0xFFFFFFFF
    /// sentinel. Getting this order wrong would read a valid-looking but wrong offset.
    private static func readZip64Extra(_ view: ByteView, at start: Int, length: Int,
                                       uncompressedSizeSentinel: Bool,
                                       compressedSizeSentinel: Bool,
                                       offsetSentinel: Bool,
                                       uncompressedSize: Int, localHeaderOffset: Int)
        throws -> (size: Int, offset: Int) {
        var size = uncompressedSize
        var offset = localHeaderOffset
        var cursor = start
        let end = start + length
        while cursor + 4 <= end {
            let id = view.u16(cursor)
            let blockLength = view.u16(cursor + 2)
            guard cursor + 4 + blockLength <= end else { break }
            if id == 0x0001 {
                var field = cursor + 4
                let blockEnd = cursor + 4 + blockLength
                // Each sentinel-gated field must fit WITHIN this block, not merely
                // within the file — otherwise a short block would read a size/offset
                // from the following bytes and yield a wrong (silent) data offset.
                func take() throws -> UInt64 {
                    guard field + 8 <= blockEnd else {
                        throw TorchCheckpointError.corruptedZip("zip64 extra block too short for its sentinel fields")
                    }
                    defer { field += 8 }
                    return view.u64(field)
                }
                if uncompressedSizeSentinel { size = try clampedOffset(try take(), view: view, what: "zip64 size") }
                if compressedSizeSentinel { _ = try take() } // present but unused (stored => equals size)
                if offsetSentinel { offset = try clampedOffset(try take(), view: view, what: "zip64 offset") }
            }
            cursor += 4 + blockLength
        }
        return (size, offset)
    }

    private static func clampedOffset(_ value: UInt64, view: ByteView, what: String) throws -> Int {
        guard value <= UInt64(view.count) else { throw TorchCheckpointError.corruptedZip("\(what) out of range") }
        return Int(value)
    }
}

/// Bounds-checked little-endian reads over a `Data`, normalized to its `startIndex`
/// so callers work in 0-based absolute offsets regardless of slicing.
private struct ByteView {
    private let data: Data
    private let base: Int
    let count: Int

    init(_ data: Data) {
        self.data = data
        self.base = data.startIndex
        self.count = data.count
    }

    func byte(_ offset: Int) -> UInt8 { data[base + offset] }

    func u16(_ offset: Int) -> Int { Int(byte(offset)) | (Int(byte(offset + 1)) << 8) }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(byte(offset)) | (UInt32(byte(offset + 1)) << 8)
            | (UInt32(byte(offset + 2)) << 16) | (UInt32(byte(offset + 3)) << 24)
    }

    func u64(_ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(byte(offset + i)) << (8 * i) }
        return value
    }

    func bounds(_ offset: Int, _ length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset + length <= count
    }

    func string(_ offset: Int, _ length: Int) -> String {
        String(decoding: slice(offset, length), as: UTF8.self)
    }

    /// A fresh, zero-based copy of `length` bytes at `offset`.
    func slice(_ offset: Int, _ length: Int) -> Data {
        data.subdata(in: (base + offset)..<(base + offset + length))
    }
}

// MARK: - Non-executing pickle VM

/// A small stack machine over a protocol-2 (and a defensive slice of protocol-3/4)
/// pickle. It builds an inert object graph; it never imports a module or calls a
/// callable. Only the data-only reducers this checkpoint format uses are
/// interpreted — everything else becomes `.opaque`.
private final class PickleMachine {
    /// Total converted-node ceiling — bounds time/memory against a shared-memo DAG
    /// that would otherwise re-expand exponentially. The real htdemucs graph is well
    /// under 100k nodes, so this leaves ~40× headroom (covering a multi-model bag).
    static let nodeCeiling = 4_000_000

    private let bytes: [UInt8]
    private var pos = 0
    private var stack: [Obj] = []
    private var memo: [Int: Obj] = [:]
    private var nodeBudget = PickleMachine.nodeCeiling
    private let storage: (String) throws -> Data

    init(bytes: [UInt8], storage: @escaping (String) throws -> Data) {
        self.bytes = bytes
        self.storage = storage
    }

    /// An intermediate, reference-typed node. Reference identity matters: pickle
    /// memoizes a container and then mutates it (SETITEMS/APPENDS), and the memo
    /// must observe those mutations — value semantics would fork the two.
    private final class Obj {
        enum Kind {
            case mark
            case none
            case bool(Bool)
            case int(Int64)
            case double(Double)
            case string(String)
            case global(String, String)
            case storage(dtype: TorchTensor.DType, key: String, numel: Int)
            case tensor(TorchTensor)
            case tuple([Obj])
            case list([Obj])
            case dict([(Obj, Obj)])
            case opaque
        }
        var kind: Kind
        init(_ kind: Kind) { self.kind = kind }
    }

    func run() throws -> TorchValue {
        loop: while true {
            guard pos < bytes.count else { throw TorchCheckpointError.truncatedPickle }
            let opcode = bytes[pos]
            pos += 1
            switch opcode {
            case 0x80: try skip(1)                                // PROTO (skip 1-byte version)
            case 0x95: try skip(8)                                // FRAME (skip 8-byte length)
            case 0x2e: break loop                                 // STOP
            case 0x28: stack.append(Obj(.mark))                   // MARK

            // Scalars / singletons.
            case 0x4e: stack.append(Obj(.none))                   // NONE
            case 0x88: stack.append(Obj(.bool(true)))             // NEWTRUE
            case 0x89: stack.append(Obj(.bool(false)))            // NEWFALSE
            case 0x4b: stack.append(Obj(.int(Int64(try readByte())))) // BININT1
            case 0x4d: stack.append(Obj(.int(Int64(try readU16()))))  // BININT2
            case 0x4a: stack.append(Obj(.int(Int64(try readI32())))) // BININT (signed)
            case 0x8a: stack.append(Obj(.int(try readLong(length: Int(try readByte()))))) // LONG1
            case 0x8b: stack.append(Obj(.int(try readLong(length: Int(try readU32()))))) // LONG4
            case 0x47: stack.append(Obj(.double(try readDoubleBE())))  // BINFLOAT

            // Strings / bytes.
            case 0x58: stack.append(Obj(.string(try readString(length: Int(try readU32()))))) // BINUNICODE
            case 0x8c: stack.append(Obj(.string(try readString(length: Int(try readByte()))))) // SHORT_BINUNICODE
            case 0x8d: stack.append(Obj(.string(try readString(length: try count(try readU64())))))  // BINUNICODE8
            case 0x42: try skip(Int(try readU32())); stack.append(Obj(.opaque)) // BINBYTES
            case 0x43: try skip(Int(try readByte())); stack.append(Obj(.opaque)) // SHORT_BINBYTES
            case 0x8e: try skip(try count(try readU64())); stack.append(Obj(.opaque)) // BINBYTES8

            // Memo.
            case 0x71: memo[Int(try readByte())] = try top()      // BINPUT
            case 0x72: memo[Int(try readU32())] = try top()       // LONG_BINPUT
            case 0x94: memo[memo.count] = try top()               // MEMOIZE
            case 0x68: stack.append(try memoGet(Int(try readByte()))) // BINGET
            case 0x6a: stack.append(try memoGet(Int(try readU32()))) // LONG_BINGET

            // Tuples.
            case 0x29: stack.append(Obj(.tuple([])))              // EMPTY_TUPLE
            case 0x85: stack.append(Obj(.tuple([try pop()])))     // TUPLE1
            case 0x86: let b = try pop(); let a = try pop(); stack.append(Obj(.tuple([a, b]))) // TUPLE2
            case 0x87: let c = try pop(); let b = try pop(); let a = try pop(); stack.append(Obj(.tuple([a, b, c]))) // TUPLE3
            case 0x74: stack.append(Obj(.tuple(try popToMark())))  // TUPLE

            // Lists.
            case 0x5d: stack.append(Obj(.list([])))               // EMPTY_LIST
            case 0x61: try appendToList([try pop()])              // APPEND
            case 0x65: try appendToList(try popToMark())          // APPENDS

            // Dicts.
            case 0x7d: stack.append(Obj(.dict([])))               // EMPTY_DICT
            case 0x73: let v = try pop(); let k = try pop(); try setItems([(k, v)]) // SETITEM
            case 0x75: try setItems(try popPairsToMark())         // SETITEMS

            // Globals / reduction / build / persistent ids.
            case 0x63: stack.append(Obj(.global(try readLine(), try readLine()))) // GLOBAL
            case 0x93: let name = try pop(); let module = try pop(); stack.append(try stackGlobal(module, name)) // STACK_GLOBAL
            case 0x51: try binPersistentId()                      // BINPERSID
            case 0x52: try reduce()                               // REDUCE
            case 0x62: try build()                                // BUILD
            case 0x81: _ = try pop(); _ = try pop(); stack.append(Obj(.opaque)) // NEWOBJ (cls,args -> opaque)

            default:
                throw TorchCheckpointError.unsupportedOpcode(opcode)
            }
        }

        let root = try pop()
        return try convert(root, depth: 0)
    }

    // MARK: Stack helpers

    private func top() throws -> Obj {
        guard let obj = stack.last else { throw TorchCheckpointError.malformedPickle("empty stack") }
        return obj
    }

    private func pop() throws -> Obj {
        guard let obj = stack.popLast() else { throw TorchCheckpointError.malformedPickle("empty stack") }
        return obj
    }

    private func popToMark() throws -> [Obj] {
        var items: [Obj] = []
        while let obj = stack.popLast() {
            if case .mark = obj.kind { return items.reversed() }
            items.append(obj)
        }
        throw TorchCheckpointError.malformedPickle("missing mark")
    }

    private func popPairsToMark() throws -> [(Obj, Obj)] {
        let flat = try popToMark()
        guard flat.count % 2 == 0 else { throw TorchCheckpointError.malformedPickle("odd dict items") }
        return stride(from: 0, to: flat.count, by: 2).map { (flat[$0], flat[$0 + 1]) }
    }

    // `existing + items` would rebuild the whole backing array per opcode → O(N²) for
    // a pickle of N repeated APPEND/SETITEMs. Instead, drop the enum's reference to the
    // array before appending so the extracted copy is uniquely owned and grows in place
    // (amortized O(1)), keeping the whole VM phase linear in the pickle size.
    private func appendToList(_ items: [Obj]) throws {
        let target = try top()
        guard case .list(var existing) = target.kind else {
            throw TorchCheckpointError.malformedPickle("APPEND target is not a list")
        }
        target.kind = .opaque
        existing.append(contentsOf: items)
        target.kind = .list(existing)
    }

    private func setItems(_ pairs: [(Obj, Obj)]) throws {
        let target = try top()
        guard case .dict(var existing) = target.kind else {
            throw TorchCheckpointError.malformedPickle("SETITEM target is not a dict")
        }
        target.kind = .opaque
        existing.append(contentsOf: pairs)
        target.kind = .dict(existing)
    }

    private func memoGet(_ index: Int) throws -> Obj {
        guard let obj = memo[index] else { throw TorchCheckpointError.malformedPickle("bad memo index \(index)") }
        return obj
    }

    // MARK: Globals, reduction, build

    private func stackGlobal(_ module: Obj, _ name: Obj) throws -> Obj {
        guard case .string(let m) = module.kind, case .string(let n) = name.kind else {
            throw TorchCheckpointError.malformedPickle("STACK_GLOBAL operands not strings")
        }
        return Obj(.global(m, n))
    }

    private func binPersistentId() throws {
        // torch persistent ids are the tuple ('storage', <StorageType>, key, device, numel).
        let pid = try pop()
        guard case .tuple(let fields) = pid.kind, fields.count >= 5,
              case .string(let tag) = fields[0].kind, tag == "storage",
              case .global(_, let storageType) = fields[1].kind,
              case .string(let key) = fields[2].kind,
              case .int(let numel) = fields[4].kind else {
            throw TorchCheckpointError.malformedPickle("unexpected persistent id")
        }
        let dtype = try Self.dtype(forStorageType: storageType)
        stack.append(Obj(.storage(dtype: dtype, key: key, numel: Int(numel))))
    }

    private func reduce() throws {
        let args = try pop()
        let callable = try pop()
        guard case .global(let module, let name) = callable.kind else {
            // Reducing a non-global (should not occur in this format) — stay inert.
            stack.append(Obj(.opaque))
            return
        }

        switch (module, name) {
        case ("collections", "OrderedDict"), ("builtins", "dict"),
             ("__builtin__", "dict"), ("collections", "defaultdict"):
            stack.append(try Self.dict(fromReduceArgs: args))

        case ("torch._utils", "_rebuild_tensor_v2"),
             ("torch._utils", "_rebuild_tensor"):
            stack.append(try rebuildTensor(args))

        case ("torch._utils", "_rebuild_parameter"):
            // _rebuild_parameter(data, requires_grad, backward_hooks) — unwrap the tensor.
            guard case .tuple(let fields) = args.kind, let first = fields.first else {
                throw TorchCheckpointError.malformedPickle("_rebuild_parameter args")
            }
            stack.append(first)

        default:
            // Any other reducer (numpy scalars, Fraction, codecs, hostile globals):
            // NEVER executed. The object is inert.
            stack.append(Obj(.opaque))
        }
    }

    private func build() throws {
        // obj.__setstate__(state). We keep obj as-is (opaque stays opaque; a dict
        // absorbs a dict state), and never call user code.
        let state = try pop()
        let obj = try top()
        if case .dict(let existing) = obj.kind, case .dict(let extra) = state.kind {
            obj.kind = .dict(existing + extra)
        }
    }

    private static func dict(fromReduceArgs args: Obj) throws -> Obj {
        // OrderedDict()/dict() are constructed empty here and filled by SETITEMS.
        // If args carry an iterable of pairs, seed from it; otherwise empty.
        guard case .tuple(let fields) = args.kind, let first = fields.first else {
            return Obj(.dict([]))
        }
        if case .list(let items) = first.kind {
            let pairs: [(Obj, Obj)] = items.compactMap { item in
                if case .tuple(let kv) = item.kind, kv.count == 2 { return (kv[0], kv[1]) }
                return nil
            }
            return Obj(.dict(pairs))
        }
        return Obj(.dict([]))
    }

    private func rebuildTensor(_ args: Obj) throws -> Obj {
        guard case .tuple(let fields) = args.kind, fields.count >= 4,
              case .storage(let dtype, let key, let numel) = fields[0].kind,
              case .int(let offset) = fields[1].kind else {
            throw TorchCheckpointError.malformedPickle("_rebuild_tensor_v2 args")
        }
        let size = try Self.intList(fields[2])
        let stride = try Self.intList(fields[3])
        let tensor = try materialize(dtype: dtype, key: key, storageNumel: numel,
                                     storageOffset: Int(offset), size: size, stride: stride)
        return Obj(.tensor(tensor))
    }

    /// Slices the raw storage bytes for one tensor, validating that the layout is a
    /// contiguous, in-bounds view so the emitted bytes can never be silently wrong.
    /// All size/offset arithmetic is overflow-checked and non-negative-guarded so a
    /// hostile or corrupt descriptor throws a typed error instead of trapping.
    private func materialize(dtype: TorchTensor.DType, key: String, storageNumel: Int,
                             storageOffset: Int, size: [Int], stride: [Int]) throws -> TorchTensor {
        let elementSize = dtype.byteWidth
        guard storageNumel >= 0, storageOffset >= 0, size.allSatisfy({ $0 >= 0 }) else {
            throw TorchCheckpointError.unsupportedTensorLayout("\(key): negative numel/offset/size")
        }
        let blob = try storage(key)
        let expectedBytes = try mul(storageNumel, elementSize, key)
        guard blob.count == expectedBytes else {
            throw TorchCheckpointError.storageSizeMismatch(
                "storage \(key): \(blob.count) bytes, expected \(expectedBytes)")
        }
        // Overflow-checked product of the dimensions.
        var elementCount = 1
        for dimension in size { elementCount = try mul(elementCount, dimension, key) }
        // Reject anything that isn't a plain contiguous, in-bounds slice — a
        // non-contiguous view would require gathering and a naive slice would corrupt.
        let expectedStride = Self.contiguousStride(size)
        guard elementCount <= 1 || stride == expectedStride else {
            throw TorchCheckpointError.unsupportedTensorLayout(
                "\(key): non-contiguous stride \(stride) for size \(size)")
        }
        let (upperElement, overflow) = storageOffset.addingReportingOverflow(elementCount)
        guard !overflow, upperElement <= storageNumel else {
            throw TorchCheckpointError.unsupportedTensorLayout(
                "\(key): view exceeds storage \(storageNumel)")
        }
        // start/end are bounded by expectedBytes == blob.count, so no further overflow.
        let start = try mul(storageOffset, elementSize, key)
        let end = try mul(upperElement, elementSize, key)
        let bytes = blob.subdata(in: start..<end)
        return TorchTensor(dtype: dtype, shape: size, data: bytes)
    }

    private func mul(_ a: Int, _ b: Int, _ key: String) throws -> Int {
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw TorchCheckpointError.unsupportedTensorLayout("\(key): size arithmetic overflow") }
        return product
    }

    // MARK: Byte reading

    private func readByte() throws -> UInt8 {
        guard pos < bytes.count else { throw TorchCheckpointError.truncatedPickle }
        defer { pos += 1 }
        return bytes[pos]
    }

    private func readU16() throws -> Int {
        try requireBytes(2); defer { pos += 2 }
        return Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8)
    }

    private func readU32() throws -> UInt32 {
        try requireBytes(4); defer { pos += 4 }
        return UInt32(bytes[pos]) | (UInt32(bytes[pos + 1]) << 8)
            | (UInt32(bytes[pos + 2]) << 16) | (UInt32(bytes[pos + 3]) << 24)
    }

    private func readI32() throws -> Int32 { Int32(bitPattern: try readU32()) }

    private func readU64() throws -> UInt64 {
        try requireBytes(8); defer { pos += 8 }
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(bytes[pos + i]) << (8 * i) }
        return value
    }

    private func readDoubleBE() throws -> Double {
        try requireBytes(8); defer { pos += 8 }
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(bytes[pos + i]) } // big-endian per pickle
        return Double(bitPattern: value)
    }

    /// Little-endian two's-complement integer of `length` bytes (LONG1/LONG4).
    private func readLong(length: Int) throws -> Int64 {
        guard length >= 0 else { throw TorchCheckpointError.malformedPickle("negative long length") }
        if length == 0 { return 0 }
        guard length <= 8 else { throw TorchCheckpointError.malformedPickle("long exceeds 64 bits") }
        try requireBytes(length); defer { pos += length }
        var value: UInt64 = 0
        for i in 0..<length { value |= UInt64(bytes[pos + i]) << (8 * i) }
        // Sign-extend from the top byte.
        if bytes[pos + length - 1] & 0x80 != 0, length < 8 {
            value |= ~UInt64(0) << (8 * length)
        }
        return Int64(bitPattern: value)
    }

    private func readString(length: Int) throws -> String {
        guard length >= 0 else { throw TorchCheckpointError.malformedPickle("negative string length") }
        try requireBytes(length); defer { pos += length }
        return String(decoding: bytes[pos..<(pos + length)], as: UTF8.self)
    }

    /// A newline-terminated line (GLOBAL's module/name operands).
    private func readLine() throws -> String {
        var out = [UInt8]()
        while pos < bytes.count {
            let byte = bytes[pos]; pos += 1
            if byte == 0x0a { return String(decoding: out, as: UTF8.self) }
            out.append(byte)
        }
        throw TorchCheckpointError.truncatedPickle
    }

    private func skip(_ length: Int) throws {
        guard length >= 0 else { throw TorchCheckpointError.malformedPickle("negative length") }
        try requireBytes(length)
        pos += length
    }

    /// Overflow-safe remaining-bytes check (a huge `length` can't overflow `pos + length`).
    private func requireBytes(_ length: Int) throws {
        guard length >= 0, length <= bytes.count - pos else { throw TorchCheckpointError.truncatedPickle }
    }

    /// Narrows a 64-bit length/count to `Int` without trapping on a hostile value
    /// (a length above `Int.max` — or simply larger than the stream — is truncated).
    private func count(_ value: UInt64) throws -> Int {
        guard let n = Int(exactly: value) else { throw TorchCheckpointError.truncatedPickle }
        return n
    }

    // MARK: Conversion to the public value model

    /// Nodes currently on the conversion recursion stack — DFS "gray" set for cycle
    /// detection (insert on entry, remove on exit), cheaper than copying a set per node.
    private var converting: Set<ObjectIdentifier> = []

    /// Converts the intermediate graph to the public value model. Three bounds keep a
    /// hostile pickle from exhausting the machine: a cycle guard (`converting`), a depth
    /// cap (deep unique nesting → stack overflow), and a global node budget (a shared
    /// memo DAG re-expanding to exponential size — the pickle "billion laughs").
    private func convert(_ obj: Obj, depth: Int) throws -> TorchValue {
        guard depth <= TorchCheckpointReader.maxNestingDepth else {
            throw TorchCheckpointError.malformedPickle("nesting too deep")
        }
        nodeBudget -= 1
        guard nodeBudget >= 0 else { throw TorchCheckpointError.malformedPickle("object graph too large") }

        // Guard against pathological cyclic memo references (never present in weights).
        let identity = ObjectIdentifier(obj)
        if converting.contains(identity) { return .opaque }
        converting.insert(identity)
        defer { converting.remove(identity) }
        let next = depth + 1

        switch obj.kind {
        case .none: return .none
        case .bool(let b): return .boolean(b)
        case .int(let i): return .integer(i)
        case .double(let d): return .double(d)
        case .string(let s): return .string(s)
        case .global(let m, let n): return .global(module: m, name: n)
        case .tensor(let t): return .tensor(t)
        case .tuple(let items): return .tuple(try items.map { try convert($0, depth: next) })
        case .list(let items): return .list(try items.map { try convert($0, depth: next) })
        case .dict(let pairs):
            return .dictionary(try pairs.map {
                (try convert($0.0, depth: next), try convert($0.1, depth: next))
            })
        case .mark, .storage, .opaque:
            return .opaque
        }
    }

    // MARK: Static helpers

    private static func dtype(forStorageType name: String) throws -> TorchTensor.DType {
        switch name {
        case "FloatStorage": return .float32
        case "DoubleStorage": return .float64
        case "HalfStorage": return .float16
        case "BFloat16Storage": return .bfloat16
        case "LongStorage": return .int64
        case "IntStorage": return .int32
        case "ShortStorage": return .int16
        case "CharStorage": return .int8
        case "ByteStorage": return .uint8
        case "BoolStorage": return .bool
        default: throw TorchCheckpointError.unsupportedStorageType(name)
        }
    }

    private static func intList(_ obj: Obj) throws -> [Int] {
        let items: [Obj]
        switch obj.kind {
        case .tuple(let t): items = t
        case .list(let l): items = l
        default: throw TorchCheckpointError.malformedPickle("expected an int sequence")
        }
        return try items.map {
            guard case .int(let i) = $0.kind else {
                throw TorchCheckpointError.malformedPickle("expected int in sequence")
            }
            return Int(i)
        }
    }

    private static func contiguousStride(_ size: [Int]) -> [Int] {
        guard !size.isEmpty else { return [] }
        var stride = [Int](repeating: 1, count: size.count)
        for i in stride.indices.dropLast().reversed() { stride[i] = stride[i + 1] * size[i + 1] }
        return stride
    }
}
