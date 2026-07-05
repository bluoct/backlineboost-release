import XCTest
@testable import BackbeatCore

final class ManagedAudioLibraryTests: XCTestCase {
    func testStoresImportedAudioUnderManagedSourceDirectory() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = temporaryRoot.appendingPathComponent("sources", isDirectory: true)
        let importURL = temporaryRoot.appendingPathComponent("sample-song.m4a")
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: importURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let library = ManagedAudioLibrary(sourceDirectory: sourceDirectory)
        let storedURL = try library.storeSourceFile(importURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))
        XCTAssertEqual(storedURL.lastPathComponent, "sample-song.m4a")
        XCTAssertEqual(storedURL.deletingLastPathComponent().deletingLastPathComponent(), sourceDirectory)
        XCTAssertEqual(try Data(contentsOf: storedURL), Data("audio".utf8))
    }
}
