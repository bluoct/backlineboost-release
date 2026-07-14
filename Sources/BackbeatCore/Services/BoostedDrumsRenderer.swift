import Foundation

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

public enum BoostedDrumsRenderError: LocalizedError {
    case missingCommand(String)
    case commandFailed(command: String, status: Int32, output: String)
    case missingStem(URL)
    /// A stem the native engine returned in-memory carried no audio (empty/silent
    /// buffers). The buffer-era analogue of `missingStem(URL)` — there is no on-disk
    /// stem to name, so it identifies the stem by identity (amendment A3).
    case emptyStem(SeparatedStems.Stem)
    case invalidOutput(URL)

    public var errorDescription: String? {
        switch self {
        case .missingCommand(let component):
            // There is no external tool to install and the separation model is bundled
            // with the app, so an unready engine means a broken install — the only
            // actionable remedy is a reinstall.
            "Cannot render: \(component) is not ready. Please reinstall Backline Boost and try again."
        case .commandFailed:
            // Amendment A2: native separation has no subprocess exit code or output to
            // embed, so the copy is a plain retryable-failure message.
            "Drum separation failed for this track. Try rendering it again."
        case .missingStem(let url):
            "Expected audio stem was not created at \(url.path)."
        case .emptyStem(let stem):
            "Separation produced no audio for the \(stem.rawValue) stem."
        case .invalidOutput(let url):
            "Rendered file was not created or is empty at \(url.path)."
        }
    }
}

public struct BoostedDrumsRenderer {
    public let rendersRootURL: URL
    public let bitrate: RenderBitrate
    private let separator: any StemSeparating
    private let stemMixdown: any StemMixing

    // `separator` is required (no default): the real engine
    // (`CustomHTDemucsSeparator`) lives in the MLX target the app injects, and
    // BackbeatCore has no default to offer — a null default would silently compile
    // a broken render path. The other
    // defaults are evaluated per construction, so a renderer built fresh for each job
    // reads the current Settings values (folder + bitrate) at render time.
    public init(
        separator: any StemSeparating,
        rendersRootURL: URL = RenderSettings.effectiveRendersRootURL(),
        bitrate: RenderBitrate = RenderSettings.bitrate(),
        stemMixdown: any StemMixing = StemMixdown()
    ) {
        self.separator = separator
        self.rendersRootURL = rendersRootURL
        self.bitrate = bitrate
        self.stemMixdown = stemMixdown
    }

    public func render(
        track: BackbeatTrack,
        createdAt: Date = Date(),
        progress: RenderProgressHandler? = nil
    ) async throws -> PracticeRenderResult {
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

        await progress?(.separatingStems)
        // The native engine separates in-process and returns float stems in memory —
        // no subprocess, no WAV round-trip (amendment A3). Its per-segment fractional
        // progress is internal (cancellation checkpoints + logging); the pinned
        // 5-stage RenderProgressState order is unchanged. Per amendment A1 there is no
        // MPS→CPU retry — a single in-process GPU attempt; a failure throws here and
        // surfaces through the queue's existing .renderFailed path, and status-driven
        // recovery re-enqueues an interrupted track on the next launch.
        let stems = try await separator.separate(source: track.sourceURL)
        try Self.requireNonEmptyStems(stems)

        await progress?(.mixingDrumsTrack)
        do {
            try await stemMixdown.writeDrums(
                stems: stems,
                outputURL: drumsOutputURL,
                bitrate: bitrate
            )
            await progress?(.mixingDrumlessTrack)
            try await stemMixdown.writeDrumless(
                stems: stems,
                outputURL: drumlessOutputURL,
                bitrate: bitrate
            )
            await progress?(.finalizingOutput)
            try RenderCommandRunner.requireNonEmptyFile(drumsOutputURL)
            try RenderCommandRunner.requireNonEmptyFile(drumlessOutputURL)
        } catch {
            // A half-written pair is referenced by no record (promotion runs only
            // on success) and would leak into the renders folder forever (R3).
            try? FileManager.default.removeItem(at: drumsOutputURL)
            try? FileManager.default.removeItem(at: drumlessOutputURL)
            throw error
        }
        // Best-effort: the new pair is complete and valid at this point — a
        // janitorial failure (renders volume unmounted mid-render, a locked
        // superseded file) must not fail the render, strand the new outputs
        // recordless, or dangle the old records it may already have half-swept.
        try? removeSupersededRenders(keeping: drumsOutputURL, for: track, isSuperseded: BoostedDrumsRenderPlan.isDrumsOutput)
        try? removeSupersededRenders(keeping: drumlessOutputURL, for: track, isSuperseded: BoostedDrumsRenderPlan.isDrumlessOutput)
        await progress?(.complete)
        return PracticeRenderResult(drumsURL: drumsOutputURL, drumlessURL: drumlessOutputURL)
    }

    /// Amendment A3: the buffer-era stem check (the demucs-subprocess era validated
    /// on-disk stem files instead). A stem the engine returned with no channels, or
    /// whose channels are all empty, is unusable — fail with `emptyStem` rather than
    /// letting a silent gap flow into a header-only "successful" output.
    static func requireNonEmptyStems(_ stems: SeparatedStems) throws {
        for (stem, channels) in stems.byStem where channels.allSatisfy(\.isEmpty) {
            throw BoostedDrumsRenderError.emptyStem(stem)
        }
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
