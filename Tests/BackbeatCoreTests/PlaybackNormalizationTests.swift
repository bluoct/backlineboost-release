import XCTest
@testable import BackbeatCore

final class PlaybackNormalizationTests: XCTestCase {
    func testDefaultSettingsBoostQuietTracksAndBarelyCutLoudTracks() {
        let settings = PlaybackNormalizationSettings.default

        XCTAssertEqual(settings.suggestedGainDB(integratedLUFS: -18, samplePeakDBFS: -8), 6, accuracy: 0.001)
        XCTAssertEqual(settings.suggestedGainDB(integratedLUFS: -15, samplePeakDBFS: -8), 3, accuracy: 0.001)
        XCTAssertEqual(settings.suggestedGainDB(integratedLUFS: -8, samplePeakDBFS: -1), -1.5, accuracy: 0.001)
    }

    func testPositiveGainIsCappedByPeakHeadroom() {
        let settings = PlaybackNormalizationSettings.default

        XCTAssertEqual(settings.suggestedGainDB(integratedLUFS: -18, samplePeakDBFS: -2), 1, accuracy: 0.001)
    }

    func testNormalizationResolverReturnsZeroWhenDisabledOrMissingProfile() {
        let track = BackbeatTrack(
            title: "Song",
            duration: 180,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/song.m4a")
        )

        XCTAssertEqual(PlaybackNormalization.gainDB(for: track, settings: .default), 0)
        XCTAssertEqual(PlaybackNormalization.gainDB(for: track, settings: .disabled), 0)
    }
}
