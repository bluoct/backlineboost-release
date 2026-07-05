import XCTest
@testable import BackbeatCore

final class FormattingTests: XCTestCase {
    func testFormatsSongDurationAsMinutesAndSeconds() {
        XCTAssertEqual(BackbeatFormat.duration(271.666), "4:32")
        XCTAssertEqual(BackbeatFormat.duration(0), "0:00")
        XCTAssertEqual(BackbeatFormat.duration(65.2), "1:05")
    }

    func testFormatsBoostWithSignedOneDecimalDb() {
        XCTAssertEqual(BackbeatFormat.boost(4), "+4.0 dB")
        XCTAssertEqual(BackbeatFormat.boost(6.25), "+6.3 dB")
        XCTAssertEqual(BackbeatFormat.boost(0), "0.0 dB")
    }
}
