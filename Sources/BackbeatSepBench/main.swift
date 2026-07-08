import AVFoundation
import BackbeatCore
import BackbeatSeparationMLX
import Darwin
import Foundation

// BackbeatSepBench — dev-time measurement tooling for the native-engine quality
// gates (architecture §4). Given a song and a `StemSeparating`, it reports
// wall-clock, peak RSS, and post-completion RSS, plus per-stem SI-SDR against the
// cached demucs oracle (G1) and the MPS-vs-oracle calibration band. It runs on
// any machine and prints one metric per line.
//
// Task 6 shipped it with STUB separators only (`--engine silent|oracle`) so the
// whole harness — oracle loading, SI-SDR, the memory probes, the table — was
// exercised before the real engine existed. `--engine custom` runs the shipping
// custom engine; the vendored port's `--engine mlx` died with the Phase 5
// cut-over. It is never built into the shipped app.

// MARK: - CLI

struct BenchOptions {
    var engine = EngineKind.silent
    var oracleRoot: URL?
    var song: URL?
    var thresholds = StemParityThresholds.g1
    /// When set, run the cancellation-latency probe (gate G4) instead of a normal
    /// bench: start separating, cancel after this many seconds, measure how long
    /// until the engine cooperatively stops.
    var cancelAfter: Double?
    /// When set, write the engine's separated stems as float WAVs to this dir
    /// (`<key>_<engine>_<stem>.wav`) so the G1 human blind-listening sign-off can
    /// A/B them against the oracle stems.
    var writeStems: URL?
    /// When set, the G3 post-completion probe samples `phys_footprint` once per
    /// second for this many seconds after `releaseGPUMemory()` and reports the
    /// instant read, the decay series, and the settled read separately. The
    /// instant read alone over-reports for MLX engines: Metal/MLX buffer
    /// reclamation completes asynchronously after the process releases its
    /// references, so `phys_footprint` sampled immediately still counts pages
    /// that are already on their way back to the OS.
    var settleSeconds: Double?
}

enum EngineKind: String {
    case silent
    case oracle
    case custom

    /// Engines that run on MLX and need the htdemucs checkpoint.
    var needsWeights: Bool {
        self == .custom
    }
}

enum BenchError: LocalizedError {
    case usage(String)
    case oracle(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message): "usage: \(message)"
        case .oracle(let message): "oracle: \(message)"
        }
    }
}

func parseArguments(_ arguments: [String]) throws -> BenchOptions {
    var options = BenchOptions()
    var index = 0
    func nextValue(_ flag: String) throws -> String {
        index += 1
        guard index < arguments.count else { throw BenchError.usage("\(flag) requires a value") }
        return arguments[index]
    }
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--engine":
            let raw = try nextValue(argument)
            guard let kind = EngineKind(rawValue: raw) else {
                throw BenchError.usage("unknown engine '\(raw)' (silent | oracle | custom)")
            }
            options.engine = kind
        case "--oracle":
            options.oracleRoot = URL(fileURLWithPath: try nextValue(argument), isDirectory: true)
        case "--song":
            options.song = URL(fileURLWithPath: try nextValue(argument))
        case "--cancel-after":
            guard let seconds = Double(try nextValue(argument)) else {
                throw BenchError.usage("--cancel-after requires a number of seconds")
            }
            options.cancelAfter = seconds
        case "--write-stems":
            options.writeStems = URL(fileURLWithPath: try nextValue(argument), isDirectory: true)
        case "--settle":
            guard let seconds = Double(try nextValue(argument)), seconds > 0 else {
                throw BenchError.usage("--settle requires a positive number of seconds")
            }
            options.settleSeconds = seconds
        case "-h", "--help":
            print(helpText)
            exit(0)
        default:
            throw BenchError.usage("unexpected argument '\(argument)'")
        }
        index += 1
    }
    return options
}

