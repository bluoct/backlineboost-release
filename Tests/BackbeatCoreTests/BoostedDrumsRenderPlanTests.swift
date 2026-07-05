import XCTest
@testable import BackbeatCore

final class BoostedDrumsRenderPlanTests: XCTestCase {
    func testDemucsCommandUsesAcceleratedMPSProfileByDefault() {
        let command = BoostedDrumsRenderPlan.demucsCommand(
            demucsPath: "/opt/homebrew/bin/demucs",
            sourceURL: URL(fileURLWithPath: "/tmp/source.m4a"),
            separationRootURL: URL(fileURLWithPath: "/tmp/separated", isDirectory: true)
        )

        XCTAssertEqual(command.executablePath, "/opt/homebrew/bin/demucs")
        XCTAssertEqual(command.arguments, [
            "--name", "htdemucs",
            "--out", "/tmp/separated",
            "-d", "mps",
            "--overlap", "0.1",
            "/tmp/source.m4a"
        ])
    }

    func testDemucsCommandCanUseTunedCPUFallbackProfile() {
        let command = BoostedDrumsRenderPlan.demucsCommand(
            demucsPath: "/opt/homebrew/bin/demucs",
            sourceURL: URL(fileURLWithPath: "/tmp/source.m4a"),
            separationRootURL: URL(fileURLWithPath: "/tmp/separated", isDirectory: true),
            profile: .tunedCPU
        )

        XCTAssertEqual(command.arguments, [
            "--name", "htdemucs",
            "--out", "/tmp/separated",
            "--overlap", "0.1",
            "/tmp/source.m4a"
        ])
        XCTAssertFalse(command.arguments.contains("-d"))
        XCTAssertFalse(command.arguments.contains("mps"))
    }

