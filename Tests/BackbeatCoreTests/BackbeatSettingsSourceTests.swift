import XCTest

final class BackbeatSettingsSourceTests: XCTestCase {
    func testAppExposesSettingsScene() throws {
        let source = try readSource("Sources/Backbeat/App/BackbeatApp.swift")

        XCTAssertTrue(source.contains("Settings {"))
        XCTAssertTrue(source.contains("BackbeatSettingsView"))
    }

    func testSettingsViewContainsNormalizePlaybackToggle() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatSettingsView.swift")

        XCTAssertTrue(source.contains("Normalize playback volume"))
        XCTAssertTrue(source.contains("store.setPlaybackNormalizationEnabled"))
        XCTAssertTrue(source.contains("Boosts quieter songs"))
    }

    func testSettingsViewExposesRendersFolderChooser() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatSettingsView.swift")

        XCTAssertTrue(source.contains("Section(\"Rendering\")"))
        XCTAssertTrue(source.contains("NSOpenPanel"))
        XCTAssertTrue(source.contains("canChooseDirectories = true"))
        XCTAssertTrue(source.contains("canChooseFiles = false"))
        XCTAssertTrue(source.contains("RenderSettings.setConfiguredRendersFolder"))
        XCTAssertTrue(source.contains("Reset to Default"))
    }

    func testSettingsViewExposesRenderBitratePicker() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatSettingsView.swift")

        XCTAssertTrue(source.contains("RenderBitrate.allCases"))
        XCTAssertTrue(source.contains("RenderSettings.setBitrate"))
        XCTAssertTrue(source.contains("Applies to new renders"))
    }

    // The bundled-weights cut-over removed the Settings "Separation model" section: the
    // checkpoint ships in the app, so there is no first-run download UI to expose.
    func testSettingsViewHasNoSeparationModelSection() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatSettingsView.swift")

        XCTAssertFalse(source.contains("Section(\"Separation model\")"))
        XCTAssertFalse(source.contains("ModelWeightsStatusView"))
    }

    // Task 9 removed the subprocess apparatus: no external audio tools, so the
    // "Audio tools" override section and its RenderPreflight plumbing are gone.
    func testSettingsViewHasNoAudioToolOverrideSection() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatSettingsView.swift")

        XCTAssertFalse(source.contains("Audio tools"))
        XCTAssertFalse(source.contains("RenderPreflight"))
        XCTAssertFalse(source.contains("toolRow"))
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
