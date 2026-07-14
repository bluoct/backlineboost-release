import XCTest
@testable import BackbeatCore

@MainActor
final class LibraryReconciliationTests: XCTestCase {
    func testReadyTrackWithMissingRenderFilesBecomesImportedAndIsReenqueued() throws {
        let dir = try makeTempDirectory()
        let sourceURL = dir.appendingPathComponent("source.m4a")
        try writeFile(at: sourceURL)
        let drumsURL = dir.appendingPathComponent("drums.m4a") // never created — simulates deleted
        let drumlessURL = dir.appendingPathComponent("drumless.m4a") // never created
        let track = BackbeatTrack(
            title: "Track",
            duration: 120,
            status: .ready,
            sourceURL: sourceURL,
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0),
                .drumless: RenderRecord(variant: .drumless, fileURL: drumlessURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track])

        store.reconcileLibraryFiles()

        let reconciled = try XCTUnwrap(store.track(id: track.id))
        XCTAssertEqual(reconciled.status, .imported)
        XCTAssertNil(reconciled.activeRender(for: .drums))
        XCTAssertNil(reconciled.activeRender(for: .drumless))

        let coordinator = makeHangingCoordinator(store: store)
        coordinator.enqueueMissingRenders()
        XCTAssertEqual(coordinator.activeTrackID, track.id, "the launch scan must re-render a ready-with-missing-file track this session")
    }

    func testTrackWithMissingSourceBecomesSourceMissingAndRetainsRenderRecords() throws {
        let dir = try makeTempDirectory()
        let sourceURL = dir.appendingPathComponent("source.m4a") // never created
        let drumsURL = dir.appendingPathComponent("drums.m4a")
        let drumlessURL = dir.appendingPathComponent("drumless.m4a")
        try writeFile(at: drumsURL)
        try writeFile(at: drumlessURL)
        let track = BackbeatTrack(
            title: "Track",
            duration: 120,
            status: .ready,
            sourceURL: sourceURL,
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0),
                .drumless: RenderRecord(variant: .drumless, fileURL: drumlessURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track])

        store.reconcileLibraryFiles()

        let reconciled = try XCTUnwrap(store.track(id: track.id))
        XCTAssertEqual(reconciled.status, .sourceMissing)
        XCTAssertNotNil(reconciled.activeRender(for: .drums), "existing Drums/Drumless files can still play with the source gone")
        XCTAssertNotNil(reconciled.activeRender(for: .drumless))
    }

    func testSourceMissingTrackWithSourceRestoredAndBothRendersPresentBecomesReady() throws {
        let dir = try makeTempDirectory()
        let sourceURL = dir.appendingPathComponent("source.m4a")
        try writeFile(at: sourceURL)
        let drumsURL = dir.appendingPathComponent("drums.m4a")
        let drumlessURL = dir.appendingPathComponent("drumless.m4a")
        try writeFile(at: drumsURL)
        try writeFile(at: drumlessURL)
        let track = BackbeatTrack(
            title: "Track",
            duration: 120,
            status: .sourceMissing,
            sourceURL: sourceURL,
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0),
                .drumless: RenderRecord(variant: .drumless, fileURL: drumlessURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track])

        store.reconcileLibraryFiles()

        XCTAssertEqual(store.track(id: track.id)?.status, .ready)
    }

    func testSourceMissingTrackWithSourceRestoredButAMissingRenderFileBecomesImported() throws {
        let dir = try makeTempDirectory()
        let sourceURL = dir.appendingPathComponent("source.m4a")
        try writeFile(at: sourceURL)
        let drumsURL = dir.appendingPathComponent("drums.m4a") // never created
        let drumlessURL = dir.appendingPathComponent("drumless.m4a")
        try writeFile(at: drumlessURL)
        let track = BackbeatTrack(
            title: "Track",
            duration: 120,
            status: .sourceMissing,
            sourceURL: sourceURL,
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0),
                .drumless: RenderRecord(variant: .drumless, fileURL: drumlessURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track])

        store.reconcileLibraryFiles()

        let reconciled = try XCTUnwrap(store.track(id: track.id))
        XCTAssertEqual(reconciled.status, .imported)
        XCTAssertNil(reconciled.activeRender(for: .drums), "the dangling record must be dropped")
        XCTAssertNotNil(reconciled.activeRender(for: .drumless))
    }

    func testReconcileLibraryFilesIsIdempotent() throws {
        let dir = try makeTempDirectory()
        let sourceURL = dir.appendingPathComponent("source.m4a")
        try writeFile(at: sourceURL)
        let drumsURL = dir.appendingPathComponent("drums.m4a") // never created
        let track = BackbeatTrack(
            title: "Track",
            duration: 120,
            status: .ready,
            sourceURL: sourceURL,
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track])

        store.reconcileLibraryFiles()
        let firstPass = store.tracks
        store.reconcileLibraryFiles()
        let secondPass = store.tracks

        XCTAssertEqual(firstPass, secondPass)
    }

    func testReconcileLibraryFilesDoesNotFireTheRecoverySeam() throws {
        let dir = try makeTempDirectory()
        let sourceURL = dir.appendingPathComponent("source.m4a")
        try writeFile(at: sourceURL)
        let drumsURL = dir.appendingPathComponent("drums.m4a") // never created
        let drumlessURL = dir.appendingPathComponent("drumless.m4a")
        try writeFile(at: drumlessURL)
        let track = BackbeatTrack(
            title: "Track",
            duration: 120,
            status: .ready,
            sourceURL: sourceURL,
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0),
                .drumless: RenderRecord(variant: .drumless, fileURL: drumlessURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track])
        var firedIDs: [BackbeatTrack.ID] = []
        store.onRenderRecoveryNeeded = { firedIDs.append($0) }

        store.reconcileLibraryFiles()

        XCTAssertEqual(store.track(id: track.id)?.status, .imported)
        XCTAssertTrue(firedIDs.isEmpty, "enqueueMissingRenders runs immediately after and re-derives the queue itself")
    }

    func testImportedTrackWithDanglingRenderRecordsDropsThemAndIsReenqueued() throws {
        let dir = try makeTempDirectory()
        let sourceURL = dir.appendingPathComponent("source.m4a")
        try writeFile(at: sourceURL)
        let drumsURL = dir.appendingPathComponent("drums.m4a") // never created
        let drumlessURL = dir.appendingPathComponent("drumless.m4a") // never created
        let track = BackbeatTrack(
            title: "Track",
            duration: 120,
            status: .imported,
            sourceURL: sourceURL,
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0),
                .drumless: RenderRecord(variant: .drumless, fileURL: drumlessURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track])

        store.reconcileLibraryFiles()

        let reconciled = try XCTUnwrap(store.track(id: track.id))
        XCTAssertEqual(reconciled.status, .imported)
        XCTAssertNil(reconciled.activeRender(for: .drums))
        XCTAssertNil(reconciled.activeRender(for: .drumless))

        let coordinator = makeHangingCoordinator(store: store)
        coordinator.enqueueMissingRenders()
        XCTAssertEqual(coordinator.activeTrackID, track.id, "a dropped record must read as nil to the launch scan")
    }

    func testRecoverMissingRenderFilesFiresTheSeamAndTheQueueEnqueuesInSession() throws {
        let dir = try makeTempDirectory()
        let sourceURL = dir.appendingPathComponent("source.m4a")
        try writeFile(at: sourceURL)
        let drumsURL = dir.appendingPathComponent("drums.m4a") // never created
        let drumlessURL = dir.appendingPathComponent("drumless.m4a")
        try writeFile(at: drumlessURL)
        let track = BackbeatTrack(
            title: "Track",
            duration: 120,
            status: .ready,
            sourceURL: sourceURL,
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0),
                .drumless: RenderRecord(variant: .drumless, fileURL: drumlessURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track])
        let coordinator = makeHangingCoordinator(store: store)
        var firedIDs: [BackbeatTrack.ID] = []
        store.onRenderRecoveryNeeded = { trackID in
            firedIDs.append(trackID)
            coordinator.enqueue(trackID)
        }

        let changed = store.recoverMissingRenderFiles(for: track.id)

        XCTAssertTrue(changed)
        XCTAssertEqual(firedIDs, [track.id], "in-session recovery must start the replacement render immediately (COR-004)")
        // The seam fires synchronously and the queue is idle, so by the time
        // recoverMissingRenderFiles returns the coordinator has already begun
        // rendering — status has moved past .imported to .rendering.
        XCTAssertEqual(store.track(id: track.id)?.status, .rendering)
        XCTAssertEqual(coordinator.activeTrackID, track.id)
    }

    func testRecoverMissingRenderFilesWithNothingMissingReturnsFalseAndDoesNotFireTheSeam() throws {
        let dir = try makeTempDirectory()
        let sourceURL = dir.appendingPathComponent("source.m4a")
        try writeFile(at: sourceURL)
        let drumsURL = dir.appendingPathComponent("drums.m4a")
        let drumlessURL = dir.appendingPathComponent("drumless.m4a")
        try writeFile(at: drumsURL)
        try writeFile(at: drumlessURL)
        let track = BackbeatTrack(
            title: "Track",
            duration: 120,
            status: .ready,
            sourceURL: sourceURL,
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0),
                .drumless: RenderRecord(variant: .drumless, fileURL: drumlessURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track])
        var firedIDs: [BackbeatTrack.ID] = []
        store.onRenderRecoveryNeeded = { firedIDs.append($0) }

        let changed = store.recoverMissingRenderFiles(for: track.id)

        XCTAssertFalse(changed)
        XCTAssertTrue(firedIDs.isEmpty)
    }

    func testNoteOriginalSourceMissingMarksTheTrackWhenTheFileIsGone() throws {
        let dir = try makeTempDirectory()
        let sourceURL = dir.appendingPathComponent("source.m4a") // never created
        let track = BackbeatTrack(title: "Track", duration: 120, status: .imported, sourceURL: sourceURL)
        let store = LibraryStore(tracks: [track])

        let result = store.noteOriginalSourceMissing(for: track.id)

        XCTAssertTrue(result)
        XCTAssertEqual(store.track(id: track.id)?.status, .sourceMissing)
    }

    func testNoteOriginalSourceMissingLeavesStatusUnchangedWhenTheFileExists() throws {
        let dir = try makeTempDirectory()
        let sourceURL = dir.appendingPathComponent("source.m4a")
        try writeFile(at: sourceURL)
        let track = BackbeatTrack(title: "Track", duration: 120, status: .imported, sourceURL: sourceURL)
        let store = LibraryStore(tracks: [track])

        let result = store.noteOriginalSourceMissing(for: track.id)

        XCTAssertFalse(result)
        XCTAssertEqual(store.track(id: track.id)?.status, .imported)
    }

    func testReconcileRetainsRecordsOnAnUnreachableRenderVolume() throws {
        let dir = try makeTempDirectory()
        let sourceURL = dir.appendingPathComponent("source.m4a")
        try writeFile(at: sourceURL)
        // The records' parent directory does not exist — an unplugged
        // external renders drive, not deleted files.
        let unmounted = dir.appendingPathComponent("unmounted", isDirectory: true)
        let drumsURL = unmounted.appendingPathComponent("drums.m4a")
        let drumlessURL = unmounted.appendingPathComponent("drumless.m4a")
        let track = BackbeatTrack(
            title: "Track",
            duration: 120,
            status: .ready,
            sourceURL: sourceURL,
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0),
                .drumless: RenderRecord(variant: .drumless, fileURL: drumlessURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track])

        store.reconcileLibraryFiles()

        let reconciled = try XCTUnwrap(store.track(id: track.id))
        XCTAssertEqual(reconciled.status, .ready, "a transient unmount must not demote the track and trigger a re-separation")
        XCTAssertNotNil(reconciled.activeRender(for: .drums), "records on an unreachable volume must survive to play again after a remount")
        XCTAssertNotNil(reconciled.activeRender(for: .drumless))
    }

    func testReconcileDropsRecordsWhenSourceAndRenderFilesAreAllGone() throws {
        let dir = try makeTempDirectory()
        let sourceURL = dir.appendingPathComponent("source.m4a") // never created
        let drumsURL = dir.appendingPathComponent("drums.m4a") // never created, parent exists
        let drumlessURL = dir.appendingPathComponent("drumless.m4a") // never created
        let track = BackbeatTrack(
            title: "Track",
            duration: 120,
            status: .ready,
            sourceURL: sourceURL,
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0),
                .drumless: RenderRecord(variant: .drumless, fileURL: drumlessURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track])

        store.reconcileLibraryFiles()

        let reconciled = try XCTUnwrap(store.track(id: track.id))
        XCTAssertEqual(reconciled.status, .sourceMissing)
        XCTAssertNil(reconciled.activeRender(for: .drums), "a record pointing at a genuinely deleted file misleads resolution regardless of status")
        XCTAssertNil(reconciled.activeRender(for: .drumless))
    }

    func testRecoverMissingRenderFilesMarksSourceMissingWithoutFiringTheSeamWhenTheSourceIsGone() throws {
        let dir = try makeTempDirectory()
        let sourceURL = dir.appendingPathComponent("source.m4a") // never created
        let drumsURL = dir.appendingPathComponent("drums.m4a") // never created, parent exists
        let drumlessURL = dir.appendingPathComponent("drumless.m4a")
        try writeFile(at: drumlessURL)
        let track = BackbeatTrack(
            title: "Track",
            duration: 120,
            status: .ready,
            sourceURL: sourceURL,
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0),
                .drumless: RenderRecord(variant: .drumless, fileURL: drumlessURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track])
        var firedIDs: [BackbeatTrack.ID] = []
        store.onRenderRecoveryNeeded = { firedIDs.append($0) }

        let changed = store.recoverMissingRenderFiles(for: track.id)

        XCTAssertTrue(changed)
        XCTAssertEqual(store.track(id: track.id)?.status, .sourceMissing, "a render without its input is doomed; the honest status must win (D-107)")
        XCTAssertTrue(firedIDs.isEmpty, "the seam must not enqueue a render that cannot succeed")
    }

    func testRecoverMissingRenderFilesLeavesRecordsOnAnUnreachableRenderVolume() throws {
        let dir = try makeTempDirectory()
        let sourceURL = dir.appendingPathComponent("source.m4a")
        try writeFile(at: sourceURL)
        let unmounted = dir.appendingPathComponent("unmounted", isDirectory: true)
        let drumsURL = unmounted.appendingPathComponent("drums.m4a")
        let drumlessURL = unmounted.appendingPathComponent("drumless.m4a")
        let track = BackbeatTrack(
            title: "Track",
            duration: 120,
            status: .ready,
            sourceURL: sourceURL,
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0),
                .drumless: RenderRecord(variant: .drumless, fileURL: drumlessURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track])
        var firedIDs: [BackbeatTrack.ID] = []
        store.onRenderRecoveryNeeded = { firedIDs.append($0) }

        let changed = store.recoverMissingRenderFiles(for: track.id)

        XCTAssertFalse(changed)
        XCTAssertEqual(store.track(id: track.id)?.status, .ready)
        XCTAssertNotNil(store.track(id: track.id)?.activeRender(for: .drums))
        XCTAssertTrue(firedIDs.isEmpty)
    }

    func testNoteOriginalSourceRestoredRederivesReadyWhenThePairIsPresent() throws {
        let dir = try makeTempDirectory()
        let sourceURL = dir.appendingPathComponent("source.m4a")
        try writeFile(at: sourceURL)
        let drumsURL = dir.appendingPathComponent("drums.m4a")
        let drumlessURL = dir.appendingPathComponent("drumless.m4a")
        try writeFile(at: drumsURL)
        try writeFile(at: drumlessURL)
        let track = BackbeatTrack(
            title: "Track",
            duration: 120,
            status: .sourceMissing,
            sourceURL: sourceURL,
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0),
                .drumless: RenderRecord(variant: .drumless, fileURL: drumlessURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track])
        var firedIDs: [BackbeatTrack.ID] = []
        store.onRenderRecoveryNeeded = { firedIDs.append($0) }

        store.noteOriginalSourceRestored(for: track.id)

        XCTAssertEqual(store.track(id: track.id)?.status, .ready)
        XCTAssertTrue(firedIDs.isEmpty)
    }

    func testNoteOriginalSourceRestoredRederivesImportedAndFiresTheSeamWithoutRenders() throws {
        let dir = try makeTempDirectory()
        let sourceURL = dir.appendingPathComponent("source.m4a")
        try writeFile(at: sourceURL)
        let track = BackbeatTrack(title: "Track", duration: 120, status: .sourceMissing, sourceURL: sourceURL)
        let store = LibraryStore(tracks: [track])
        var firedIDs: [BackbeatTrack.ID] = []
        store.onRenderRecoveryNeeded = { firedIDs.append($0) }

        store.noteOriginalSourceRestored(for: track.id)

        XCTAssertEqual(store.track(id: track.id)?.status, .imported)
        XCTAssertEqual(firedIDs, [track.id], "a restored renderless track re-enters the render pipeline immediately")
    }

    func testNoteOriginalSourceRestoredIgnoresTracksWhoseSourceIsStillGone() throws {
        let dir = try makeTempDirectory()
        let sourceURL = dir.appendingPathComponent("source.m4a") // never created
        let track = BackbeatTrack(title: "Track", duration: 120, status: .sourceMissing, sourceURL: sourceURL)
        let store = LibraryStore(tracks: [track])

        store.noteOriginalSourceRestored(for: track.id)

        XCTAssertEqual(store.track(id: track.id)?.status, .sourceMissing)
    }

    // MARK: - Fixtures

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func writeFile(at url: URL) throws {
        try Data("x".utf8).write(to: url)
    }

    // Hermetic: the render never completes, so these tests only need to
    // observe enqueue/status transitions, never a finished job.
    private func makeHangingCoordinator(store: LibraryStore) -> RenderQueueCoordinator {
        RenderQueueCoordinator(store: store) { _, _ in
            try await withCheckedThrowingContinuation { _ in }
        }
    }
}
