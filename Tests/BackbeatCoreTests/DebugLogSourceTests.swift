import XCTest

/// The debug-log capture and its wiring live in the `Backbeat` executable,
/// which the test target can't import, so pin the behavior by reading the
/// source (the project's `*SourceTests` convention).
final class DebugLogSourceTests: XCTestCase {
    func testSettingsExposesDebugLogToggle() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatSettingsView.swift")
        XCTAssertTrue(source.contains("Section(\"Diagnostics\")"))
        XCTAssertTrue(
            source.contains("Write debug log"),
            "Settings must expose the debug-log toggle the user asked for."
        )
        XCTAssertTrue(source.contains("debugLog.setEnabled"))
        XCTAssertTrue(
            source.contains("activateFileViewerSelecting"),
            "The captured file must be revealable so it can be shared for debugging."
        )
    }

    func testControllerCapturesViaLogStreamToFile() throws {
        let source = try readSource("Sources/Backbeat/Services/DebugLogController.swift")
        XCTAssertTrue(
            source.contains("/usr/bin/log"),
            "Capture must use the same unified-log stream as build_and_run.sh --logs."
        )
        XCTAssertTrue(source.contains("\"stream\""))
        XCTAssertTrue(source.contains("--predicate"))
        XCTAssertTrue(
            source.contains("FileHandle(forWritingTo:"),
            "The stream must be redirected to debug.log."
        )
        XCTAssertTrue(
            source.contains(".terminate()"),
            "The capture child must be terminable so it does not outlive the app."
        )
        XCTAssertTrue(
            source.contains("reapOrphanedChild"),
            "An unclean exit orphans the capture child; the next start must reap it so they can't accumulate."
        )
        XCTAssertTrue(source.contains("setLastCaptureChildPID"))
    }

    func testAppStartsAndStopsCapture() throws {
        let source = try readSource("Sources/Backbeat/App/BackbeatApp.swift")
        XCTAssertTrue(source.contains("DebugLogController()"))
        XCTAssertTrue(
            source.contains("startIfEnabled()"),
            "Capture must resume at launch when the user left it enabled."
        )
        XCTAssertTrue(
            source.contains("stopDebugLogOnTerminate"),
            "Capture must stop on quit so the log child does not leak."
        )
        XCTAssertTrue(source.contains("BackbeatSettingsView(store: store, debugLog: debugLog)"))
    }

    func testImportPathEmitsStructuredMarkers() throws {
        // The import pipeline now lives in Core (F2); its per-file markers are
        // pinned by reading the Core source, not the root view.
        let source = try readSource("Sources/BackbeatCore/Services/TrackImportPipeline.swift")
        // Dotted `area.event` markers keep the import lifecycle greppable, and
        // the artwork marker is what a missing-artwork report will be read from.
        XCTAssertTrue(source.contains("DebugLog.importing"))
        XCTAssertTrue(source.contains("import.start"))
        XCTAssertTrue(source.contains("import.metadata"))
        XCTAssertTrue(source.contains("import.artwork"))
        XCTAssertTrue(source.contains("import.done"))
    }

    private func readSource(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
