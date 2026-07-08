import XCTest
@testable import BackbeatCore

/// Coverage for the SI-SDR parity metric that backs quality gate G1. These are
/// the numeric properties the whole engine gate rests on, so they are asserted
/// hermetically on hand-built signals (no weights, tools, or audio files):
///  - an exact or scaled-exact match is `+∞` (scale invariance is the defining
///    property of SI-SDR — the reason plain SDR is not used);
///  - a reference plus known orthogonal noise yields the exact closed-form dB;
///  - the multi-channel form scores coherently with a single shared scale;
///  - the silent / mismatched-length / mismatched-channel edges are defined, not
///    crashes.
final class StemSeparationMetricsTests: XCTestCase {
    // A ±1 square-ish reference whose samples sum to zero, so a constant vector is
    // orthogonal to it — the lever that lets a test inject a known noise power.
    private func alternating(_ count: Int) -> [Float] {
        (0..<count).map { $0 % 2 == 0 ? Float(1) : Float(-1) }
    }

    func testIdenticalSignalIsInfinite() {
        let reference = alternating(1_024)
        let siSDR = StemSeparationMetrics.signalToDistortionRatioDB(reference: reference, estimate: reference)
        XCTAssertEqual(siSDR, .infinity)
    }

    func testScaledEstimateIsInfinite() {
        // Scale invariance: multiplying the estimate by any positive constant must
        // not change SI-SDR (α absorbs it), so a scaled copy is still a perfect
        // separation. This is the property that makes the metric robust to
        // demucs's per-stem rescale.
        let reference = alternating(1_024)
        for scale: Float in [0.25, 3.0, 17.5] {
            let estimate = reference.map { $0 * scale }
            let siSDR = StemSeparationMetrics.signalToDistortionRatioDB(reference: reference, estimate: estimate)
            XCTAssertEqual(siSDR, .infinity, "scale \(scale) should still be a perfect match")
        }
    }

    func testKnownOrthogonalNoiseGivesClosedFormValue() {
        // reference ⟂ constant vector, so estimate = reference + noise has the
        // reference's own energy as the target and the noise energy as the
        // residual. ||ref||² = N; noise = c everywhere → ||noise||² = c²·N.
        // SI-SDR = 10·log10(1/c²), exactly. c = 0.125 is exactly representable in
        // Float, so the closed form holds to machine precision (0.1 is NOT, which
        // would leave a ~2e-6 artifact and hide real regressions behind slack).
        let count = 4_096
        let c: Float = 0.125
        let reference = alternating(count)
        let estimate = reference.map { $0 + c }
        let siSDR = StemSeparationMetrics.signalToDistortionRatioDB(reference: reference, estimate: estimate)
        XCTAssertEqual(siSDR, 10 * log10(1.0 / Double(c * c)), accuracy: 1e-9)
    }

    func testHalvedNoiseGainsSixDB() {
        // Halving the noise adds exactly 6.0206 dB (20·log10 2), a second
        // independent point on the curve so the test is not satisfiable by a
        // single-constant fudge. c = 0.0625 is again exactly representable.
        let count = 4_096
        let c: Float = 0.0625
        let reference = alternating(count)
        let estimate = reference.map { $0 + c }
        let siSDR = StemSeparationMetrics.signalToDistortionRatioDB(reference: reference, estimate: estimate)
        XCTAssertEqual(siSDR, 10 * log10(1.0 / Double(c * c)), accuracy: 1e-9)
        // Explicitly pin the +6.02 dB gap vs the 0.125 case.
        let coarser = StemSeparationMetrics.signalToDistortionRatioDB(
            reference: reference,
            estimate: reference.map { $0 + 0.125 }
        )
        XCTAssertEqual(siSDR - coarser, 20 * log10(2.0), accuracy: 1e-9)
    }

    func testNonUnitScaleWithNoisePinsAlphaSquared() {
        // The only FINITE-value tests above all resolve to α = 1 (estimate = ref +
        // c), so none pins the least-squares scale power `α²` in targetEnergy. Here
        // estimate = a·ref + c with a = 2 forces α = 2 exactly (a, c both exactly
        // Float-representable): SI-SDR = 10·log10(a²·N / c²·N) = 20·log10(a/c).
        // A missing-square regression (targetEnergy = α·refEnergy) yields 21.07 dB
        // instead of 24.08 dB — a 3 dB miss, far outside the tolerance.
        let count = 4_096
        let a: Float = 2.0
        let c: Float = 0.125
        let reference = alternating(count)
        let estimate = reference.map { a * $0 + c }
        let siSDR = StemSeparationMetrics.signalToDistortionRatioDB(reference: reference, estimate: estimate)
        XCTAssertEqual(siSDR, 20 * log10(Double(a) / Double(c)), accuracy: 1e-9)
    }

