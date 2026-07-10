import XCTest
@testable import BackbeatCore

final class MusicPasteboardMetadataParserTests: XCTestCase {
    func testExtractsLocationsFromiTunesTracksShape() throws {
        let plist: [String: Any] = [
            "Major Version": 1,
            "Tracks": [
                "1001": [
                    "Name": "Song One",
                    "Location": "file:///Users/tester/Music/Song%20One.m4a"
                ],
                "1002": [
                    "Name": "Song Two",
                    "Location": "file:///Users/tester/Music/Song%20Two.mp3"
                ]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        let urls = MusicPasteboardMetadataParser.locationURLs(from: data)

        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls.allSatisfy(\.isFileURL))
        XCTAssertEqual(
            Set(urls.map(\.lastPathComponent)),
            ["Song One.m4a", "Song Two.mp3"]
        )
    }

    func testExtractsLocationsFromArrayShape() throws {
        let plist: [[String: Any]] = [
            ["Location": "file:///tmp/a.m4a"],
            ["Location": "file:///tmp/b.wav"]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)

        let urls = MusicPasteboardMetadataParser.locationURLs(from: data)

        XCTAssertEqual(urls.map(\.lastPathComponent), ["a.m4a", "b.wav"])
    }

    func testSkipsNonFileLocations() throws {
        let plist: [String: Any] = [
            "Tracks": [
                "1": ["Location": "https://music.apple.com/library/song.m4a"],
                "2": ["Location": "file:///tmp/local.m4a"]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        let urls = MusicPasteboardMetadataParser.locationURLs(from: data)

        XCTAssertEqual(urls.map(\.lastPathComponent), ["local.m4a"])
    }

    func testSkipsUnsupportedExtensions() throws {
        let plist: [String: Any] = [
            "Tracks": [
                "1": ["Location": "file:///tmp/protected.m4p"],
                "2": ["Location": "file:///tmp/notes.pdf"],
                "3": ["Location": "file:///tmp/song.flac"]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        let urls = MusicPasteboardMetadataParser.locationURLs(from: data)

        XCTAssertEqual(urls.map(\.lastPathComponent), ["song.flac"])
    }

    func testDeduplicatesRepeatedLocations() throws {
        let plist: [[String: Any]] = [
            ["Location": "file:///tmp/same.m4a"],
            ["Location": "file:///tmp/same.m4a"]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        XCTAssertEqual(MusicPasteboardMetadataParser.locationURLs(from: data).count, 1)
    }

    func testMalformedDataYieldsEmpty() {
        let garbage = Data("this is not a property list".utf8)

        XCTAssertTrue(MusicPasteboardMetadataParser.locationURLs(from: garbage).isEmpty)
        XCTAssertTrue(MusicPasteboardMetadataParser.locationURLs(from: Data()).isEmpty)
    }

    func testPromiseTypeIdentifiersMatchLegacyCarbonFlavors() {
        XCTAssertEqual(
            MusicPasteboardMetadataParser.filePromiseTypeIdentifiers,
            ["com.apple.pasteboard.promised-file-url", "com.apple.pasteboard.promised-file-content-type"]
        )
    }

    func testMetadataIdentifiersIncludeCurrentTVFlavor() {
        // Current Music vends its per-track metadata plist as
        // com.apple.tv.metadata; the legacy iTunes/Music names stay for older
        // macOS. Dropping the tv flavor silently breaks cloud-track imports.
        XCTAssertTrue(
            MusicPasteboardMetadataParser.metadataTypeIdentifiers.contains("com.apple.tv.metadata")
        )
    }

    // Mirrors the real com.apple.tv.metadata payload a Music drag vends for a
    // DRM-protected Apple Music download: an iTunes `Tracks` dict whose track
    // has a local `.m4p` Location and `Protected == true`.
    func testUnimportableTracksReportsProtectedAppleMusicDownload() throws {
        let plist: [String: Any] = [
            "Music Folder": "file:///Users/tester/Music/Music/",
            "Tracks": [
                "19384": [
                    "Name": "Take It to the Limit",
                    "Protected": true,
                    "Location": "file:///Users/tester/Music/Music/Apple%20Music/Eagles/Hits/08%20Take%20It%20to%20the%20Limit.m4p"
                ]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        XCTAssertTrue(MusicPasteboardMetadataParser.locationURLs(from: data).isEmpty)
        XCTAssertEqual(
            MusicPasteboardMetadataParser.unimportableTracks(from: data),
            [MusicPasteboardMetadataParser.UnimportableTrack(title: "Take It to the Limit", isProtected: true)]
        )
    }

    func testUnimportableTracksOmitsImportableTracks() throws {
        let plist: [String: Any] = [
            "Tracks": [
                "1": ["Name": "Local Song", "Location": "file:///Users/tester/Music/Local%20Song.m4a"]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        XCTAssertEqual(MusicPasteboardMetadataParser.locationURLs(from: data).count, 1)
        XCTAssertTrue(MusicPasteboardMetadataParser.unimportableTracks(from: data).isEmpty)
    }

    func testUnimportableTracksReportsUnsupportedExtension() throws {
        let plist: [[String: Any]] = [
            ["Name": "Notes", "Location": "file:///tmp/notes.pdf"]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)

        XCTAssertEqual(
            MusicPasteboardMetadataParser.unimportableTracks(from: data),
            [MusicPasteboardMetadataParser.UnimportableTrack(title: "Notes", isProtected: false)]
        )
    }

    func testUnimportableTrackFallsBackToFilenameWhenUnnamed() throws {
        let plist: [[String: Any]] = [
            ["Location": "file:///tmp/protected.m4p"]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        XCTAssertEqual(
            MusicPasteboardMetadataParser.unimportableTracks(from: data),
            [MusicPasteboardMetadataParser.UnimportableTrack(title: "protected", isProtected: false)]
        )
    }

    // A multi-track Music drag vends a real file URL for file-reference
    // tracks only, while the combined metadata plist describes every track —
    // the drop must import the union or a mixed drag loses songs
    // (2026-07-08: a seven-track drop imported one).
    func testMergedImportCandidatesUnionsBothSources() {
        let direct = [URL(fileURLWithPath: "/tmp/file-backed.m4a")]
        let metadata = [
            URL(fileURLWithPath: "/tmp/cloud-one.m4a"),
            URL(fileURLWithPath: "/tmp/cloud-two.m4a")
        ]

        let merged = MusicPasteboardMetadataParser.mergedImportCandidates(
            direct: direct,
            metadataLocations: metadata
        )

        XCTAssertEqual(
            merged.map(\.lastPathComponent),
            ["file-backed.m4a", "cloud-one.m4a", "cloud-two.m4a"]
        )
    }

    func testMergedImportCandidatesDeduplicatesByStandardizedPath() {
        // The metadata plist usually repeats the file-backed track's Location;
        // the same file must not import twice (a second copy would trip the
        // duplicate detector mid-batch and raise a spurious warning).
        let direct = [URL(fileURLWithPath: "/tmp/subdir/../same.m4a")]
        let metadata = [
            URL(fileURLWithPath: "/tmp/same.m4a"),
            URL(fileURLWithPath: "/tmp/other.m4a")
        ]

        let merged = MusicPasteboardMetadataParser.mergedImportCandidates(
            direct: direct,
            metadataLocations: metadata
        )

        XCTAssertEqual(merged.map(\.lastPathComponent), ["same.m4a", "other.m4a"])
    }

    func testMergedImportCandidatesHandleEmptySources() {
        let only = [URL(fileURLWithPath: "/tmp/a.m4a")]

        XCTAssertEqual(
            MusicPasteboardMetadataParser.mergedImportCandidates(direct: [], metadataLocations: only),
            only
        )
        XCTAssertEqual(
            MusicPasteboardMetadataParser.mergedImportCandidates(direct: only, metadataLocations: []),
            only
        )
        XCTAssertTrue(
            MusicPasteboardMetadataParser.mergedImportCandidates(direct: [], metadataLocations: []).isEmpty
        )
    }

    func testUnimportableTracksIgnoreStreamingLocations() throws {
        // A cloud/streaming entry with a non-file Location is not a local
        // dead-end — nothing to warn about.
        let plist: [String: Any] = [
            "Tracks": ["1": ["Name": "Streamed", "Location": "https://music.apple.com/song"]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        XCTAssertTrue(MusicPasteboardMetadataParser.unimportableTracks(from: data).isEmpty)
    }
}
