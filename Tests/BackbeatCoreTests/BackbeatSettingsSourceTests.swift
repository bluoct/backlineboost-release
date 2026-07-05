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

    func testSettingsViewExposesAudioToolPathOverrides() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatSettingsView.swift")

        XCTAssertTrue(source.contains("Audio tools"))
        XCTAssertTrue(source.contains("RenderPreflight.setOverridePath"))
        XCTAssertTrue(source.contains("RenderPreflight.resolveCommand"))
        XCTAssertTrue(source.contains("toolRow(command: \"demucs\""))
        XCTAssertTrue(source.contains("toolRow(command: \"ffmpeg\""))
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
