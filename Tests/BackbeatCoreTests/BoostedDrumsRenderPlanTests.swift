import XCTest
@testable import BackbeatCore

final class BoostedDrumsRenderPlanTests: XCTestCase {
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

        // The CLI has no app bundle to read the checkpoint from, so it binds the
        // separator to an explicitly resolved weights path — not the argument-less
        // CustomHTDemucsSeparator(), whose bundle default resolves to nothing here.
        XCTAssertTrue(source.contains("CustomHTDemucsSeparator(weightsURL: weightsURL)"))
        XCTAssertFalse(source.contains("CustomHTDemucsSeparator()"))
    }

    func testRendererPassesConfiguredBitrateToStemMixdown() async throws {
        let fixture = try makeRenderFixture()
        defer { fixture.cleanUp() }

        let mixRecorder = StemMixdownRecorder()
        let renderer = BoostedDrumsRenderer(
            separator: FakeStemSeparator(stems: Self.makeStems(), recorder: nil),
            rendersRootURL: fixture.rendersRootURL,
            bitrate: .kbps192,
            stemMixdown: RecordingStemMixdown(recorder: mixRecorder)
        )

        _ = try await renderer.render(track: fixture.track)

        let calls = await mixRecorder.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(Set(calls.map(\.kind)), ["drums", "drumless"])
        for call in calls {
            XCTAssertEqual(call.bitrate, .kbps192)
        }
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
            separator: FakeStemSeparator(stems: Self.makeStems(), recorder: nil),
            rendersRootURL: rendersRootURL,
            stemMixdown: RecordingStemMixdown(recorder: nil)
        )
        _ = try await renderer.render(track: track)

        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingDrums.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingDrumless.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyDrums.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleOwnDrums.path))
    }

    func testMissingCommandErrorDescriptionIncludesRecoveryHint() {
        // The native engine has no external tool to install and the model is bundled, so
        // an unready engine means a broken install — the copy points at a reinstall.
        XCTAssertEqual(
            BoostedDrumsRenderError.missingCommand("separation engine").errorDescription,
            "Cannot render: separation engine is not ready. Please reinstall Backline Boost and try again."
        )
    }

    func testRendererReportsProgressStagesInOrder() async throws {
        let fixture = try makeRenderFixture()
        defer { fixture.cleanUp() }

        let stems = Self.makeStems()
        let separatorRecorder = SeparatorRecorder()
        let mixRecorder = StemMixdownRecorder()
        let renderer = BoostedDrumsRenderer(
            separator: FakeStemSeparator(stems: stems, recorder: separatorRecorder),
            rendersRootURL: fixture.rendersRootURL,
            stemMixdown: RecordingStemMixdown(recorder: mixRecorder)
        )
        let recorder = RenderProgressRecorder()

        let result = try await renderer.render(track: fixture.track) { state in
            await recorder.record(state)
        }

        // The pinned 5-stage order is unchanged by the native-engine swap: the
        // subprocess separation became an in-process engine call, but drums are still
        // mixed before drumless and the stages fire in the same sequence.
        let states = await recorder.states()
        XCTAssertEqual(
            states,
            [.separatingStems, .mixingDrumsTrack, .mixingDrumlessTrack, .finalizingOutput, .complete]
        )
        XCTAssertEqual(result.drumsURL.deletingLastPathComponent(), fixture.rendersRootURL.appendingPathComponent("drums", isDirectory: true))
        XCTAssertEqual(result.drumlessURL.deletingLastPathComponent(), fixture.rendersRootURL.appendingPathComponent("drumless", isDirectory: true))

        // The engine was asked to separate exactly the track's source — once, with no
        // subprocess and no retry (amendment A1).
        let separated = await separatorRecorder.sources()
        XCTAssertEqual(separated, [fixture.track.sourceURL])

        // The native mixer received the engine's in-memory stems for both outputs, in
        // the pinned drums-before-drumless order, into the right variant folders — no
        // WAV round-trip (amendment A3).
        let calls = await mixRecorder.calls()
        XCTAssertEqual(calls.map(\.kind), ["drums", "drumless"])
        XCTAssertEqual(calls[0].stems, stems)
        XCTAssertEqual(calls[0].outputURL.deletingLastPathComponent(), fixture.rendersRootURL.appendingPathComponent("drums", isDirectory: true))
        XCTAssertEqual(calls[1].stems, stems)
        XCTAssertEqual(calls[1].outputURL.deletingLastPathComponent(), fixture.rendersRootURL.appendingPathComponent("drumless", isDirectory: true))
    }

    func testRenderPropagatesSeparatorCancellation() async throws {
        let fixture = try makeRenderFixture()
        defer { fixture.cleanUp() }

        let renderer = BoostedDrumsRenderer(
            separator: FakeStemSeparator(stems: Self.makeStems(), shouldThrowCancellation: true, recorder: nil),
            rendersRootURL: fixture.rendersRootURL,
            stemMixdown: RecordingStemMixdown(recorder: nil)
        )

        // A4: the engine cancels cooperatively between segments and throws
        // CancellationError; the renderer must let it propagate uncaught so the queue
        // maps it to `.cancelled` (revert to `.imported`), not `.renderFailed`.
        await XCTAssertThrowsErrorAsync(try await renderer.render(track: fixture.track)) { error in
            XCTAssertTrue(error is CancellationError, "expected CancellationError to propagate, got \(error)")
        }
    }

    func testRenderThrowsEmptyStemWhenEngineReturnsSilentStem() async throws {
        let fixture = try makeRenderFixture()
        defer { fixture.cleanUp() }

        let renderer = BoostedDrumsRenderer(
            separator: FakeStemSeparator(stems: Self.makeStems(drumsEmpty: true), recorder: nil),
            rendersRootURL: fixture.rendersRootURL,
            stemMixdown: RecordingStemMixdown(recorder: nil)
        )

        // A3: an engine that returns a stem with no audio must fail as emptyStem
        // rather than silently mixing a header-only "successful" output.
        await XCTAssertThrowsErrorAsync(try await renderer.render(track: fixture.track)) { error in
            guard case BoostedDrumsRenderError.emptyStem(.drums) = error else {
                return XCTFail("expected emptyStem(.drums), got \(error)")
            }
        }
    }

    // MARK: - Fixtures

    private struct RenderFixture {
        let root: URL
        let rendersRootURL: URL
        let track: BackbeatTrack

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeRenderFixture() throws -> RenderFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rendersRootURL = root.appendingPathComponent("renders", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let track = BackbeatTrack(
            title: "Sample Song",
            duration: 271,
            status: .imported,
            sourceURL: root.appendingPathComponent("sample-song.m4a")
        )
        return RenderFixture(root: root, rendersRootURL: rendersRootURL, track: track)
    }

    /// Small in-memory stereo stems, mirroring what a `StemSeparating` engine returns.
    static func makeStems(sampleRate: Double = 44_100, frames: Int = 128, drumsEmpty: Bool = false) -> SeparatedStems {
        let channel = [Float](repeating: 0.1, count: frames)
        let stereo = [channel, channel]
        return SeparatedStems(
            sampleRate: sampleRate,
            drums: drumsEmpty ? [] : stereo,
            bass: stereo,
            other: stereo,
            vocals: stereo
        )
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

private actor SeparatorRecorder {
    private var recordedSources: [URL] = []

    func record(_ source: URL) {
        recordedSources.append(source)
    }

    func sources() -> [URL] {
        recordedSources
    }
}

private actor StemMixdownRecorder {
    struct Call: Equatable {
        let kind: String
        let stems: SeparatedStems
        let outputURL: URL
        let bitrate: RenderBitrate
    }

    private var recordedCalls: [Call] = []

    func record(_ call: Call) {
        recordedCalls.append(call)
    }

    func calls() -> [Call] {
        recordedCalls
    }
}

/// Stands in for the native `CustomHTDemucsSeparator`: returns canned in-memory stems (or
/// throws), and records the source it was asked to separate.
private struct FakeStemSeparator: StemSeparating {
    let stems: SeparatedStems
    var shouldThrowCancellation = false
    let recorder: SeparatorRecorder?

    func separate(source: URL, progress: StemSeparationProgress?) async throws -> SeparatedStems {
        await recorder?.record(source)
        if shouldThrowCancellation {
            throw CancellationError()
        }
        return stems
    }
}

/// Stands in for the native `StemMixdown` buffer entry: records the stems the
/// renderer hands it and drops a non-empty placeholder so the renderer's non-empty
/// output validation and superseded-file cleanup still exercise.
private struct RecordingStemMixdown: StemMixing {
    let recorder: StemMixdownRecorder?

    func writeDrums(stems: SeparatedStems, outputURL: URL, bitrate: RenderBitrate) async throws {
        await recorder?.record(.init(kind: "drums", stems: stems, outputURL: outputURL, bitrate: bitrate))
        try Data("render".utf8).write(to: outputURL)
    }

    func writeDrumless(stems: SeparatedStems, outputURL: URL, bitrate: RenderBitrate) async throws {
        await recorder?.record(.init(kind: "drumless", stems: stems, outputURL: outputURL, bitrate: bitrate))
        try Data("render".utf8).write(to: outputURL)
    }
}

/// Async variant of XCTAssertThrowsError (the stock macro is synchronous only).
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error to be thrown", file: file, line: line)
    } catch {
        handler(error)
    }
}
