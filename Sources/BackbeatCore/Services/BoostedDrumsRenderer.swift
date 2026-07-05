import Foundation

public struct CommandSpec: Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]

    public init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

public struct FourStemURLs: Equatable, Sendable {
    public let drums: URL
    public let bass: URL
    public let other: URL
    public let vocals: URL

    public init(drums: URL, bass: URL, other: URL, vocals: URL) {
        self.drums = drums
        self.bass = bass
        self.other = other
        self.vocals = vocals
    }

    public var all: [URL] {
        [drums, bass, other, vocals]
    }
}

public struct DrumBoostMixGains: Equatable, Sendable {
    public let drumGainDB: Double
    public let backingGainDB: Double
    public let drumLinearGain: Float
    public let backingLinearGain: Float

    public init(boostDB: Double) {
        let relativeDrumGain = pow(10, max(0, boostDB) / 20)
        let masterCompensation = 1 / sqrt(((relativeDrumGain * relativeDrumGain) + 3) / 4)
        let drumLinearGain = relativeDrumGain * masterCompensation
        let backingLinearGain = masterCompensation
        self.drumLinearGain = Float(drumLinearGain)
        self.backingLinearGain = Float(backingLinearGain)
        self.drumGainDB = Self.db(linearGain: drumLinearGain)
        self.backingGainDB = Self.db(linearGain: backingLinearGain)
    }

    private static func db(linearGain: Double) -> Double {
        20 * log10(max(linearGain, .leastNonzeroMagnitude))
    }
}

public struct DemucsSeparationProfile: Equatable, Sendable {
    public let device: String?
    public let overlap: Double

    public init(device: String?, overlap: Double = 0.1) {
        self.device = device
        self.overlap = overlap
    }

    public static let accelerated = DemucsSeparationProfile(device: "mps")
    public static let tunedCPU = DemucsSeparationProfile(device: nil)

    public var fallbackProfile: DemucsSeparationProfile? {
        guard device != nil else {
            return nil
        }
        return DemucsSeparationProfile(device: nil, overlap: overlap)
    }
}

public enum BoostedDrumsRenderPlan {
    // "boosted_drums" is the legacy single-file variant: kept so old on-disk
    // renders in user libraries keep resolving. Legacy files are superseded via
    // the track's recorded render URLs (LibraryStore.completePracticeRender),
    // not by name prefix: pre-UUID names are ambiguous between same-title tracks.
    public static func outputURL(
        for track: BackbeatTrack,
        rendersRootURL: URL,
        createdAt: Date = Date()
    ) -> URL {
        outputURL(for: track, rendersRootURL: rendersRootURL, folder: "boosted_drums", suffix: "boosted_drums", createdAt: createdAt)
    }

    public static func drumlessOutputURL(
        for track: BackbeatTrack,
        rendersRootURL: URL,
        createdAt: Date = Date()
    ) -> URL {
        outputURL(for: track, rendersRootURL: rendersRootURL, folder: "drumless", suffix: "drumless", createdAt: createdAt)
    }

    public static func drumsOutputURL(
        for track: BackbeatTrack,
        rendersRootURL: URL,
        createdAt: Date = Date()
    ) -> URL {
        outputURL(for: track, rendersRootURL: rendersRootURL, folder: "drums", suffix: "drums", createdAt: createdAt)
    }

    public static func outputFilePrefix(for track: BackbeatTrack) -> String {
        filePrefix(for: track, suffix: "boosted_drums")
    }

    public static func drumlessOutputFilePrefix(for track: BackbeatTrack) -> String {
        filePrefix(for: track, suffix: "drumless")
    }

    public static func drumsOutputFilePrefix(for track: BackbeatTrack) -> String {
        filePrefix(for: track, suffix: "drums")
    }

    public static func isOutput(_ url: URL, for track: BackbeatTrack) -> Bool {
        isOutput(url, prefix: outputFilePrefix(for: track))
    }

    public static func isDrumlessOutput(_ url: URL, for track: BackbeatTrack) -> Bool {
        isOutput(url, prefix: drumlessOutputFilePrefix(for: track))
    }

    public static func isDrumsOutput(_ url: URL, for track: BackbeatTrack) -> Bool {
        isOutput(url, prefix: drumsOutputFilePrefix(for: track))
    }

    private static func outputURL(
        for track: BackbeatTrack,
        rendersRootURL: URL,
        folder: String,
        suffix: String,
        createdAt: Date
    ) -> URL {
        let folderURL = rendersRootURL.appendingPathComponent(folder, isDirectory: true)
        let baseName = filePrefix(for: track, suffix: suffix) + timestamp(createdAt)
        return folderURL.appendingPathComponent(baseName).appendingPathExtension("m4a")
    }