    func testMultiChannelIsScoredCoherently() {
        // Two channels, each the same closed-form case, must yield that same value
        // overall — a single shared α across channels, not a per-channel average
        // that would mishandle an infinite channel.
        let count = 4_096
        let c: Float = 0.125
        let reference = alternating(count)
        let estimate = reference.map { $0 + c }
        let siSDR = StemSeparationMetrics.signalToDistortionRatioDB(
            referenceChannels: [reference, reference],
            estimateChannels: [estimate, estimate]
        )
        XCTAssertEqual(siSDR, 10 * log10(1.0 / Double(c * c)), accuracy: 1e-9)
    }

    func testHeterogeneousMultiChannelUsesSharedAlpha() {
        // The symmetric test above (identical channels) cannot tell coherent
        // shared-α scoring apart from per-channel-dB-then-average — both give the
        // same number. Here channel 0 is a PERFECT match and channel 1 = ref + c,
        // so the two disagree: coherent scoring yields a FINITE 10·log10(2/c²) ≈
        // 21.07 dB (targetEnergy = 2N, noiseEnergy = c²N), whereas a per-channel
        // average would be (+∞ + finite)/2 = +∞. This is the case that actually
        // pins the design's "single shared α" guarantee.
        let count = 4_096
        let c: Float = 0.125
        let reference = alternating(count)
        let estimate = reference.map { $0 + c }
        let siSDR = StemSeparationMetrics.signalToDistortionRatioDB(
            referenceChannels: [reference, reference],
            estimateChannels: [reference, estimate]
        )
        XCTAssertEqual(siSDR, 10 * log10(2.0 / Double(c * c)), accuracy: 1e-9)
    }

    func testMismatchedChannelCountsScoreCommonLeadingChannels() {
        // The documented contract: a channel-count mismatch compares only the
        // common leading channels (channelCount = min). A 2-ref vs 1-est call must
        // fold in only channel 0's closed-form value and must NOT crash on the
        // unmatched reference channel (a `max` regression would index out of range).
        let count = 4_096
        let c: Float = 0.125
        let reference = alternating(count)
        let estimate = reference.map { $0 + c }
        let siSDR = StemSeparationMetrics.signalToDistortionRatioDB(
            referenceChannels: [reference, reference],
            estimateChannels: [estimate]
        )
        XCTAssertEqual(siSDR, 10 * log10(1.0 / Double(c * c)), accuracy: 1e-9)
    }

    func testSilentReferenceIsInfiniteOnlyWhenEstimateSilent() {
        let silence = [Float](repeating: 0, count: 512)
        XCTAssertEqual(
            StemSeparationMetrics.signalToDistortionRatioDB(reference: silence, estimate: silence),
            .infinity
        )
        XCTAssertEqual(
            StemSeparationMetrics.signalToDistortionRatioDB(reference: silence, estimate: alternating(512)),
            -.infinity
        )
    }

    func testSilentEstimateAgainstRealReferenceIsNegativeInfinity() {
        let reference = alternating(512)
        let silence = [Float](repeating: 0, count: 512)
        XCTAssertEqual(
            StemSeparationMetrics.signalToDistortionRatioDB(reference: reference, estimate: silence),
            -.infinity
        )
    }

    func testOrthogonalNonSilentEstimateIsNegativeInfinityViaLog10() {
        // reference ⟂ constant vector → α = 0 (targetEnergy = 0) but the estimate
        // carries energy (noiseEnergy > 0), so this must reach the log10(0) = −∞
        // path — NOT the silent-estimate guard (noiseEnergy would be 0) and NOT the
        // silent-reference guard (referenceEnergy would be 0). This is the only test
        // that exercises the metric's main log branch producing −∞.
        let reference = alternating(512)
        let estimate = [Float](repeating: 0.5, count: 512)
        XCTAssertEqual(
            StemSeparationMetrics.signalToDistortionRatioDB(reference: reference, estimate: estimate),
            -.infinity
        )
    }

    func testLengthMismatchTruncatesToShorter() {
        // A few extra boundary samples on either side must not crash and must not
        // change a perfect match (the common prefix is identical).
        let reference = alternating(1_000)
        let estimate = alternating(1_003)
        XCTAssertEqual(
            StemSeparationMetrics.signalToDistortionRatioDB(reference: reference, estimate: estimate),
            .infinity
        )
    }

    func testEmptyInputsAreNegativeInfinityNotCrash() {
        XCTAssertEqual(
            StemSeparationMetrics.signalToDistortionRatioDB(referenceChannels: [], estimateChannels: []),
            -.infinity
        )
        XCTAssertEqual(
            StemSeparationMetrics.signalToDistortionRatioDB(reference: [], estimate: []),
            -.infinity
        )
    }

    func testG1ThresholdsMatchArchitectureGate() {
        // Pin the gate so a silent edit to the thresholds is caught in review.
        let gate = StemParityThresholds.g1
        XCTAssertEqual(gate.drumsMinimumDB, 25)
        XCTAssertEqual(gate.backingStemMinimumDB, 20)
        XCTAssertEqual(gate.calibrationBandMarginDB, 3)
        XCTAssertEqual(gate.minimumDB(for: .drums), 25)
        for stem: SeparatedStems.Stem in [.bass, .other, .vocals] {
            XCTAssertEqual(gate.minimumDB(for: stem), 20)
        }
    }
}
