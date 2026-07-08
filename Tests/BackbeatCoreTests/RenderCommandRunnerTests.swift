import XCTest
@testable import BackbeatCore

final class RenderCommandRunnerTests: XCTestCase {
    func testRequireNonEmptyFileThrowsInvalidOutputForMissingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        XCTAssertThrowsError(try RenderCommandRunner.requireNonEmptyFile(url)) { error in
            guard case BoostedDrumsRenderError.invalidOutput(let failedURL) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failedURL, url)
        }
    }

    func testRequireNonEmptyFileThrowsInvalidOutputForEmptyFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        XCTAssertThrowsError(try RenderCommandRunner.requireNonEmptyFile(url)) { error in
            guard case BoostedDrumsRenderError.invalidOutput(let failedURL) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failedURL, url)
        }
    }

    func testRequireNonEmptyFileReturnsForNonEmptyFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0x1]).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        XCTAssertNoThrow(try RenderCommandRunner.requireNonEmptyFile(url))
    }
}
