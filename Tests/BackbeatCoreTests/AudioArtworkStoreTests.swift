import XCTest
@testable import BackbeatCore

final class AudioArtworkStoreTests: XCTestCase {
    func testStoresArtworkDataUnderArtworkDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbeat-artwork-\(UUID().uuidString)", isDirectory: true)
        let artworkDirectory = root.appendingPathComponent("artwork", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let store = AudioArtworkStore(artworkDirectory: artworkDirectory)
        let trackID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let data = Data([0xFF, 0xD8, 0xFF, 0xE0])

        let url = try XCTUnwrap(store.storeArtwork(data, contentType: "public.jpeg", trackID: trackID))

        XCTAssertEqual(url.deletingLastPathComponent(), artworkDirectory)
        XCTAssertEqual(url.lastPathComponent, "11111111-2222-3333-4444-555555555555.jpg")
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testStoreArtworkReturnsNilWhenDataIsMissing() throws {
        let store = AudioArtworkStore(
            artworkDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("backbeat-artwork-\(UUID().uuidString)", isDirectory: true)
        )

        XCTAssertNil(try store.storeArtwork(nil, contentType: nil, trackID: UUID()))
    }
}