let helpText = """
BackbeatSepBench — native-engine parity/memory benchmark (dev-only)

  swift run BackbeatSepBench --engine <silent|oracle|custom> [--oracle <dir>] [--song <path>]

Engines
  silent   returns silence shaped like the source (plumbing self-test; SI-SDR = -inf)
  oracle   returns the cached oracle stems (harness self-test; SI-SDR = +inf)
  custom   the purpose-written custom engine — the shipping engine (D1-A, Phase 5)

Selecting songs
  --song <path> --oracle <root>   bench one song; oracle stems looked up by its basename
  --oracle <root>                 bench every song recorded in <root>/manifest.json
  --song <path>                   bench one song with no SI-SDR (timing/memory only)

Probes
  --settle <seconds>    sample phys_footprint 1/s after releaseGPUMemory() and report
                        instant / series / settled reads (G3 memory-after; the instant
                        read over-counts pages Metal is still reclaiming asynchronously)
  --cancel-after <s>    G4 cancellation-latency probe instead of a normal bench
  --write-stems <dir>   write the engine stems as float WAVs for the G1 listening A/B

The oracle tree is produced by script/generate_oracle.sh.
"""

// MARK: - Oracle manifest

struct OracleManifest: Decodable {
    struct Generator: Decodable {
        var demucs: String?
        var torch: String?
        var overlap: Double?
        var device: String?
        var model: String?
    }

    struct Song: Decodable {
        var key: String
        var input: String
        var stems: String
        var calibrationMPS: String?

        enum CodingKeys: String, CodingKey {
            case key, input, stems
            case calibrationMPS = "calibration_mps"
        }
    }

    var generator: Generator?
    var songs: [Song]
}

func loadManifest(oracleRoot: URL) throws -> OracleManifest {
    let url = oracleRoot.appendingPathComponent("manifest.json")
    guard let data = try? Data(contentsOf: url) else {
        throw BenchError.oracle("no manifest.json at \(url.path) — run script/generate_oracle.sh first")
    }
    do {
        return try JSONDecoder().decode(OracleManifest.self, from: data)
    } catch {
        throw BenchError.oracle("could not parse \(url.path): \(error)")
    }
}

/// One benchmarking unit: a source mixture, its oracle stem directory, and an
/// optional MPS calibration stem directory.
struct BenchSong {
    var key: String
    var source: URL
    var oracleStems: URL?
    var calibrationStems: URL?
}

/// Derive the oracle directory/key from a source filename, mirroring the bash
/// `song_key()` in script/generate_oracle.sh EXACTLY (`tr -c 'A-Za-z0-9._-' '_'`
/// over the extensionless basename). The two MUST agree, or the single-song
/// `--song X --oracle root` lookup cannot find the stems the script wrote — e.g.
/// the dev file "15 Gett Off" maps to the on-disk key/dir "15_Gett_Off".
/// Operating on UTF-8 bytes reproduces `tr`'s per-byte semantics (a multibyte
/// character becomes one '_' per byte, as `tr` does).
func songKey(for source: URL) -> String {
    let base = source.deletingPathExtension().lastPathComponent
    func isAllowed(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
    }
    return String(decoding: base.utf8.map { isAllowed($0) ? $0 : UInt8(ascii: "_") }, as: UTF8.self)
}

/// Resolve which songs to bench from the options: an explicit `--song` (single,
/// oracle looked up under `--oracle` by basename) or every song in the manifest.
func resolveSongs(_ options: BenchOptions) throws -> (songs: [BenchSong], generator: OracleManifest.Generator?) {
    if let song = options.song {
        let key = songKey(for: song)
        var oracleStems: URL?
        var calibrationStems: URL?
        var generator: OracleManifest.Generator?
        if let root = options.oracleRoot {
            // Accept either the oracle ROOT (look up by manifest/key) or a
            // per-song directory that directly holds the four stem WAVs.
            if let manifest = try? loadManifest(oracleRoot: root),
               let entry = manifest.songs.first(where: { $0.key == key }) {
                oracleStems = root.appendingPathComponent(entry.stems, isDirectory: true)
                calibrationStems = entry.calibrationMPS.map { root.appendingPathComponent($0, isDirectory: true) }
                generator = manifest.generator
            } else if hasStemWAVs(root) {
                oracleStems = root
            } else if hasStemWAVs(root.appendingPathComponent(key, isDirectory: true)) {
                oracleStems = root.appendingPathComponent(key, isDirectory: true)
            }
        }
        return ([BenchSong(key: key, source: song, oracleStems: oracleStems, calibrationStems: calibrationStems)], generator)
    }

    guard let root = options.oracleRoot else {
        throw BenchError.usage("pass --song <path>, or --oracle <root> to bench every manifest song")
    }
    let manifest = try loadManifest(oracleRoot: root)
    let songs = manifest.songs.map { entry in
        BenchSong(
            key: entry.key,
            source: URL(fileURLWithPath: entry.input),
            oracleStems: root.appendingPathComponent(entry.stems, isDirectory: true),
            calibrationStems: entry.calibrationMPS.map { root.appendingPathComponent($0, isDirectory: true) }
        )
    }
    guard !songs.isEmpty else { throw BenchError.oracle("manifest lists no songs") }
    return (songs, manifest.generator)
}

