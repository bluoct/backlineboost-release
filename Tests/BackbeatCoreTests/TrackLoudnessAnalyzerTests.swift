import XCTest
@testable import BackbeatCore

final class TrackLoudnessAnalyzerTests: XCTestCase {
    func testBuildsFFmpegLoudnormCommandForSourceFile() {
        let sourceURL = URL(fileURLWithPath: "/tmp/song.m4a")
        let command = TrackLoudnessAnalyzer.loudnormCommand(ffmpegPath: "/opt/homebrew/bin/ffmpeg", sourceURL: sourceURL)

        XCTAssertEqual(command.executablePath, "/opt/homebrew/bin/ffmpeg")
        XCTAssertTrue(command.arguments.contains("-af"))
        XCTAssertTrue(command.arguments.contains("loudnorm=I=-12.0:TP=-1.0:LRA=11.0:print_format=json"))
        XCTAssertEqual(command.arguments.last, "/dev/null")
    }

    func testParsesLoudnormOutputIntoProfile() throws {
        let output = """
        [Parsed_loudnorm_0 @ 0x123] {
            "input_i" : "-18.04",
            "input_tp" : "-2.35"
        }
        """

        let profile = try TrackLoudnessAnalyzer.profile(
            from: output,
            settings: .default,
            analyzedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(profile.integratedLUFS, -18.04, accuracy: 0.001)
        XCTAssertEqual(profile.samplePeakDBFS ?? 0, -2.35, accuracy: 0.001)
        XCTAssertEqual(profile.suggestedGainDB, 1.35, accuracy: 0.001)
    }

    func testParsesLoudnormOutputWithStrayBraceBeforeMarker() throws {
        let output = """
        Input #0, mov,mp4,m4a, from '/tmp/song {live}.m4a':
          Metadata:
            title           : Song {Live Version}
        [Parsed_loudnorm_0 @ 0x123] {
            "input_i" : "-18.04",
            "input_tp" : "-2.35"
        }
        """

        let profile = try TrackLoudnessAnalyzer.profile(
            from: output,
            settings: .default,
            analyzedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(profile.integratedLUFS, -18.04, accuracy: 0.001)
        XCTAssertEqual(profile.samplePeakDBFS ?? 0, -2.35, accuracy: 0.001)
    }

    func testParsesBareJSONWithoutBanner() throws {
        let output = """
        {
            "input_i" : "-18.04",
            "input_tp" : "-2.35"
        }
        """

        let profile = try TrackLoudnessAnalyzer.profile(
            from: output,
            settings: .default,
            analyzedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(profile.integratedLUFS, -18.04, accuracy: 0.001)
    }

    func testThrowsMissingMeasuredLoudnessWhenOutputHasNoJSON() {
        let output = "[Parsed_loudnorm_0 @ 0x123] no json here"

        XCTAssertThrowsError(
            try TrackLoudnessAnalyzer.profile(from: output, settings: .default)
        ) { error in
            guard case TrackLoudnessAnalyzer.Error.missingMeasuredLoudness = error else {
                XCTFail("Expected missingMeasuredLoudness, got \(error)")
                return
            }
        }
    }
}
