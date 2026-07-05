import XCTest

final class AppBrandIconSourceTests: XCTestCase {
    func testBrandIconAssetIsCommittedAndNonEmpty() throws {
        let url = packageRoot().appendingPathComponent("Sources/Backbeat/Resources/BackbeatIcon.png")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "The UI brand icon must ship as a loadable PNG resource."
        )
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 1_000, "BackbeatIcon.png looks empty or truncated.")
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "BackbeatIcon.png must be a real PNG.")
    }

    func testBrandIconLoaderResolvesBundleThenModule() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatBrandIcon.swift")
        XCTAssertTrue(source.contains("Bundle.main.resourceURL"))
        XCTAssertTrue(source.contains("Bundle.module.url"))
        XCTAssertTrue(source.contains("NSImage(contentsOf:"))
        XCTAssertTrue(source.contains("struct AppIconBadge"))
    }

    func testSidebarLogoUsesTheAppIcon() throws {
        let source = try readSource("Sources/Backbeat/Views/SidebarView.swift")
        XCTAssertTrue(source.contains("BackbeatBrandIcon"))
        XCTAssertTrue(source.contains("AppIconBadge"))
    }

    func testArtworkFallbackUsesTheAppIcon() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatStyle.swift")
        XCTAssertTrue(
            source.contains("BackbeatBrandIcon.image"),
            "Artwork-less tracks must fall back to the app icon."
        )
        // Keep the artwork cache path intact (mirrors TrackTileArtworkSourceTests).
        XCTAssertTrue(source.contains("let artworkImage = cachedArtworkImage"))
        XCTAssertTrue(source.contains("ArtworkImageCache.image(for:"))
        XCTAssertFalse(
            source.contains("NSImage(contentsOf:"),
            "TrackTile must not decode images from disk; the brand-icon loader owns that."
        )
    }

    func testEmptyStatesUseTheAppIcon() throws {
        let library = try readSource("Sources/Backbeat/Views/LibraryView.swift")
        XCTAssertTrue(library.contains("AppIconBadge"))
        let miniPlayer = try readSource("Sources/Backbeat/Views/MiniPlayerView.swift")
        XCTAssertTrue(miniPlayer.contains("AppIconBadge"))
    }

    func testBuildScriptCopiesBrandIconIntoBundle() throws {
        let source = try readSource("script/build_and_run.sh")
        XCTAssertTrue(source.contains("BackbeatIcon.png"))
        XCTAssertTrue(source.contains("cp \"$BRAND_ICON_SOURCE\" \"$BRAND_ICON_DEST\""))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }
}
