import XCTest
@testable import BackbeatCore

final class AudioImportFilterTests: XCTestCase {
    func testFiltersDroppedURLsToSupportedAudioFilesInOriginalOrder() {
        let urls = [
            URL(fileURLWithPath: "/tmp/readme.txt"),
            URL(fileURLWithPath: "/tmp/session.aac"),
            URL(fileURLWithPath: "/tmp/bounce.aif"),
            URL(fileURLWithPath: "/tmp/mix.aiff"),
            URL(fileURLWithPath: "/tmp/master.flac"),
            URL(fileURLWithPath: "/tmp/song.m4a"),
            URL(fileURLWithPath: "/tmp/demo.mp3"),
            URL(fileURLWithPath: "/tmp/beat.WAV"),
            URL(fileURLWithPath: "/tmp/artwork.png")
        ]

        let audioURLs = AudioImportFilter.audioFileURLs(from: urls)

        XCTAssertEqual(
            audioURLs.map(\.lastPathComponent),
            ["session.aac", "bounce.aif", "mix.aiff", "master.flac", "song.m4a", "demo.mp3", "beat.WAV"]
        )
    }

    func testProvidesExplicitPickerContentTypesForEverySupportedExtension() {
        for pathExtension in AudioImportFilter.supportedAudioExtensions {
            XCTAssertFalse(identifiersForExtension(pathExtension).isEmpty, "\(pathExtension) should be represented in picker content types.")
        }
    }

    private func identifiersForExtension(_ pathExtension: String) -> [String] {
        AudioImportFilter.supportedContentTypes
            .filter { type in
                type.preferredFilenameExtension == pathExtension
                    || type.tags[.filenameExtension]?.contains(pathExtension) == true
            }
            .map(\.identifier)
    }
}