    func testRenderOutputURLUsesBoostedDrumsFolderAndSanitizedName() {
        let root = URL(fileURLWithPath: "/tmp/backbeat/renders", isDirectory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let createdAt = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let track = BackbeatTrack(
            id: trackID,
            title: "Sample Song",
            artist: "Prince & The N.P.G.",
            duration: 271,
            status: .imported,
            sourceURL: URL(fileURLWithPath: "/tmp/sample-song.m4a")
        )

        let outputURL = BoostedDrumsRenderPlan.outputURL(
            for: track,
            rendersRootURL: root,
            createdAt: createdAt
        )

        XCTAssertEqual(outputURL.deletingLastPathComponent(), root.appendingPathComponent("boosted_drums", isDirectory: true))
        XCTAssertEqual(outputURL.lastPathComponent, "Sample_Song_Prince_The_N_P_G_boosted_drums_\(trackID.uuidString)_20260901_000000.m4a")
    }

    func testDrumlessOutputURLUsesDrumlessFolderAndSanitizedName() {
        let root = URL(fileURLWithPath: "/tmp/backbeat/renders", isDirectory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let createdAt = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let track = BackbeatTrack(
            id: trackID,
            title: "Sample Song",
            artist: "Prince & The N.P.G.",
            duration: 271,
            status: .imported,
            sourceURL: URL(fileURLWithPath: "/tmp/sample-song.m4a")
        )

        let outputURL = BoostedDrumsRenderPlan.drumlessOutputURL(
            for: track,
            rendersRootURL: root,
            createdAt: createdAt
        )

        XCTAssertEqual(outputURL.deletingLastPathComponent(), root.appendingPathComponent("drumless", isDirectory: true))
        XCTAssertEqual(outputURL.lastPathComponent, "Sample_Song_Prince_The_N_P_G_drumless_\(trackID.uuidString)_20260901_000000.m4a")
    }

    func testDrumsOutputURLUsesDrumsFolderAndSanitizedName() {
        let trackID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let track = BackbeatTrack(
            id: trackID,
            title: "Song / One",
            artist: "Artist Name",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/song.m4a")
        )
        let url = BoostedDrumsRenderPlan.drumsOutputURL(
            for: track,
            rendersRootURL: URL(fileURLWithPath: "/tmp/renders", isDirectory: true),
            createdAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(url.path, "/tmp/renders/drums/Song_One_Artist_Name_drums_\(trackID.uuidString)_19700101_000000.m4a")
    }

    func testPracticeRenderResultCarriesDrumsAndDrumlessOnly() {
        let result = PracticeRenderResult(
            drumsURL: URL(fileURLWithPath: "/tmp/drums.m4a"),
            drumlessURL: URL(fileURLWithPath: "/tmp/drumless.m4a")
        )

        XCTAssertEqual(result.drumsURL.lastPathComponent, "drums.m4a")
        XCTAssertEqual(result.drumlessURL.lastPathComponent, "drumless.m4a")
    }

    func testWorkflowSmokeValidatesDrumsAndDrumlessOutputs() throws {
        let source = try readSource("Sources/BackbeatWorkflowSmoke/main.swift")

        XCTAssertTrue(source.contains("renderResult.drumsURL"))
        XCTAssertTrue(source.contains("renderResult.drumlessURL"))
        XCTAssertFalse(source.contains("renderResult.boostedDrumsURL"))
    }

    func testMixCommandBoostsDrumsWithoutAmixNormalization() {
        let stems = FourStemURLs(
            drums: URL(fileURLWithPath: "/tmp/drums.wav"),
            bass: URL(fileURLWithPath: "/tmp/bass.wav"),
            other: URL(fileURLWithPath: "/tmp/other.wav"),
            vocals: URL(fileURLWithPath: "/tmp/vocals.wav")
        )
        let command = BoostedDrumsRenderPlan.mixCommand(
            ffmpegPath: "/opt/homebrew/bin/ffmpeg",
            stems: stems,
            outputURL: URL(fileURLWithPath: "/tmp/output.m4a"),
            boostDB: 4.5
        )
        let gains = DrumBoostMixGains(boostDB: 4.5)
        let drumGain = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), gains.drumGainDB)

        XCTAssertEqual(command.executablePath, "/opt/homebrew/bin/ffmpeg")
        XCTAssertTrue(command.arguments.contains("-filter_complex"))
        XCTAssertEqual(gains.drumGainDB - gains.backingGainDB, 4.5, accuracy: 0.01)
        XCTAssertTrue(command.arguments.contains { $0.contains("volume=\(drumGain)dB") })
        XCTAssertTrue(command.arguments.contains { $0.contains("amix=inputs=4:duration=longest:normalize=0") })
        XCTAssertFalse(command.arguments.contains { $0.contains("normalize=1") })
    }

    func testMixCommandAppliesCompensatingBackingTrimAtHigherBoosts() {
        let stems = FourStemURLs(
            drums: URL(fileURLWithPath: "/tmp/drums.wav"),
            bass: URL(fileURLWithPath: "/tmp/bass.wav"),
            other: URL(fileURLWithPath: "/tmp/other.wav"),
            vocals: URL(fileURLWithPath: "/tmp/vocals.wav")
        )

        let command = BoostedDrumsRenderPlan.mixCommand(
            ffmpegPath: "/opt/homebrew/bin/ffmpeg",
            stems: stems,
            outputURL: URL(fileURLWithPath: "/tmp/output.m4a"),
            boostDB: 9
        )
        let gains = DrumBoostMixGains(boostDB: 9)
        let drumGain = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), gains.drumGainDB)
        let backingGain = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), gains.backingGainDB)

        XCTAssertEqual(gains.drumGainDB - gains.backingGainDB, 9, accuracy: 0.01)
        XCTAssertGreaterThan(gains.drumGainDB, 0)
        XCTAssertLessThan(gains.backingGainDB, 0)
        XCTAssertTrue(command.arguments.contains { $0.contains("[0:a]volume=\(drumGain)dB[drums]") })
        XCTAssertTrue(command.arguments.contains { $0.contains("[1:a]volume=\(backingGain)dB[bass]") })
        XCTAssertTrue(command.arguments.contains { $0.contains("[2:a]volume=\(backingGain)dB[other]") })
        XCTAssertTrue(command.arguments.contains { $0.contains("[3:a]volume=\(backingGain)dB[vocals]") })
    }

    func testDrumlessMixCommandOmitsDrumStem() {
        let stems = FourStemURLs(
            drums: URL(fileURLWithPath: "/tmp/drums.wav"),
            bass: URL(fileURLWithPath: "/tmp/bass.wav"),
            other: URL(fileURLWithPath: "/tmp/other.wav"),
            vocals: URL(fileURLWithPath: "/tmp/vocals.wav")
        )

        let command = BoostedDrumsRenderPlan.drumlessMixCommand(
            ffmpegPath: "/opt/homebrew/bin/ffmpeg",
            stems: stems,
            outputURL: URL(fileURLWithPath: "/tmp/output.m4a")
        )

        XCTAssertEqual(command.executablePath, "/opt/homebrew/bin/ffmpeg")
        XCTAssertFalse(command.arguments.contains(stems.drums.path))
        XCTAssertTrue(command.arguments.contains(stems.bass.path))
        XCTAssertTrue(command.arguments.contains(stems.other.path))
        XCTAssertTrue(command.arguments.contains(stems.vocals.path))
        XCTAssertTrue(command.arguments.contains { $0.contains("[0:a][1:a][2:a]amix=inputs=3:duration=longest:normalize=0") })
        XCTAssertTrue(command.arguments.contains("-c:a"))
        XCTAssertTrue(command.arguments.contains("aac"))
        XCTAssertTrue(command.arguments.contains("-b:a"))
        XCTAssertTrue(command.arguments.contains("256k"))
    }

    func testDrumsStemCommandUsesOnlyDrumsStem() {
        let stems = FourStemURLs(
            drums: URL(fileURLWithPath: "/tmp/drums.wav"),
            bass: URL(fileURLWithPath: "/tmp/bass.wav"),
            other: URL(fileURLWithPath: "/tmp/other.wav"),
            vocals: URL(fileURLWithPath: "/tmp/vocals.wav")
        )

        let command = BoostedDrumsRenderPlan.drumsStemCommand(
            ffmpegPath: "/opt/homebrew/bin/ffmpeg",
            stems: stems,
            outputURL: URL(fileURLWithPath: "/tmp/output.m4a")
        )

        XCTAssertEqual(command.executablePath, "/opt/homebrew/bin/ffmpeg")
        XCTAssertTrue(command.arguments.contains(stems.drums.path))
        XCTAssertFalse(command.arguments.contains(stems.bass.path))
        XCTAssertFalse(command.arguments.contains(stems.other.path))
        XCTAssertFalse(command.arguments.contains(stems.vocals.path))
        XCTAssertTrue(command.arguments.contains("-c:a"))
        XCTAssertTrue(command.arguments.contains("aac"))
        XCTAssertTrue(command.arguments.contains("-b:a"))
        XCTAssertTrue(command.arguments.contains("256k"))
    }

    func testCommandsUseConfiguredBitrate() {
        let stems = FourStemURLs(
            drums: URL(fileURLWithPath: "/tmp/drums.wav"),
            bass: URL(fileURLWithPath: "/tmp/bass.wav"),
            other: URL(fileURLWithPath: "/tmp/other.wav"),
            vocals: URL(fileURLWithPath: "/tmp/vocals.wav")
        )
        let outputURL = URL(fileURLWithPath: "/tmp/output.m4a")

        let mix = BoostedDrumsRenderPlan.mixCommand(
            ffmpegPath: "/opt/homebrew/bin/ffmpeg",
            stems: stems,
            outputURL: outputURL,
            boostDB: 4,
            bitrate: .kbps320
        )
        let drumless = BoostedDrumsRenderPlan.drumlessMixCommand(
            ffmpegPath: "/opt/homebrew/bin/ffmpeg",
            stems: stems,
            outputURL: outputURL,
            bitrate: .kbps128
        )
        let drums = BoostedDrumsRenderPlan.drumsStemCommand(
            ffmpegPath: "/opt/homebrew/bin/ffmpeg",
            stems: stems,
            outputURL: outputURL,
            bitrate: .kbps192
        )

        assertBitrateArgument(mix, equals: "320k")
        assertBitrateArgument(drumless, equals: "128k")
        assertBitrateArgument(drums, equals: "192k")
        XCTAssertFalse(mix.arguments.contains("256k"))
        XCTAssertFalse(drumless.arguments.contains("256k"))
        XCTAssertFalse(drums.arguments.contains("256k"))
    }

    func testRendererPassesBitrateToFfmpegCommands() async throws {
        let temporaryRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rendersRootURL = temporaryRootURL.appendingPathComponent("renders", isDirectory: true)
        let sourceURL = temporaryRootURL.appendingPathComponent("sample-song.m4a")
        try FileManager.default.createDirectory(at: temporaryRootURL, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryRootURL)
        }

        let commandRecorder = RenderCommandRecorder()
        let renderer = BoostedDrumsRenderer(
            rendersRootURL: rendersRootURL,
            temporaryRootURL: temporaryRootURL.appendingPathComponent("jobs", isDirectory: true),
            bitrate: .kbps192,
            commandResolver: { command in "/usr/local/bin/\(command)" },
            commandExecutor: ProgressRecordingRenderCommandExecutor(recorder: commandRecorder)
        )
        let track = BackbeatTrack(
            title: "Sample Song",
            duration: 271,
            status: .imported,
            sourceURL: sourceURL
        )

        _ = try await renderer.render(track: track)

        let ffmpegCommands = await commandRecorder.commands().filter { $0.executablePath.hasSuffix("ffmpeg") }
        XCTAssertEqual(ffmpegCommands.count, 2)
        for command in ffmpegCommands {
            assertBitrateArgument(command, equals: "192k")
        }
    }

    private func assertBitrateArgument(_ command: CommandSpec, equals expected: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let flagIndex = command.arguments.firstIndex(of: "-b:a") else {
            XCTFail("command has no -b:a flag: \(command.arguments)", file: file, line: line)
            return
        }
        XCTAssertEqual(command.arguments[command.arguments.index(after: flagIndex)], expected, file: file, line: line)
    }

    func testIdentifiesSupersededOutputsByTrackUUIDOnly() {
        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let siblingID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let track = BackbeatTrack(
            id: trackID,
            title: "Sample Song",
            duration: 271,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/sample-song.m4a")
        )

        // This track's UUID-named outputs match.
        XCTAssertTrue(BoostedDrumsRenderPlan.isOutput(URL(fileURLWithPath: "/tmp/Sample_Song_boosted_drums_\(trackID.uuidString)_20260701_230824.m4a"), for: track))
        XCTAssertTrue(BoostedDrumsRenderPlan.isDrumsOutput(URL(fileURLWithPath: "/tmp/Sample_Song_drums_\(trackID.uuidString)_20260701_230824.m4a"), for: track))
        // A same-title sibling's outputs never match: different UUID.
        XCTAssertFalse(BoostedDrumsRenderPlan.isOutput(URL(fileURLWithPath: "/tmp/Sample_Song_boosted_drums_\(siblingID.uuidString)_20260701_230824.m4a"), for: track))
        // Pre-UUID names are ambiguous between same-title tracks, so the prefix
        // scan must not claim them; they are superseded via recorded render URLs.
        XCTAssertFalse(BoostedDrumsRenderPlan.isOutput(URL(fileURLWithPath: "/tmp/Sample_Song_boosted_drums_20260701_230824.m4a"), for: track))
        // Variant and title mismatches never match.
        XCTAssertFalse(BoostedDrumsRenderPlan.isOutput(URL(fileURLWithPath: "/tmp/Sample_Song_drumless_\(trackID.uuidString)_20260701_230824.m4a"), for: track))
        XCTAssertFalse(BoostedDrumsRenderPlan.isOutput(URL(fileURLWithPath: "/tmp/Other_Song_boosted_drums_\(trackID.uuidString)_20260701_230824.m4a"), for: track))
    }

    func testRenderPreservesSameTitleSiblingRenderFiles() async throws {
        let temporaryRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rendersRootURL = temporaryRootURL.appendingPathComponent("renders", isDirectory: true)
        let sourceURL = temporaryRootURL.appendingPathComponent("sample-song.m4a")
        try FileManager.default.createDirectory(at: temporaryRootURL, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryRootURL)
        }

        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let siblingID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let track = BackbeatTrack(
            id: trackID,
            title: "Sample Song",
            duration: 271,
            status: .imported,
            sourceURL: sourceURL
        )

        // Pre-populate the render folders with the sibling's UUID-named files,
        // ambiguous old-style files, and a stale file of the rendered track's own.
        let drumsFolder = rendersRootURL.appendingPathComponent("drums", isDirectory: true)
        let drumlessFolder = rendersRootURL.appendingPathComponent("drumless", isDirectory: true)
        try FileManager.default.createDirectory(at: drumsFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: drumlessFolder, withIntermediateDirectories: true)
        let siblingDrums = drumsFolder.appendingPathComponent("Sample_Song_drums_\(siblingID.uuidString)_20260101_000000.m4a")
        let siblingDrumless = drumlessFolder.appendingPathComponent("Sample_Song_drumless_\(siblingID.uuidString)_20260101_000000.m4a")
        let legacyDrums = drumsFolder.appendingPathComponent("Sample_Song_drums_20260101_000000.m4a")
        let staleOwnDrums = drumsFolder.appendingPathComponent("Sample_Song_drums_\(trackID.uuidString)_20260101_000000.m4a")
        for url in [siblingDrums, siblingDrumless, legacyDrums, staleOwnDrums] {
            try Data("render".utf8).write(to: url)
        }

        let renderer = BoostedDrumsRenderer(
            rendersRootURL: rendersRootURL,
            temporaryRootURL: temporaryRootURL.appendingPathComponent("jobs", isDirectory: true),
            commandResolver: { command in "/usr/local/bin/\(command)" },
            commandExecutor: ProgressRecordingRenderCommandExecutor(recorder: nil)
        )
        _ = try await renderer.render(track: track)

        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingDrums.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingDrumless.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyDrums.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleOwnDrums.path))
    }

    func testMissingCommandErrorDescriptionIncludesRecoveryHint() {
        XCTAssertEqual(
            BoostedDrumsRenderError.missingCommand("ffmpeg").errorDescription,
            "Required audio tool is not available: ffmpeg. Install ffmpeg or set its location in Backbeat Settings, then retry."
        )
    }

    func testRendererReportsProgressStagesInOrder() async throws {
        let temporaryRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rendersRootURL = temporaryRootURL.appendingPathComponent("renders", isDirectory: true)
        let sourceURL = temporaryRootURL.appendingPathComponent("sample-song.m4a")
        try FileManager.default.createDirectory(at: temporaryRootURL, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryRootURL)
        }

        let commandRecorder = RenderCommandRecorder()
        let renderer = BoostedDrumsRenderer(
            rendersRootURL: rendersRootURL,
            temporaryRootURL: temporaryRootURL.appendingPathComponent("jobs", isDirectory: true),
            commandResolver: { command in "/usr/local/bin/\(command)" },
            commandExecutor: ProgressRecordingRenderCommandExecutor(recorder: commandRecorder)
        )
        let recorder = RenderProgressRecorder()
        let track = BackbeatTrack(
            title: "Sample Song",
            duration: 271,
            status: .imported,
            sourceURL: sourceURL
        )

        let result = try await renderer.render(track: track) { state in
            await recorder.record(state)
        }

        let states = await recorder.states()
        XCTAssertEqual(
            states,
            [.separatingStems, .mixingDrumsTrack, .mixingDrumlessTrack, .finalizingOutput, .complete]
        )
        XCTAssertEqual(result.drumsURL.deletingLastPathComponent(), rendersRootURL.appendingPathComponent("drums", isDirectory: true))
        XCTAssertEqual(result.drumlessURL.deletingLastPathComponent(), rendersRootURL.appendingPathComponent("drumless", isDirectory: true))

        let commands = await commandRecorder.commands()
        XCTAssertEqual(commands.filter { $0.executablePath.hasSuffix("demucs") }.count, 1)
        let ffmpegCommands = commands.filter { $0.executablePath.hasSuffix("ffmpeg") }
        XCTAssertEqual(ffmpegCommands.count, 2)

        let separationRootURL = try XCTUnwrap(separationRootURL(from: commands))
        let stems = BoostedDrumsRenderPlan.stemURLs(
            stemDirectory: BoostedDrumsRenderPlan.stemDirectory(
                separationRootURL: separationRootURL,
                sourceURL: sourceURL
            )
        )
        let drumsCommand = ffmpegCommands[0]
        XCTAssertTrue(drumsCommand.arguments.contains(stems.drums.path))
        XCTAssertFalse(drumsCommand.arguments.contains(stems.bass.path))
        XCTAssertFalse(drumsCommand.arguments.contains(stems.other.path))
        XCTAssertFalse(drumsCommand.arguments.contains(stems.vocals.path))
        XCTAssertEqual(URL(fileURLWithPath: drumsCommand.arguments.last ?? "").deletingLastPathComponent(), rendersRootURL.appendingPathComponent("drums", isDirectory: true))

        let drumlessCommand = ffmpegCommands[1]
        XCTAssertFalse(drumlessCommand.arguments.contains(stems.drums.path))
        XCTAssertTrue(drumlessCommand.arguments.contains(stems.bass.path))
        XCTAssertTrue(drumlessCommand.arguments.contains(stems.other.path))
        XCTAssertTrue(drumlessCommand.arguments.contains(stems.vocals.path))
        XCTAssertEqual(URL(fileURLWithPath: drumlessCommand.arguments.last ?? "").deletingLastPathComponent(), rendersRootURL.appendingPathComponent("drumless", isDirectory: true))
    }

    func testRendererRetriesDemucsWithTunedCPUProfileWhenMPSFails() async throws {
        let temporaryRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rendersRootURL = temporaryRootURL.appendingPathComponent("renders", isDirectory: true)
        let sourceURL = temporaryRootURL.appendingPathComponent("sample-song.m4a")
        try FileManager.default.createDirectory(at: temporaryRootURL, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryRootURL)
        }

        let executor = MPSFallbackRenderCommandExecutor()
        let renderer = BoostedDrumsRenderer(
            rendersRootURL: rendersRootURL,
            temporaryRootURL: temporaryRootURL.appendingPathComponent("jobs", isDirectory: true),
            commandResolver: { command in "/usr/local/bin/\(command)" },
            commandExecutor: executor
        )
        let track = BackbeatTrack(
            title: "Sample Song",
            duration: 271,
            status: .imported,
            sourceURL: sourceURL
        )

        let result = try await renderer.render(track: track)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.drumsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.drumlessURL.path))

        let demucsCommands = await executor.commands().filter { $0.executablePath.hasSuffix("demucs") }
        XCTAssertEqual(demucsCommands.count, 2)
        XCTAssertTrue(demucsCommands[0].arguments.contains("-d"))
        XCTAssertTrue(demucsCommands[0].arguments.contains("mps"))
        XCTAssertFalse(demucsCommands[1].arguments.contains("-d"))
        XCTAssertFalse(demucsCommands[1].arguments.contains("mps"))
        XCTAssertTrue(demucsCommands[1].arguments.contains("--overlap"))
        XCTAssertTrue(demucsCommands[1].arguments.contains("0.1"))
    }
}

