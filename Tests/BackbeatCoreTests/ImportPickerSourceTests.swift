import XCTest

final class ImportPickerSourceTests: XCTestCase {
    func testTrackImporterUsesSharedExplicitAudioContentTypes() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        XCTAssertTrue(source.contains("AudioImportFilter.supportedContentTypes"))
        XCTAssertFalse(source.contains("allowedContentTypes: [.audio]"))
    }

    func testSingleFileImporterServesTrackAndFolderModes() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        let importerCount = source.components(separatedBy: ".fileImporter(").count - 1
        XCTAssertEqual(
            importerCount, 1,
            "Two .fileImporter modifiers on one view conflict in SwiftUI and only the last presents — keep a single mode-switched importer."
        )
        XCTAssertTrue(source.contains("enum BackbeatImporter"))
        XCTAssertTrue(source.contains("allowedContentTypes: activeImporter.allowedContentTypes"))
        XCTAssertTrue(source.contains("allowsMultipleSelection: activeImporter.allowsMultipleSelection"))
    }

    func testTrackImportAcceptsMultipleSelectedFiles() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        XCTAssertTrue(source.contains("importAudioFiles(urls, managesSecurityScope: true, musicLibraryArtwork: false)"))
        XCTAssertFalse(
            source.contains("importAudioFiles([url], managesSecurityScope: true"),
            "Track import must feed every selected URL through the shared import loop, not just the first."
        )
    }

    private func readSource(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
