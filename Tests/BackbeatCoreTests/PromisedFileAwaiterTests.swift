import XCTest
@testable import BackbeatCore

final class PromisedFileAwaiterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromisedFileAwaiterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testReturnsFileAlreadyStable() async throws {
        try Data("audio-bytes".utf8).write(to: directory.appendingPathComponent("done.m4a"))

        let awaiter = PromisedFileAwaiter(timeout: 2, pollInterval: 0.05)
        let urls = await awaiter.stabilizedFiles(named: ["done.m4a"], in: directory)

        XCTAssertEqual(urls.map(\.lastPathComponent), ["done.m4a"])
    }

    func testFindsFileThatAppearsMidWait() async throws {
        let fileURL = directory.appendingPathComponent("late.m4a")
        Task.detached {
            try? await Task.sleep(nanoseconds: 150_000_000)
            try? Data("late-audio".utf8).write(to: fileURL)
        }

        let awaiter = PromisedFileAwaiter(timeout: 3, pollInterval: 0.05)
        let urls = await awaiter.stabilizedFiles(named: ["late.m4a"], in: directory)

        XCTAssertEqual(urls.map(\.lastPathComponent), ["late.m4a"])
    }

    func testMissingFileTimesOutEmpty() async {
        let awaiter = PromisedFileAwaiter(timeout: 0.3, pollInterval: 0.05)
        let urls = await awaiter.stabilizedFiles(named: ["never.m4a"], in: directory)

        XCTAssertTrue(urls.isEmpty)
    }

    func testZeroByteFileIsNotReturned() async throws {
        FileManager.default.createFile(atPath: directory.appendingPathComponent("empty.m4a").path, contents: nil)

        let awaiter = PromisedFileAwaiter(timeout: 0.3, pollInterval: 0.05)
        let urls = await awaiter.stabilizedFiles(named: ["empty.m4a"], in: directory)

        XCTAssertTrue(urls.isEmpty)
    }

    func testTimeoutReturnsStabilizedSubset() async throws {
        try Data("present".utf8).write(to: directory.appendingPathComponent("present.m4a"))

        let awaiter = PromisedFileAwaiter(timeout: 0.4, pollInterval: 0.05)
        let urls = await awaiter.stabilizedFiles(
            named: ["present.m4a", "drm-blocked.m4a"],
            in: directory
        )

        XCTAssertEqual(urls.map(\.lastPathComponent), ["present.m4a"])
    }

    func testEmptyNamesReturnsImmediately() async {
        let awaiter = PromisedFileAwaiter(timeout: 10, pollInterval: 1)
        let urls = await awaiter.stabilizedFiles(named: [], in: directory)

        XCTAssertTrue(urls.isEmpty)
    }
}
