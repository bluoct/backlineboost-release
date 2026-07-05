import XCTest
@testable import BackbeatCore

@MainActor
final class InitialLibraryTests: XCTestCase {
    func testDevelopmentStoreStartsEmptyUntilUserImportsAudio() {
        let store = InitialLibrary.makeDevelopmentStore(renderRootURL: URL(fileURLWithPath: "/tmp/missing-renders", isDirectory: true))

        XCTAssertTrue(store.tracks.isEmpty)
        XCTAssertNil(store.selectedTrackID)
        XCTAssertNil(store.nowPlayingTrackID)
    }
}
