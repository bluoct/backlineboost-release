import XCTest
@testable import BackbeatCore

final class DebugLogTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "DebugLogTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testCaptureIsDisabledByDefault() {
        XCTAssertFalse(DebugLog.isEnabled(defaults: makeDefaults()))
    }

    func testEnableRoundTrips() {
        let defaults = makeDefaults()

        DebugLog.setEnabled(true, defaults: defaults)
        XCTAssertTrue(DebugLog.isEnabled(defaults: defaults))

        DebugLog.setEnabled(false, defaults: defaults)
        XCTAssertFalse(DebugLog.isEnabled(defaults: defaults))
    }

    func testFileURLIsNamedDebugLog() {
        XCTAssertEqual(DebugLog.fileURL.lastPathComponent, "debug.log")
    }

    func testCaptureChildPIDRoundTrips() {
        let defaults = makeDefaults()

        XCTAssertNil(DebugLog.lastCaptureChildPID(defaults: defaults))

        DebugLog.setLastCaptureChildPID(4242, defaults: defaults)
        XCTAssertEqual(DebugLog.lastCaptureChildPID(defaults: defaults), 4242)

        DebugLog.setLastCaptureChildPID(nil, defaults: defaults)
        XCTAssertNil(DebugLog.lastCaptureChildPID(defaults: defaults))
    }
}