    private static func filePrefix(for track: BackbeatTrack, suffix: String) -> String {
        let title = sanitizedComponent(track.title)
        let artist = track.artist
            .map { sanitizedComponent($0) }
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { [$0] } ?? []
        return ([title] + artist + [suffix, track.id.uuidString])
            .filter { !$0.isEmpty }
            .joined(separator: "_") + "_"
    }

    private static func isOutput(_ url: URL, prefix: String) -> Bool {
        url.pathExtension.lowercased() == "m4a"
            && url.deletingPathExtension().lastPathComponent.hasPrefix(prefix)
    }

    public static func demucsCommand(
        demucsPath: String,
        sourceURL: URL,
        separationRootURL: URL,
        profile: DemucsSeparationProfile = .accelerated
    ) -> CommandSpec {
        var arguments = [
            "--name", "htdemucs",
            "--out", separationRootURL.path
        ]
        if let device = profile.device {
            arguments.append(contentsOf: ["-d", device])
        }
        arguments.append(contentsOf: [
            "--overlap", decimalString(profile.overlap),
            sourceURL.path
        ])

        return CommandSpec(
            executablePath: demucsPath,
            arguments: arguments
        )
    }

    public static func stemDirectory(separationRootURL: URL, sourceURL: URL) -> URL {
        separationRootURL
            .appendingPathComponent("htdemucs", isDirectory: true)
            .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    public static func stemURLs(stemDirectory: URL) -> FourStemURLs {
        FourStemURLs(
            drums: stemDirectory.appendingPathComponent("drums.wav"),
            bass: stemDirectory.appendingPathComponent("bass.wav"),
            other: stemDirectory.appendingPathComponent("other.wav"),
            vocals: stemDirectory.appendingPathComponent("vocals.wav")
        )
    }

    public static func mixCommand(
        ffmpegPath: String,
        stems: FourStemURLs,
        outputURL: URL,
        boostDB: Double,
        bitrate: RenderBitrate = .default
    ) -> CommandSpec {
        let gains = DrumBoostMixGains(boostDB: boostDB)
        let drumGain = dbString(gains.drumGainDB)
        let backingGain = dbString(gains.backingGainDB)
        let filter = "[0:a]volume=\(drumGain)dB[drums];[1:a]volume=\(backingGain)dB[bass];[2:a]volume=\(backingGain)dB[other];[3:a]volume=\(backingGain)dB[vocals];[drums][bass][other][vocals]amix=inputs=4:duration=longest:normalize=0,alimiter=limit=0.98[out]"
        return CommandSpec(
            executablePath: ffmpegPath,
            arguments: [
                "-y",
                "-i", stems.drums.path,
                "-i", stems.bass.path,
                "-i", stems.other.path,
                "-i", stems.vocals.path,
                "-filter_complex", filter,
                "-map", "[out]",
                "-c:a", "aac",
                "-b:a", bitrate.ffmpegArgumentValue,
                outputURL.path
            ]
        )
    }

    public static func drumlessMixCommand(
        ffmpegPath: String,
        stems: FourStemURLs,
        outputURL: URL,
        bitrate: RenderBitrate = .default
    ) -> CommandSpec {
        let filter = "[0:a][1:a][2:a]amix=inputs=3:duration=longest:normalize=0,alimiter=limit=0.98[out]"
        return CommandSpec(
            executablePath: ffmpegPath,
            arguments: [
                "-y",
                "-i", stems.bass.path,
                "-i", stems.other.path,
                "-i", stems.vocals.path,
                "-filter_complex", filter,
                "-map", "[out]",
                "-c:a", "aac",
                "-b:a", bitrate.ffmpegArgumentValue,
                outputURL.path
            ]
        )
    }

    public static func drumsStemCommand(
        ffmpegPath: String,
        stems: FourStemURLs,
        outputURL: URL,
        bitrate: RenderBitrate = .default
    ) -> CommandSpec {
        CommandSpec(
            executablePath: ffmpegPath,
            arguments: [
                "-y",
                "-i", stems.drums.path,
                "-c:a", "aac",
                "-b:a", bitrate.ffmpegArgumentValue,
                outputURL.path
            ]
        )
    }

    private static func sanitizedComponent(_ value: String) -> String {
        value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: date)
    }