func hasStemWAVs(_ directory: URL) -> Bool {
    SeparatedStems.Stem.allCases.allSatisfy {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0.rawValue).wav").path)
    }
}

// MARK: - Multi-channel decode (dev tooling; the app decodes via StemMixdown/AudioPCMDecoder)

enum AudioChannels {
    static func decode(_ url: URL) throws -> (channels: [[Float]], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        let total = Int(file.length)
        guard channelCount > 0, total > 0 else {
            throw BenchError.oracle("empty or unreadable audio at \(url.path)")
        }
        var channels = [[Float]](repeating: [], count: channelCount)
        for channel in 0..<channelCount { channels[channel].reserveCapacity(total) }

        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw BenchError.oracle("could not allocate decode buffer for \(url.path)")
        }
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let read = Int(buffer.frameLength)
            guard read > 0, let data = buffer.floatChannelData else { break }
            for channel in 0..<channelCount {
                channels[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: read))
            }
        }
        return (channels, format.sampleRate)
    }
}

// MARK: - Stub separators (Task 6). The real engine lands in Task 7/8.

/// Returns silence shaped like the source. Exercises the -inf SI-SDR path and the
/// timing/memory probes without any model.
struct SilentStubSeparator: StemSeparating {
    func separate(source: URL, progress: StemSeparationProgress?) async throws -> SeparatedStems {
        let decoded = try AudioChannels.decode(source)
        let silent = decoded.channels.map { [Float](repeating: 0, count: $0.count) }
        progress?(1)
        return SeparatedStems(sampleRate: decoded.sampleRate, drums: silent, bass: silent, other: silent, vocals: silent)
    }
}

/// Returns the cached oracle stems for the song. A perfect "engine": SI-SDR reads
/// as +inf, so it self-tests that the whole harness (oracle load → SI-SDR → table
/// → gate verdict) reports GO on a known-good separation.
struct OracleStubSeparator: StemSeparating {
    let stemsDirectory: URL

    func separate(source: URL, progress: StemSeparationProgress?) async throws -> SeparatedStems {
        var stems: [SeparatedStems.Stem: [[Float]]] = [:]
        var sampleRate = 0.0
        for stem in SeparatedStems.Stem.allCases {
            let decoded = try AudioChannels.decode(stemsDirectory.appendingPathComponent("\(stem.rawValue).wav"))
            stems[stem] = decoded.channels
            sampleRate = decoded.sampleRate
        }
        progress?(1)
        return SeparatedStems(
            sampleRate: sampleRate,
            drums: stems[.drums] ?? [],
            bass: stems[.bass] ?? [],
            other: stems[.other] ?? [],
            vocals: stems[.vocals] ?? []
        )
    }
}

/// Resolve the htdemucs `.th` for the MLX engine: an explicit `BACKBEAT_WEIGHTS`
/// override, else the machine-local weights cache the app's build script
/// (`script/build_and_run.sh`) populates and verifies by SHA-256. Shared by the
/// preflight check and `makeSeparator` so the verdict and the actual render bind to the
/// same path.
func resolveMLXWeights() throws -> URL {
    let fm = FileManager.default
    if let override = ProcessInfo.processInfo.environment["BACKBEAT_WEIGHTS"], !override.isEmpty {
        let url = URL(fileURLWithPath: override)
        guard fm.fileExists(atPath: url.path) else {
            throw BenchError.usage("BACKBEAT_WEIGHTS points at a missing file: \(url.path)")
        }
        return url
    }
    let cached = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/backline-boost/weights/\(WeightsIdentity.htdemucs.filename)")
    guard fm.fileExists(atPath: cached.path) else {
        throw BenchError.usage(
            "--engine custom needs the htdemucs weights. Build the app once "
                + "(./script/build_and_run.sh populates \(cached.deletingLastPathComponent().path)), "
                + "or set BACKBEAT_WEIGHTS to a local \(WeightsIdentity.htdemucs.filename).")
    }
    return cached
}