private func readSource(_ relativePath: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = packageRoot.appendingPathComponent(relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private actor RenderProgressRecorder {
    private var recordedStates: [RenderProgressState] = []

    func record(_ state: RenderProgressState) {
        recordedStates.append(state)
    }

    func states() -> [RenderProgressState] {
        recordedStates
    }
}

private actor RenderCommandRecorder {
    private var recordedCommands: [CommandSpec] = []

    func record(_ command: CommandSpec) {
        recordedCommands.append(command)
    }

    func commands() -> [CommandSpec] {
        recordedCommands
    }
}

private struct ProgressRecordingRenderCommandExecutor: RenderCommandExecuting {
    var recorder: RenderCommandRecorder?

    func run(_ command: CommandSpec) async throws -> RenderCommandResult {
        await recorder?.record(command)

        if command.executablePath.hasSuffix("demucs") {
            try createStemFiles(for: command)
        } else if command.executablePath.hasSuffix("ffmpeg"), let outputPath = command.arguments.last {
            try Data("render".utf8).write(to: URL(fileURLWithPath: outputPath))
        }

        return RenderCommandResult(terminationStatus: 0, output: "")
    }

    private func createStemFiles(for command: CommandSpec) throws {
        guard
            let outIndex = command.arguments.firstIndex(of: "--out"),
            command.arguments.indices.contains(outIndex + 1),
            let sourcePath = command.arguments.last
        else {
            XCTFail("Unexpected demucs command arguments: \(command.arguments)")
            return
        }

        let separationRootURL = URL(fileURLWithPath: command.arguments[outIndex + 1], isDirectory: true)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let stemDirectory = BoostedDrumsRenderPlan.stemDirectory(
            separationRootURL: separationRootURL,
            sourceURL: sourceURL
        )
        try FileManager.default.createDirectory(at: stemDirectory, withIntermediateDirectories: true)

        for url in BoostedDrumsRenderPlan.stemURLs(stemDirectory: stemDirectory).all {
            try Data("stem".utf8).write(to: url)
        }
    }
}

private func separationRootURL(from commands: [CommandSpec]) -> URL? {
    guard
        let demucsCommand = commands.first(where: { $0.executablePath.hasSuffix("demucs") }),
        let outIndex = demucsCommand.arguments.firstIndex(of: "--out"),
        demucsCommand.arguments.indices.contains(outIndex + 1)
    else {
        return nil
    }
    return URL(fileURLWithPath: demucsCommand.arguments[outIndex + 1], isDirectory: true)
}

private actor MPSFallbackRenderCommandExecutor: RenderCommandExecuting {
    private var recordedCommands: [CommandSpec] = []

    func commands() -> [CommandSpec] {
        recordedCommands
    }

    func run(_ command: CommandSpec) async throws -> RenderCommandResult {
        recordedCommands.append(command)

        if command.executablePath.hasSuffix("demucs") {
            if command.arguments.contains("-d") && command.arguments.contains("mps") {
                try createPartialOutput(for: command)
                return RenderCommandResult(terminationStatus: 1, output: "MPS backend unavailable")
            }
            if try hasPartialOutput(for: command) {
                return RenderCommandResult(terminationStatus: 1, output: "Fallback separation root was not cleaned")
            }
            try createStemFiles(for: command)
        } else if command.executablePath.hasSuffix("ffmpeg"), let outputPath = command.arguments.last {
            try Data("render".utf8).write(to: URL(fileURLWithPath: outputPath))
        }

        return RenderCommandResult(terminationStatus: 0, output: "")
    }

    private func createPartialOutput(for command: CommandSpec) throws {
        let separationRootURL = try separationRootURL(for: command)
        try FileManager.default.createDirectory(at: separationRootURL, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: separationRootURL.appendingPathComponent("partial.tmp"))
    }

    private func hasPartialOutput(for command: CommandSpec) throws -> Bool {
        let separationRootURL = try separationRootURL(for: command)
        return FileManager.default.fileExists(atPath: separationRootURL.appendingPathComponent("partial.tmp").path)
    }

    private func createStemFiles(for command: CommandSpec) throws {
        let separationRootURL = try separationRootURL(for: command)
        guard
            let sourcePath = command.arguments.last
        else {
            XCTFail("Unexpected demucs command arguments: \(command.arguments)")
            return
        }

        let sourceURL = URL(fileURLWithPath: sourcePath)
        let stemDirectory = BoostedDrumsRenderPlan.stemDirectory(
            separationRootURL: separationRootURL,
            sourceURL: sourceURL
        )
        try FileManager.default.createDirectory(at: stemDirectory, withIntermediateDirectories: true)

        for url in BoostedDrumsRenderPlan.stemURLs(stemDirectory: stemDirectory).all {
            try Data("stem".utf8).write(to: url)
        }
    }

    private func separationRootURL(for command: CommandSpec) throws -> URL {
        guard
            let outIndex = command.arguments.firstIndex(of: "--out"),
            command.arguments.indices.contains(outIndex + 1)
        else {
            throw BoostedDrumsRenderError.commandFailed(
                command: command.executablePath,
                status: 1,
                output: "Unexpected demucs command arguments: \(command.arguments)"
            )
        }
        return URL(fileURLWithPath: command.arguments[outIndex + 1], isDirectory: true)
    }
}