    private static func dbString(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func decimalString(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

public struct RenderCommandResult: Equatable, Sendable {
    public let terminationStatus: Int32
    public let output: String

    public init(terminationStatus: Int32, output: String) {
        self.terminationStatus = terminationStatus
        self.output = output
    }
}

public protocol RenderCommandExecuting: Sendable {
    func run(_ command: CommandSpec) async throws -> RenderCommandResult
}

public typealias RenderProgressHandler = @Sendable (RenderProgressState) async -> Void

public struct PracticeRenderResult: Equatable, Sendable {
    public let drumsURL: URL
    public let drumlessURL: URL

    public init(drumsURL: URL, drumlessURL: URL) {
        self.drumsURL = drumsURL
        self.drumlessURL = drumlessURL
    }

    @available(*, deprecated, message: "Use drumsURL for the standalone drums asset. This bridge exists until library promotion moves to two-track assets.")
    public var boostedDrumsURL: URL {
        drumsURL
    }

    @available(*, deprecated, message: "Use init(drumsURL:drumlessURL:) for two-track practice renders.")
    public init(boostedDrumsURL: URL, drumlessURL: URL) {
        self.init(drumsURL: boostedDrumsURL, drumlessURL: drumlessURL)
    }
}

public struct ProcessRenderCommandExecutor: RenderCommandExecuting {
    public init() {}

    public func run(_ command: CommandSpec) async throws -> RenderCommandResult {
        let session = RenderCommandProcessSession(command: command)
        return try await withTaskCancellationHandler {
            try await session.run()
        } onCancel: {
            session.terminate()
        }
    }
}

// Drains one pipe as the child writes so the child can never fill the ~64KB
// kernel pipe buffer and block before exiting; EOF arrives when the child exits.
private final class PipeOutputCollector: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var data = Data()
    private var isFinished = false
    private var continuation: CheckedContinuation<Void, Never>?

    func begin() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            self.lock.lock()
            if chunk.isEmpty {
                self.isFinished = true
                let continuation = self.continuation
                self.continuation = nil
                self.lock.unlock()
                handle.readabilityHandler = nil
                continuation?.resume()
            } else {
                self.data.append(chunk)
                self.lock.unlock()
            }
        }
    }

