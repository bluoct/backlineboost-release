import XCTest

final class TrackTileArtworkSourceTests: XCTestCase {
    func testTrackTileLoadsArtworkAsynchronouslyThroughTheThumbnailRepository() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatStyle.swift")

        XCTAssertTrue(source.contains("@State private var artworkImage"))
        XCTAssertTrue(source.contains(".task(id: track.artworkURL)"))
        XCTAssertTrue(source.contains("ArtworkThumbnails.store.thumbnail("))
        XCTAssertFalse(source.contains("NSImage(contentsOf:"), "TrackTile must not decode artwork synchronously from disk.")
        XCTAssertFalse(source.contains("ArtworkImageCache.image(for:"), "the old synchronous cache symbol must be gone.")
        XCTAssertTrue(
            source.contains("if artworkImageURL != track.artworkURL {"),
            "a tile whose track changes under stable identity must clear the previous track's art instead of showing it next to the new title"
        )
    }

    func testArtworkThumbnailsRepositoryDownsamplesAndByteBudgets() throws {
        let source = try readSource("Sources/Backbeat/Views/ArtworkThumbnails.swift")

        XCTAssertTrue(source.contains("CGImageSourceCreateThumbnailAtIndex"))
        XCTAssertTrue(source.contains("kCGImageSourceThumbnailMaxPixelSize"))
        XCTAssertTrue(source.contains("totalCostLimit"))
        XCTAssertFalse(
            source.contains("NSImage(contentsOf:"),
            "the thumbnail repository must decode via ImageIO, not a full-resolution NSImage load."
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
