import XCTest
@testable import BackbeatCore

final class BackbeatFileLocationsTests: XCTestCase {
    func testWritableLibraryLocationsUseApplicationSupportBackbeatFolder() throws {
        let applicationSupportURL = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let expectedRoot = applicationSupportURL.appendingPathComponent("Backbeat", isDirectory: true)

        XCTAssertEqual(BackbeatFileLocations.applicationSupportDirectory, expectedRoot)
        XCTAssertEqual(
            BackbeatFileLocations.managedSourceDirectory,
            expectedRoot
                .appendingPathComponent("AppAudioLibrary", isDirectory: true)
                .appendingPathComponent("sources", isDirectory: true)
        )
        XCTAssertEqual(
            BackbeatFileLocations.librarySnapshotURL,
            expectedRoot
                .appendingPathComponent("AppAudioLibrary", isDirectory: true)
                .appendingPathComponent("library.json")
        )
        XCTAssertEqual(
            BackbeatFileLocations.renderRootDirectory,
            expectedRoot.appendingPathComponent("renders", isDirectory: true)
        )
        XCTAssertEqual(
            BackbeatFileLocations.artworkDirectory,
            expectedRoot.appendingPathComponent("artwork", isDirectory: true)
        )
    }

    func testTemporaryLocationUsesUserCachesBackbeatFolder() throws {
        let cachesURL = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        )
        let expectedRoot = cachesURL
            .appendingPathComponent("Backbeat", isDirectory: true)
            .appendingPathComponent("Temporary", isDirectory: true)

        XCTAssertEqual(BackbeatFileLocations.temporaryDirectory, expectedRoot)
    }

    func testWritableLocationsDoNotPointAtSourceCheckout() {
        let projectRoot = BackbeatFileLocations.projectRoot.standardizedFileURL.path
        let writablePaths = [
            BackbeatFileLocations.managedSourceDirectory,
            BackbeatFileLocations.librarySnapshotURL,
            BackbeatFileLocations.renderRootDirectory,
            BackbeatFileLocations.artworkDirectory,
            BackbeatFileLocations.temporaryDirectory
        ].map { $0.standardizedFileURL.path }

        for path in writablePaths {
            XCTAssertFalse(path.hasPrefix(projectRoot), "\(path) should not live under source checkout \(projectRoot)")
        }
    }
}