    func cancelCollection() {
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    // Cancellable: a cancelled run must not stay suspended waiting for EOF
    // that may never come (e.g. a grandchild process inherited the write end).
    func waitUntilEOF() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isFinished {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            cancelCollection()
        }
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class RenderCommandProcessSession: @unchecked Sendable {
    private let command: CommandSpec
    private let process = Process()
    private let lock = NSLock()
    private var didStart = false
    private var wasCancelled = false

    init(command: CommandSpec) {
        self.command = command
    }

    func terminate() {
        lock.lock()
        wasCancelled = true
        let shouldSignal = didStart && process.isRunning
        lock.unlock()
        guard shouldSignal else { return }
        process.terminate()
        // Escalate for tools that ignore SIGTERM so cancellation cannot hang
        // on a child that never exits.
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    func run() async throws -> RenderCommandResult {
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        // Tools like demucs locate ffmpeg via PATH; under launchd that PATH
        // is minimal, so every tool child gets the app's augmented search path.
        process.environment = RenderPreflight.subprocessEnvironment(executablePath: command.executablePath)

        let outputCollector = PipeOutputCollector()
        let errorCollector = PipeOutputCollector()
        process.standardOutput = outputCollector.pipe
        process.standardError = errorCollector.pipe
        outputCollector.begin()
        errorCollector.begin()

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            lock.lock()
            if wasCancelled {
                lock.unlock()
                process.terminationHandler = nil
                outputCollector.cancelCollection()
                errorCollector.cancelCollection()
                continuation.resume(throwing: CancellationError())
                return
            }
            do {
                try process.run()
                didStart = true
                lock.unlock()
            } catch {
                lock.unlock()
                process.terminationHandler = nil
                outputCollector.cancelCollection()
                errorCollector.cancelCollection()
                continuation.resume(throwing: error)
            }
        }

        await outputCollector.waitUntilEOF()
        await errorCollector.waitUntilEOF()
        try Task.checkCancellation()
        return RenderCommandResult(
            terminationStatus: status,
            output: outputCollector.text() + errorCollector.text()
        )
    }
}

public enum BoostedDrumsRenderError: LocalizedError {
    case missingCommand(String)
    case commandFailed(command: String, status: Int32, output: String)
    case missingStem(URL)
    case invalidOutput(URL)

    public var errorDescription: String? {
        switch self {
        case .missingCommand(let command):
            "Required audio tool is not available: \(command). Install \(command) or set its location in Backbeat Settings, then retry."
        case .commandFailed(let command, let status, let output):
            "\(command) failed with exit code \(status). \(output)"
        case .missingStem(let url):
            "Expected audio stem was not created at \(url.path)."
        case .invalidOutput(let url):
            "Rendered file was not created or is empty at \(url.path)."
        }
    }
}

public struct BoostedDrumsRenderer {
    public let rendersRootURL: URL
    public let temporaryRootURL: URL
    public let bitrate: RenderBitrate
    private let demucsProfile: DemucsSeparationProfile
    private let commandResolver: RenderPreflight.CommandResolver
    private let commandRunner: RenderCommandRunner

    // Default arguments are evaluated per construction, so a renderer built
    // fresh for each job reads the current Settings values at render time.
    public init(
        rendersRootURL: URL = RenderSettings.effectiveRendersRootURL(),
        temporaryRootURL: URL = BackbeatFileLocations.temporaryDirectory,
        bitrate: RenderBitrate = RenderSettings.bitrate(),
        demucsProfile: DemucsSeparationProfile = .accelerated,
        commandResolver: @escaping RenderPreflight.CommandResolver = RenderPreflight.resolveCommand(_:),
        commandExecutor: any RenderCommandExecuting = ProcessRenderCommandExecutor()
    ) {
        self.rendersRootURL = rendersRootURL
        self.temporaryRootURL = temporaryRootURL
        self.bitrate = bitrate
        self.demucsProfile = demucsProfile
        self.commandResolver = commandResolver
        self.commandRunner = RenderCommandRunner(executor: commandExecutor)
    }

    public func render(
        track: BackbeatTrack,
        createdAt: Date = Date(),
        progress: RenderProgressHandler? = nil
    ) async throws -> PracticeRenderResult {
        guard let demucsPath = commandResolver("demucs") else {
            throw BoostedDrumsRenderError.missingCommand("demucs")
        }
        guard let ffmpegPath = commandResolver("ffmpeg") else {
            throw BoostedDrumsRenderError.missingCommand("ffmpeg")
        }

        let drumsOutputURL = BoostedDrumsRenderPlan.drumsOutputURL(
            for: track,
            rendersRootURL: rendersRootURL,
            createdAt: createdAt
        )
        let drumlessOutputURL = BoostedDrumsRenderPlan.drumlessOutputURL(
            for: track,
            rendersRootURL: rendersRootURL,
            createdAt: createdAt
        )
        try FileManager.default.createDirectory(
            at: drumsOutputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: drumlessOutputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let jobDirectory = temporaryRootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let separationRootURL = jobDirectory.appendingPathComponent("separated", isDirectory: true)
        try FileManager.default.createDirectory(at: separationRootURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: jobDirectory)
        }

        await progress?(.separatingStems)
        try await commandRunner.runDemucsWithFallback(
            demucsPath: demucsPath,
            sourceURL: track.sourceURL,
            separationRootURL: separationRootURL,
            profile: demucsProfile
        )

        let stemDirectory = BoostedDrumsRenderPlan.stemDirectory(
            separationRootURL: separationRootURL,
            sourceURL: track.sourceURL
        )
        let stems = BoostedDrumsRenderPlan.stemURLs(stemDirectory: stemDirectory)
        try stems.all.forEach(RenderCommandRunner.requireExistingFile(_:))

        await progress?(.mixingDrumsTrack)
        try await commandRunner.runOrThrow(
            BoostedDrumsRenderPlan.drumsStemCommand(
                ffmpegPath: ffmpegPath,
                stems: stems,
                outputURL: drumsOutputURL,
                bitrate: bitrate
            )
        )
        await progress?(.mixingDrumlessTrack)
        try await commandRunner.runOrThrow(
            BoostedDrumsRenderPlan.drumlessMixCommand(
                ffmpegPath: ffmpegPath,
                stems: stems,
                outputURL: drumlessOutputURL,
                bitrate: bitrate
            )
        )
        await progress?(.finalizingOutput)
        try RenderCommandRunner.requireNonEmptyFile(drumsOutputURL)
        try RenderCommandRunner.requireNonEmptyFile(drumlessOutputURL)
        try removeSupersededRenders(keeping: drumsOutputURL, for: track, isSuperseded: BoostedDrumsRenderPlan.isDrumsOutput)
        try removeSupersededRenders(keeping: drumlessOutputURL, for: track, isSuperseded: BoostedDrumsRenderPlan.isDrumlessOutput)
        await progress?(.complete)
        return PracticeRenderResult(drumsURL: drumsOutputURL, drumlessURL: drumlessOutputURL)
    }

    private func removeSupersededRenders(
        keeping outputURL: URL,
        for track: BackbeatTrack,
        isSuperseded: (URL, BackbeatTrack) -> Bool
    ) throws {
        let folderURL = outputURL.deletingLastPathComponent()
        let keepingURL = outputURL.standardizedFileURL
        let contents = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for candidateURL in contents
            where candidateURL.standardizedFileURL != keepingURL && isSuperseded(candidateURL, track)
        {
            try FileManager.default.removeItem(at: candidateURL)
        }
    }
}
