import XCTest
@testable import BackbeatCore

final class PlaybackSourceTests: XCTestCase {
    func testPlaybackSourcesRepresentOriginalLiveMixAndComponentTracks() {
        XCTAssertEqual(PlaybackSource.allCases, [.original, .drumBoost, .drumless, .drums])
        XCTAssertEqual(PlaybackSource.original.displayLabel, "Original")
        XCTAssertEqual(PlaybackSource.drumBoost.displayLabel, "Drum Boost")
        XCTAssertEqual(PlaybackSource.drumless.displayLabel, "Drumless")
        XCTAssertEqual(PlaybackSource.drums.displayLabel, "Drums")
    }

    func testPlaybackSourceControlCasesExcludeUnroutedDrumsSource() {
        XCTAssertEqual(PlaybackSource.controlCases, [.original, .drumBoost, .drumless])
    }

    func testLegacyBoostedDrumsPlaybackSourceDecodesAsDrumBoost() throws {
        let data = #""boostedDrums""#.data(using: .utf8)!

        let source = try JSONDecoder().decode(PlaybackSource.self, from: data)

        XCTAssertEqual(source, .drumBoost)
    }

    func testDrumBoostPlaybackSourceEncodesCurrentRawValue() throws {
        let data = try JSONEncoder().encode(PlaybackSource.drumBoost)
        let rawValue = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(rawValue, #""drumBoost""#)
    }

    func testTwoTrackMixAssetCarriesDrumsAndDrumlessTogether() {
        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let asset = TwoTrackMixAsset(
            trackID: trackID,
            drumlessURL: URL(fileURLWithPath: "/tmp/renders/drumless/song.m4a"),
            drumsURL: URL(fileURLWithPath: "/tmp/renders/drums/song.m4a"),
            duration: 180,
            settings: DrumMixSettings(boostDB: 4)
        )

        XCTAssertEqual(asset.trackID, trackID)
        XCTAssertEqual(asset.drumlessURL.lastPathComponent, "song.m4a")
        XCTAssertEqual(asset.drumsURL.lastPathComponent, "song.m4a")
        XCTAssertEqual(asset.duration, 180)
        XCTAssertEqual(asset.settings.boostDB, 4)
    }

    func testPlaybackSourceDisplayLabelsAreUserFacing() {
        XCTAssertEqual(PlaybackSource.original.displayLabel, "Original")
        XCTAssertEqual(PlaybackSource.drumBoost.displayLabel, "Drum Boost")
        XCTAssertEqual(PlaybackSource.drumless.displayLabel, "Drumless")
        XCTAssertEqual(PlaybackSource.drums.displayLabel, "Drums")
    }

    func testPlaybackQueueExposesCurrentTrackIDWhenIndexIsValid() {
        let firstID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let queue = PlaybackQueue(
            playlistID: nil,
            trackIDs: [firstID, secondID],
            currentIndex: 1,
            preferredSource: .drumless
        )

        XCTAssertEqual(queue.currentTrackID, secondID)
    }

    func testPlaybackQueueReturnsNilCurrentTrackWhenIndexIsInvalid() {
        let queue = PlaybackQueue(
            playlistID: nil,
            trackIDs: [],
            currentIndex: 0,
            preferredSource: .drumBoost
        )

        XCTAssertNil(queue.currentTrackID)
    }

    @MainActor
    func testPlaybackAssetUsesOriginalSource() {
        let track = BackbeatTrack(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Original",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/original.m4a")
        )
        let store = LibraryStore(tracks: [track])

        let asset = store.playbackAsset(for: track, preferredSource: .original)

        XCTAssertEqual(asset?.preferredSource, .original)
        XCTAssertEqual(asset?.effectiveSource, .original)
        XCTAssertEqual(asset?.fileURL, track.sourceURL)
    }

    @MainActor
    func testPlaybackAssetUsesDrumBoostRenderWhenAvailable() {
        let boostedURL = URL(fileURLWithPath: "/tmp/boosted.m4a")
        let track = BackbeatTrack(
            title: "Boosted",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/original.m4a"),
            activeRenders: [
                .boostedDrums: RenderRecord(variant: .boostedDrums, fileURL: boostedURL, boostDB: 4)
            ]
        )
        let store = LibraryStore(tracks: [track])

        let asset = store.playbackAsset(for: track, preferredSource: .drumBoost)

        XCTAssertEqual(asset?.preferredSource, .drumBoost)
        XCTAssertEqual(asset?.effectiveSource, .drumBoost)
        XCTAssertEqual(asset?.fileURL, boostedURL)
    }

    @MainActor
    func testPlaybackAssetUsesDrumsRenderWhenAvailable() {
        let drumsURL = URL(fileURLWithPath: "/tmp/drums.m4a")
        let track = BackbeatTrack(
            title: "Drums",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/original.m4a"),
            activeRenders: [
                .drums: RenderRecord(variant: .drums, fileURL: drumsURL, boostDB: 0)
            ]
        )
        let store = LibraryStore(tracks: [track])

        let asset = store.playbackAsset(for: track, preferredSource: .drums)

        XCTAssertEqual(asset?.preferredSource, .drums)
        XCTAssertEqual(asset?.effectiveSource, .drums)
        XCTAssertEqual(asset?.fileURL, drumsURL)
    }

    @MainActor
    func testPlaybackAssetFallsBackToOriginalWhenDrumlessRenderIsMissing() {
        let track = BackbeatTrack(
            title: "Fallback",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/original.m4a")
        )
        let store = LibraryStore(tracks: [track])

        let asset = store.playbackAsset(for: track, preferredSource: .drumless)

        XCTAssertEqual(asset?.preferredSource, .drumless)
        XCTAssertEqual(asset?.effectiveSource, .original)
        XCTAssertEqual(asset?.fileURL, track.sourceURL)
    }
}
