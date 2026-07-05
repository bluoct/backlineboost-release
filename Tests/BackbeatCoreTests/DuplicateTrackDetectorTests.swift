import XCTest
@testable import BackbeatCore

final class DuplicateTrackDetectorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateTrackDetectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFile(_ name: String, contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testIdenticalContentIsDuplicateDespiteDifferentName() throws {
        let stored = try makeFile("stored.m4a", contents: "identical-audio-bytes")
        let candidate = try makeFile("candidate-copy.m4a", contents: "identical-audio-bytes")

        let match = DuplicateTrackDetector().existingDuplicate(of: candidate, among: [stored])

        XCTAssertEqual(match, stored)
    }

    func testSameSizeDifferentContentIsNotDuplicate() throws {
        let stored = try makeFile("stored.m4a", contents: "aaaaaaaaaa")
        let candidate = try makeFile("candidate.m4a", contents: "bbbbbbbbbb")

        XCTAssertNil(DuplicateTrackDetector().existingDuplicate(of: candidate, among: [stored]))
    }

    func testDifferentSizeIsNotDuplicate() throws {
        let stored = try makeFile("stored.m4a", contents: "short")
        let candidate = try makeFile("candidate.m4a", contents: "much longer content here")

        XCTAssertNil(DuplicateTrackDetector().existingDuplicate(of: candidate, among: [stored]))
    }

    func testEmptyStoredListIsNotDuplicate() throws {
        let candidate = try makeFile("candidate.m4a", contents: "anything")

        XCTAssertNil(DuplicateTrackDetector().existingDuplicate(of: candidate, among: []))
    }

    func testMissingCandidateIsNotDuplicate() throws {
        let stored = try makeFile("stored.m4a", contents: "anything")
        let missing = directory.appendingPathComponent("nonexistent.m4a")

        XCTAssertNil(DuplicateTrackDetector().existingDuplicate(of: missing, among: [stored]))
    }

    func testMissingStoredFileIsSkippedNotMatched() throws {
        let candidate = try makeFile("candidate.m4a", contents: "fresh")
        let missingStored = directory.appendingPathComponent("gone.m4a")

        XCTAssertNil(DuplicateTrackDetector().existingDuplicate(of: candidate, among: [missingStored]))
    }

    func testPicksTheMatchingStoredFileAmongMany() throws {
        let storedA = try makeFile("a.m4a", contents: "content-A")
        let storedB = try makeFile("b.m4a", contents: "content-B")
        let candidate = try makeFile("candidate.m4a", contents: "content-B")

        let match = DuplicateTrackDetector().existingDuplicate(of: candidate, among: [storedA, storedB])

        XCTAssertEqual(match, storedB)
    }
}
