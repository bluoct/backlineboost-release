import XCTest

final class LibraryReRenderSourceTests: XCTestCase {
    func testReadyTracksOfferAConfirmedReRenderAction() throws {
        let source = try readSource("Sources/Backbeat/Views/LibraryView.swift")

        XCTAssertTrue(source.contains("if track.status == .ready {"))
        XCTAssertTrue(source.contains("reRenderCandidate = track"))
        XCTAssertTrue(source.contains("\"Re-render this track?\""))
        XCTAssertTrue(source.contains("reRenderConfirmationBinding"))
        XCTAssertTrue(source.contains("accessibilityLabel(\"Re-render\")"))

        // The row button must only stage a candidate for confirmation — the
        // enqueue itself must live behind the alert, not fire on tap (D-105).
        let readyBranch = try XCTUnwrap(
            source.range(of: "if track.status == .ready {"),
            "expected a dedicated .ready branch for the re-render action"
        )
        let readyBranchButtonEnd = try XCTUnwrap(
            source.range(of: "}", range: readyBranch.upperBound..<source.endIndex)
        )
        let readyButtonBody = source[readyBranch.upperBound..<readyBranchButtonEnd.lowerBound]
        XCTAssertTrue(readyButtonBody.contains("reRenderCandidate = track"))
        XCTAssertFalse(
            readyButtonBody.contains("renderQueue.enqueue"),
            "the re-render button must stage a candidate for confirmation, not enqueue directly"
        )

        let yesButton = try XCTUnwrap(source.range(of: "Button(\"Yes\") {"))
        let yesButtonEnd = try XCTUnwrap(source.range(of: "}", range: yesButton.upperBound..<source.endIndex))
        let yesButtonBody = source[yesButton.upperBound..<yesButtonEnd.lowerBound]
        XCTAssertTrue(
            yesButtonBody.contains("renderQueue.enqueue(track.id)"),
            "the enqueue call must live inside the confirmation alert's Yes action"
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
