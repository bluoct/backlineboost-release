import XCTest

final class DuplicateImportWarningSourceTests: XCTestCase {
    func testImportChecksForDuplicatesBeforeStoringTheFile() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        let detectorRange = source.range(of: "DuplicateTrackDetector()")
        let storeRange = source.range(of: "ManagedAudioLibrary().storeSourceFile")
        XCTAssertNotNil(detectorRange)
        XCTAssertNotNil(storeRange)
        if let detectorRange, let storeRange {
            XCTAssertTrue(
                detectorRange.lowerBound < storeRange.lowerBound,
                "The duplicate check must run before the file is copied into the managed library, or every duplicate still leaves an orphaned copy."
            )
        }
    }

    func testDuplicateWarningAlertExists() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        XCTAssertTrue(source.contains(".alert(\"Already in library\""))
        XCTAssertTrue(source.contains("duplicateWarningMessage"))
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
