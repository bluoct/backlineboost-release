import XCTest
@testable import BackbeatCore

final class AudioMetadataReaderTests: XCTestCase {
    func testReadsMetadataFromFullSongM4A() async throws {
        guard let path = ProcessInfo.processInfo.environment["BACKBEAT_TEST_AUDIO"] else {
            throw XCTSkip("Set BACKBEAT_TEST_AUDIO to a local audio file to run this test.")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("BACKBEAT_TEST_AUDIO does not point to an existing file.")
        }

        let metadata = try await AudioMetadataReader().read(url: url)

        XCTAssertFalse(metadata.fileName.isEmpty)
        XCTAssertGreaterThan(metadata.duration, 0)
        XCTAssertGreaterThan(metadata.sampleRate, 0)
        XCTAssertGreaterThanOrEqual(metadata.channelCount, 1)
    }
}