/// Global engine-availability check, run once before any song. A missing checkpoint is a
/// configuration error (exit 2), surfaced up front so a spike script under `set -e` fails
/// loudly rather than per-song.
func preflightEngine(_ options: BenchOptions) throws {
    if options.engine.needsWeights {
        _ = try resolveMLXWeights()
    }
}

func makeSeparator(_ options: BenchOptions, song: BenchSong) throws -> StemSeparating {
    switch options.engine {
    case .silent:
        return SilentStubSeparator()
    case .oracle:
        guard let stems = song.oracleStems, hasStemWAVs(stems) else {
            throw BenchError.oracle("--engine oracle needs the cached oracle stems for '\(song.key)' (run script/generate_oracle.sh)")
        }
        return OracleStubSeparator(stemsDirectory: stems)
    case .custom:
        // BACKBEAT_MLX_BATCH is the A/B knob; the engine's measured default is 1
        // (see CustomHTDemucsSeparator.init).
        let batch = ProcessInfo.processInfo.environment["BACKBEAT_MLX_BATCH"].flatMap(Int.init) ?? 1
        return CustomHTDemucsSeparator(weightsURL: try resolveMLXWeights(), batchSize: batch)
    }
}

// MARK: - Stem WAV writer (for the G1 listening sign-off)

/// Write an engine's stems as float WAVs (`<key>_<engine>_<stem>.wav`) so they can
/// be blind-A/B'd against the oracle stems.
func writeStemsWAV(_ stems: SeparatedStems, key: String, engine: String, to directory: URL) {
    do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    catch { row("write_stems", "error creating dir: \(error.localizedDescription)"); return }
    for (stem, channels) in stems.byStem {
        let url = directory.appendingPathComponent("\(key)_\(engine)_\(stem.rawValue).wav")
        do { try writeWAV(channels: channels, sampleRate: stems.sampleRate, to: url) }
        catch { row("write_stems", "error \(stem.rawValue): \(error.localizedDescription)"); return }
    }
    row("wrote_stems", directory.path + "/\(key)_\(engine)_*.wav")
}

func writeWAV(channels: [[Float]], sampleRate: Double, to url: URL) throws {
    let channelCount = channels.count
    let frames = channels.map(\.count).max() ?? 0
    guard channelCount > 0, frames > 0 else { return }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channelCount,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let format = file.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
        throw BenchError.oracle("could not allocate write buffer for \(url.lastPathComponent)")
    }
    buffer.frameLength = AVAudioFrameCount(frames)
    if let dst = buffer.floatChannelData {
        for c in 0 ..< Int(format.channelCount) {
            let src = channels[min(c, channelCount - 1)]
            let out = dst[c]
            for t in 0 ..< frames { out[t] = t < src.count ? src[t] : 0 }
        }
    }
    try file.write(from: buffer)
}

// MARK: - Memory probes (Darwin)

enum MemoryProbe {
    /// Process-lifetime peak resident size. On Darwin `ru_maxrss` is in BYTES
    /// (Linux reports KiB). Monotonic across the process, so for multi-song runs
    /// it is the peak over ALL songs so far, not per-song.
    static func peakResidentBytes() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(max(0, usage.ru_maxrss))
    }

    /// Current physical footprint — the figure Activity Monitor's "Memory"
    /// column reports, and the one the G3 memory-after gate measures.
    static func currentFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }
}

// MARK: - Table output

func megabytes(_ bytes: UInt64) -> String {
    String(format: "%.1f", Double(bytes) / (1024 * 1024))
}

func decibels(_ value: Double) -> String {
    if value == .infinity { return "inf" }
    if value == -.infinity { return "-inf" }
    return String(format: "%.2f", value)
}

func row(_ label: String, _ value: String) {
    print(label.padding(toLength: 20, withPad: " ", startingAt: 0) + value)
}

// MARK: - Bench one song

