import XCTest

final class AppBundleIconTests: XCTestCase {
    func testBuildScriptWiresDockAndLauncherIconIntoAppBundle() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = packageRoot.appendingPathComponent("script/build_and_run.sh")
        let iconArchiveURL = packageRoot.appendingPathComponent("icons/Backbeat.iconset.zip")
        let source = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(FileManager.default.fileExists(atPath: iconArchiveURL.path))
        XCTAssertTrue(source.contains("APP_RESOURCES=\"$APP_CONTENTS/Resources\""))
        XCTAssertTrue(source.contains("ICON_ARCHIVE=\"$ROOT_DIR/icons/Backbeat.iconset.zip\""))
        XCTAssertTrue(source.contains("iconutil -c icns"))
        XCTAssertTrue(source.contains("tiff2icns"))
        XCTAssertTrue(source.contains("cp \"$BUILD_ICON\" \"$APP_ICON\""))
        XCTAssertTrue(source.contains("<key>CFBundleIconFile</key>"))
        XCTAssertTrue(source.contains("<string>$APP_ICON_NAME</string>"))
    }
}
