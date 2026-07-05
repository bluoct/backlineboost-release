import XCTest

final class BackbeatHelpSourceTests: XCTestCase {
    func testAppExposesBackbeatHelpWindowAndCommand() throws {
        let source = try readSource("Sources/Backbeat/App/BackbeatApp.swift")

        XCTAssertTrue(source.contains("BackbeatHelpCommands()"))
        XCTAssertTrue(source.contains("Window(BackbeatHelpWindow.title"))
        XCTAssertTrue(source.contains("BackbeatHelpView()"))
    }

    func testHelpCommandReplacesDefaultUnavailableHelpAction() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatHelpView.swift")

        XCTAssertTrue(source.contains("CommandGroup(replacing: .help)"))
        XCTAssertTrue(source.contains("openWindow(id: BackbeatHelpWindow.id)"))
        XCTAssertTrue(source.contains(".keyboardShortcut(\"/\", modifiers: [.command, .shift])"))
    }

    func testHelpViewLoadsBundledLocalHelpFile() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatHelpView.swift")

        XCTAssertTrue(source.contains("import WebKit"))
        XCTAssertTrue(source.contains("WKWebView"))
        XCTAssertTrue(source.contains("BackbeatHelpWindow.indexURL"))
        XCTAssertTrue(source.contains("loadFileURL"))
    }

    func testHelpFileContainsManualReadmeInstallAndLegalNotices() throws {
        let source = try readSource("Sources/Backbeat/Resources/Help/index.html")

        XCTAssertTrue(source.contains("<title>Backline Boost Help</title>"))
        XCTAssertTrue(source.contains("User Manual"))
        XCTAssertTrue(source.contains("README"))
        XCTAssertTrue(source.contains("Install"))
        XCTAssertTrue(source.contains("Legal Notices"))
        XCTAssertTrue(source.contains("FFmpeg"))
        XCTAssertTrue(source.contains("Demucs"))
    }

    func testBuildScriptCopiesHelpResourcesIntoAppBundle() throws {
        let source = try readSource("script/build_and_run.sh")

        XCTAssertTrue(source.contains("HELP_SOURCE_DIR"))
        XCTAssertTrue(source.contains("HELP_RESOURCES"))
        XCTAssertTrue(source.contains("cp -R \"$HELP_SOURCE_DIR/.\" \"$HELP_RESOURCES/\""))
    }

    func testPackageDeclaresHelpResourcesForSwiftPMBuilds() throws {
        let source = try readSource("Package.swift")

        XCTAssertTrue(source.contains("resources: [.copy(\"Resources\")]"))
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
