import XCTest

final class TrackTileArtworkSourceTests: XCTestCase {
    func testTrackTileResolvesArtworkThroughTheSharedCacheOncePerBody() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatStyle.swift")

        XCTAssertTrue(source.contains("ArtworkImageCache.image(for:"))
        XCTAssertTrue(source.contains("let artworkImage = cachedArtworkImage"), "body must bind the cached image once instead of decoding per usage.")
        XCTAssertFalse(source.contains("NSImage(contentsOf:"), "TrackTile must not decode artwork from disk on every body evaluation.")
    }

    func testArtworkImageCacheIsNSCacheBacked() throws {
        let source = try readSource("Sources/Backbeat/Views/ArtworkImageCache.swift")

        XCTAssertTrue(source.contains("NSCache<NSURL, NSImage>"))
        XCTAssertTrue(source.contains("NSImage(contentsOf:"))
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