/// Benchmark one song. Returns `true` when the harness produced its numbers, and
/// `false` only on an EXECUTION error (separation crashed, an oracle stem could
/// not be read) — a `parity_gate FAIL` is a legitimate informational result and
/// keeps the exit code 0, because judging GO/NO-GO from the printed numbers is
/// the reader's job (architecture Task 7 Step 3), not the tool's.
@discardableResult
func bench(_ song: BenchSong, options: BenchOptions, generator: OracleManifest.Generator?) async -> Bool {
    print("# BackbeatSepBench — \(song.key)")
    row("engine", options.engine.rawValue)
    if let generator {
        if let demucs = generator.demucs { row("oracle_demucs", demucs) }
        if let torch = generator.torch { row("oracle_torch", torch) }
        if let device = generator.device { row("oracle_device", device) }
    }

    let separator: StemSeparating
    do {
        separator = try makeSeparator(options, song: song)
    } catch {
        row("error", error.localizedDescription)
        print("")
        return false
    }

    // Source shape for the realtime factor.
    var durationSeconds = 0.0
    if let decoded = try? AudioChannels.decode(song.source) {
        row("channels", "\(decoded.channels.count)")
        row("sample_rate_hz", String(format: "%.0f", decoded.sampleRate))
        durationSeconds = Double(decoded.channels.map(\.count).max() ?? 0) / decoded.sampleRate
        row("duration_s", String(format: "%.2f", durationSeconds))
    }

    let clock = ContinuousClock()
    let started = clock.now
    let stems: SeparatedStems
    do {
        stems = try await separator.separate(source: song.source, progress: nil)
    } catch {
        row("error", "separation failed: \(error.localizedDescription)")
        print("")
        return false
    }
    let elapsed = clock.now - started
    let wallClock = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

    // Release the MLX GPU buffer cache before reading the footprint, so
    // post_rss_mb reflects the memory-after (G3) gate, not retained scratch.
    // (The engine also clears in its own `defer`; this is the explicit G3 probe.)
    switch options.engine {
    case .custom: CustomHTDemucsSeparator.releaseGPUMemory()
    case .silent, .oracle: break
    }
    let postFootprint = MemoryProbe.currentFootprintBytes()
    let peak = MemoryProbe.peakResidentBytes()

    row("wall_clock_s", String(format: "%.3f", wallClock))
    if durationSeconds > 0, wallClock > 0 {
        row("realtime_x", String(format: "%.1f", durationSeconds / wallClock))
    }
    row("peak_rss_mb", megabytes(peak))
    if let settle = options.settleSeconds {
        // G3 settle probe: the instant read counts pages Metal/MLX is still
        // handing back asynchronously, so sample the footprint once per second
        // until the settle window closes and report all three views. The
        // settled figure is the G3 memory-after number; the series shows the
        // reclaim decay (and exposes it if the settled read is still drifting,
        // meaning the window was too short).
        row("post_rss_instant_mb", megabytes(postFootprint))
        var series: [UInt64] = []
        var slept = 0.0
        while slept < settle {
            let step = min(1.0, settle - slept)
            try? await Task.sleep(for: .seconds(step))
            slept += step
            series.append(MemoryProbe.currentFootprintBytes())
        }
        row("post_rss_series_mb", series.map(megabytes).joined(separator: " "))
        row("post_rss_settled_mb", megabytes(series.last ?? postFootprint))
    } else {
        row("post_rss_mb", megabytes(postFootprint))
    }

    if let stemsDir = options.writeStems {
        writeStemsWAV(stems, key: song.key, engine: options.engine.rawValue, to: stemsDir)
    }

    guard let oracleStems = song.oracleStems, hasStemWAVs(oracleStems) else {
        row("si_sdr", "n/a (no oracle stems for this song)")
        print("")
        return true
    }

    // Per-stem SI-SDR of the engine output vs the CPU fp32 oracle, plus the
    // MPS-vs-oracle calibration band when the MPS set was generated.
    var oracleChannels: [SeparatedStems.Stem: [[Float]]] = [:]
    var calibrationChannels: [SeparatedStems.Stem: [[Float]]] = [:]
    for stem in SeparatedStems.Stem.allCases {
        oracleChannels[stem] = (try? AudioChannels.decode(oracleStems.appendingPathComponent("\(stem.rawValue).wav")))?.channels
        if let calibration = song.calibrationStems {
            calibrationChannels[stem] = (try? AudioChannels.decode(calibration.appendingPathComponent("\(stem.rawValue).wav")))?.channels
        }
    }

    var gatePassed = true
    var oracleReadable = true
    for stem in SeparatedStems.Stem.allCases {
        guard let oracle = oracleChannels[stem] else {
            row("sisdr_\(stem.rawValue)_db", "n/a (oracle stem unreadable)")
            gatePassed = false
            oracleReadable = false
            continue
        }
        let siSDR = StemSeparationMetrics.signalToDistortionRatioDB(
            referenceChannels: oracle,
            estimateChannels: stems[stem]
        )
        row("sisdr_\(stem.rawValue)_db", decibels(siSDR))

        var floorDB = options.thresholds.minimumDB(for: stem)
        if let calibration = calibrationChannels[stem] {
            let band = StemSeparationMetrics.signalToDistortionRatioDB(
                referenceChannels: oracle,
                estimateChannels: calibration
            )
            row("band_\(stem.rawValue)_db", decibels(band))
            // native ≥ MPS-vs-oracle − margin, on top of the absolute floor.
            if band.isFinite {
                floorDB = max(floorDB, band - options.thresholds.calibrationBandMarginDB)
            }
        }
        let stemPassed = siSDR >= floorDB
        gatePassed = gatePassed && stemPassed
        row("parity_\(stem.rawValue)", "\(stemPassed ? "PASS" : "FAIL") (\(decibels(siSDR)) >= \(decibels(floorDB)))")
    }
    row("parity_gate", gatePassed ? "PASS" : "FAIL")
    print("")
    return oracleReadable
}

