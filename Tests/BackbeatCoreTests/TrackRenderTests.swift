import XCTest
@testable import BackbeatCore

final class TrackRenderTests: XCTestCase {
    func testTrackPromotesDrumsAndDrumlessAsCurrentPracticeAssets() {
        var track = BackbeatTrack(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Paper Crown",
            artist: "Velvet Static",
            duration: 311,
            status: .rendering,
            sourceURL: URL(fileURLWithPath: "/tmp/source.m4a")
        )

        let drumsRender = RenderRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            variant: .drums,
            fileURL: URL(fileURLWithPath: "/tmp/renders/drums/paper-crown.m4a"),
            boostDB: 0,
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let drumlessRender = RenderRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            variant: .drumless,
            fileURL: URL(fileURLWithPath: "/tmp/renders/drumless/paper-crown.m4a"),
            boostDB: 0,
            createdAt: Date(timeIntervalSince1970: 31)
        )

        track.promote(render: drumsRender)
        track.promote(render: drumlessRender)

        XCTAssertEqual(track.activeRender(for: .drums), drumsRender)
        XCTAssertEqual(track.activeRender(for: .drumless), drumlessRender)
        XCTAssertEqual(track.status, .ready)
    }

    func testDrumMixSettingsClampBoostRange() {
        XCTAssertEqual(DrumMixSettings(boostDB: -2).boostDB, 0)
        XCTAssertEqual(DrumMixSettings(boostDB: 3.25).boostDB, 3.25)
        XCTAssertEqual(DrumMixSettings(boostDB: 12).boostDB, 8)
    }

    func testDrumMixSettingsClampsDecodedBoostRange() throws {
        let data = #"{"boostDB":12}"#.data(using: .utf8)!

        let settings = try JSONDecoder().decode(DrumMixSettings.self, from: data)

        XCTAssertEqual(settings.boostDB, 8)
    }

    func testPromotingNewBoostedRenderReplacesPreviousBoostedRender() {
        var track = BackbeatTrack(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Paper Crown",
            artist: "Velvet Static",
            duration: 311,
            status: .ready,
            sourceURL: URL(fileURLWithPath: "/tmp/source.m4a")
        )

        let oldRender = RenderRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            variant: .boostedDrums,
            fileURL: URL(fileURLWithPath: "/tmp/renders/boosted_drums/old.m4a"),
            boostDB: 4,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let newRender = RenderRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            variant: .boostedDrums,
            fileURL: URL(fileURLWithPath: "/tmp/renders/boosted_drums/new.m4a"),
            boostDB: 6,
            createdAt: Date(timeIntervalSince1970: 20)
        )

        track.promote(render: oldRender)
        track.promote(render: newRender)

        XCTAssertEqual(track.activeRender(for: .boostedDrums), newRender)
        XCTAssertEqual(track.activeRenders.count, 1)
    }
}
