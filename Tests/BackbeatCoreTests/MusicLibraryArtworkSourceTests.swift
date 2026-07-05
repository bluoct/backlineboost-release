import XCTest

/// Music-drag imports byte-copy the raw on-disk library file, whose artwork
/// lives in Music's database rather than the file (D-087) — so the import
/// path recovers it via the iTunesLibrary framework. These pins guard the
/// wiring the diagnosis depends on: exact location matching, the Music-drag
/// gate on the permission-prompting lookup, and the bundle identity that
/// keeps the "Media & Apple Music" consent prompt readable and persistent.
final class MusicLibraryArtworkSourceTests: XCTestCase {
    func testProviderMatchesByOnDiskLocationOnly() throws {
        let source = try readSource("Sources/Backbeat/Services/MusicLibraryArtworkProvider.swift")

        XCTAssertTrue(
            source.contains("import iTunesLibrary"),
            "Artwork for raw library files comes from Music's database via the iTunesLibrary framework."
        )
        XCTAssertTrue(
            source.contains("ITLibrary(apiVersion:"),
            "A fresh ITLibrary per lookup keeps the snapshot current for tracks added to Music just before the drag."
        )
        XCTAssertTrue(
            source.contains("location?.standardizedFileURL.path == targetPath"),
            "Matching must stay location-exact: title matching confuses same-titled tracks (Anthrax vs Nine Inch Nails \"Only\")."
        )
        XCTAssertFalse(
            source.contains("item.title") && source.contains("first(where: { $0.title"),
            "No fuzzy title/artist fallback — a wrong-album cover is worse than none."
        )
    }

    func testImportLooksUpMusicArtworkOnlyForMusicDragsAndOnlyWhenArtless() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        XCTAssertTrue(
            source.contains("if artworkData == nil && musicLibraryArtwork {"),
            "Embedded artwork always wins; the library lookup is a fallback for artless files, gated to Music-drag imports so Finder/panel imports never raise the media-library consent prompt."
        )
        XCTAssertTrue(
            source.contains("MusicLibraryArtworkProvider().artworkData(forFileAt: url)"),
            "The lookup must use the original dragged URL — it is the path Music's own database records."
        )
        XCTAssertTrue(
            source.contains("import.artwork stored=\\(artworkURL != nil) source=\\(artworkSource, privacy: .public)"),
            "The structured source= field (embedded|musiclibrary|none) is how a missing graphic gets diagnosed from debug.log."
        )
        XCTAssertTrue(
            source.contains("musicLibraryArtwork: false"),
            "Finder drops, the import panel, and folder imports must keep the lookup disabled."
        )
    }

    func testBundleIdentityKeepsTheConsentPromptReadableAndPersistent() throws {
        let script = try readSource("script/build_and_run.sh")

        XCTAssertTrue(
            script.contains("NSAppleMusicUsageDescription"),
            "The media-library consent prompt must explain why Backbeat reads the Music library."
        )
        XCTAssertTrue(
            script.contains("CFBundleShortVersionString") && script.contains("CFBundleDisplayName"),
            "Without a display name and version the TCC prompt labels the app with garbage (the observed \"2.1.201\")."
        )
        XCTAssertTrue(
            script.contains("security find-identity -v -p codesigning"),
            "A stable signing identity is what lets the one-time TCC grant survive rebuilds; ad-hoc re-signing resets it every build."
        )
        XCTAssertTrue(
            script.contains("BACKBEAT_CODESIGN_IDENTITY"),
            "The identity must stay overridable for machines with several certificates."
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