// MARK: - Cancellation probe (gate G4)

/// Start separating `song`, cancel after `options.cancelAfter` seconds, and report
/// how long the engine took to cooperatively stop (`cancel_latency_s`) and whether
/// it threw `CancellationError` rather than completing. Gate G4 requires cancel to
/// stop at the next segment boundary (≤ 10 s; ≤ ~2 s / one segment on M5 Pro).
func cancelProbe(_ song: BenchSong, options: BenchOptions) async -> Bool {
    print("# BackbeatSepBench — cancel probe — \(song.key)")
    row("engine", options.engine.rawValue)
    let separator: StemSeparating
    do { separator = try makeSeparator(options, song: song) }
    catch { row("error", error.localizedDescription); return false }

    let clock = ContinuousClock()
    let work = Task { try await separator.separate(source: song.source, progress: nil) }
    try? await Task.sleep(for: .seconds(options.cancelAfter ?? 2))
    let cancelIssued = clock.now
    work.cancel()
    do {
        _ = try await work.value
        row("cancel_result", "COMPLETED (finished before cancel took effect)")
        return false
    } catch is CancellationError {
        let elapsed = clock.now - cancelIssued
        let latency = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        row("cancel_result", "CANCELLED")
        row("cancel_latency_s", String(format: "%.2f", latency))
        row("cancel_gate_10s", latency <= 10 ? "PASS" : "FAIL")
        return true
    } catch {
        row("cancel_result", "ERROR: \(error.localizedDescription)")
        return false
    }
}

// MARK: - Entry

@main
struct BackbeatSepBench {
    static func main() async {
        let options: BenchOptions
        let songs: [BenchSong]
        let generator: OracleManifest.Generator?
        do {
            options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            try preflightEngine(options)
            (songs, generator) = try resolveSongs(options)
        } catch {
            // Configuration/usage errors: couldn't even start. Exit 2.
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            FileHandle.standardError.write(Data((helpText + "\n").utf8))
            exit(2)
        }

        if options.cancelAfter != nil {
            var ok = true
            for song in songs { ok = await cancelProbe(song, options: options) && ok }
            exit(ok ? 0 : 1)
        }

        var allProduced = true
        for song in songs {
            let produced = await bench(song, options: options, generator: generator)
            allProduced = allProduced && produced
        }
        // Exit 1 if any song failed to produce its numbers (execution error);
        // a `parity_gate FAIL` alone does NOT fail the process (see `bench`).
        if !allProduced { exit(1) }
    }
}
