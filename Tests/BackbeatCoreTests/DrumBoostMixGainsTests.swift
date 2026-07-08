import XCTest
import Foundation
@testable import BackbeatCore

/// Direct coverage for the compensated drum-boost gain model.
///
/// `DrumBoostMixGains` survives the native-engine migration because the LIVE
/// two-track playback mixer consumes it, but its only previous pins were the
/// dead ffmpeg `mixCommand` tests. This suite pins the exact linear gains and
/// the delta invariant on their own so that coverage does not disappear when the
/// `mixCommand` builder and its tests are deleted (amendment A5).
final class DrumBoostMixGainsTests: XCTestCase {
    // For boostDB >= 0 the drum-vs-backing dB delta equals the requested boost,
    // because the master compensation cancels in the difference:
    // drumDB - backingDB == 20*log10(relativeDrumGain) == boostDB.
    func testDeltaEqualsBoostForNonNegativeBoost() {
        for boost in [0.0, 4.5, 9.0] {
            let gains = DrumBoostMixGains(boostDB: boost)
            XCTAssertEqual(gains.drumGainDB - gains.backingGainDB, boost, accuracy: 1e-9)
        }
    }

    // For boostDB < 0 the model clamps at max(0, boostDB): relativeDrumGain == 1,
    // compensation == 1, so both gains collapse to unity (0 dB) and the delta is 0.
    func testDeltaCollapsesToUnityForNegativeBoost() {
        for boost in [-6.0, -0.1] {
            let gains = DrumBoostMixGains(boostDB: boost)
            XCTAssertEqual(gains.drumGainDB, 0, accuracy: 1e-12)
            XCTAssertEqual(gains.backingGainDB, 0, accuracy: 1e-12)
            XCTAssertEqual(gains.drumGainDB - gains.backingGainDB, 0, accuracy: 1e-12)
            XCTAssertEqual(gains.drumLinearGain, 1, accuracy: 1e-6)
            XCTAssertEqual(gains.backingLinearGain, 1, accuracy: 1e-6)
        }
    }

    // The linear gains match the compensation model exactly:
    // relativeDrumGain = pow(10, max(0,boostDB)/20)
    // compensation     = 1 / sqrt((relativeDrumGain^2 + 3) / 4)
    // drumLinear       = relativeDrumGain * compensation
    // backingLinear    = compensation
    func testLinearGainsMatchCompensationModel() {
        for boost in [-6.0, -0.1, 0.0, 4.5, 9.0] {
            let gains = DrumBoostMixGains(boostDB: boost)
            let relative = pow(10, max(0, boost) / 20)
            let compensation = 1 / (((relative * relative) + 3) / 4).squareRoot()
            XCTAssertEqual(Double(gains.drumLinearGain), relative * compensation, accuracy: 1e-6)
            XCTAssertEqual(Double(gains.backingLinearGain), compensation, accuracy: 1e-6)
        }
    }
}
