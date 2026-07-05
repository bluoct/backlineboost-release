import XCTest
@testable import BackbeatCore

final class WaveformEnvelopeTests: XCTestCase {
    func testBucketsInterleavedSamplesIntoNormalizedPeaks() {
        let envelope = WaveformEnvelope.make(
            samples: [
                0.0, 0.25,
                -0.5, 0.0,
                0.75, -1.0,
                0.2, 0.1
            ],
            sampleRate: 4,
            channelCount: 2,
            binCount: 2
        )

        XCTAssertEqual(envelope.duration, 1)
        XCTAssertEqual(envelope.bins.count, 2)
        XCTAssertEqual(envelope.bins[0].amplitude, 0.5, accuracy: 0.0001)
        XCTAssertEqual(envelope.bins[0].startTime, 0, accuracy: 0.0001)
        XCTAssertEqual(envelope.bins[0].endTime, 0.5, accuracy: 0.0001)
        XCTAssertEqual(envelope.bins[1].amplitude, 1, accuracy: 0.0001)
        XCTAssertEqual(envelope.bins[1].startTime, 0.5, accuracy: 0.0001)
        XCTAssertEqual(envelope.bins[1].endTime, 1, accuracy: 0.0001)
    }

    func testEmptyInputKeepsDeterministicZeroBins() {
        let envelope = WaveformEnvelope.make(samples: [], sampleRate: 44_100, channelCount: 2, binCount: 3)

        XCTAssertEqual(envelope.duration, 0)
        XCTAssertEqual(envelope.bins.count, 3)
        XCTAssertEqual(envelope.bins.map(\.amplitude), [0, 0, 0])
    }

    func testInvalidBinCountReturnsEmptyEnvelope() {
        let envelope = WaveformEnvelope.make(samples: [1, -1], sampleRate: 44_100, channelCount: 1, binCount: 0)

        XCTAssertEqual(envelope.duration, 0)
        XCTAssertTrue(envelope.bins.isEmpty)
    }

    func testNonInterleavedSamplesUseLoudestChannelPerFrame() {
        let envelope = WaveformEnvelope.make(
            channelSamples: [
                [0.1, 0.2, 0.3, 0.4],
                [0.0, -0.8, 0.1, -0.2]
            ],
            sampleRate: 4,
            binCount: 2
        )

        XCTAssertEqual(envelope.bins.map(\.amplitude), [1, 0.5])
    }

    func testInterleavedNonFiniteSamplesAreSkippedInPeakDetection() {
        // Historically each non-finite sample was skipped individually; the
        // vDSP fast path must fall back to that behavior for NaN and infinity.
        let envelope = WaveformEnvelope.make(
            samples: [0.5, .nan, 1.0, .infinity],
            sampleRate: 4,
            channelCount: 1,
            binCount: 2
        )

        XCTAssertEqual(envelope.bins.count, 2)
        XCTAssertEqual(envelope.bins[0].amplitude, 0.5, accuracy: 0.0001)
        XCTAssertEqual(envelope.bins[1].amplitude, 1, accuracy: 0.0001)
    }

    func testNonInterleavedNonFiniteSamplesAreSkippedInPeakDetection() {
        let envelope = WaveformEnvelope.make(
            channelSamples: [
                [0.5, .nan],
                [0.25, 0.75]
            ],
            sampleRate: 2,
            binCount: 2
        )

        XCTAssertEqual(envelope.bins.count, 2)
        XCTAssertEqual(envelope.bins[0].amplitude, 0.5 / 0.75, accuracy: 0.0001)
        XCTAssertEqual(envelope.bins[1].amplitude, 1, accuracy: 0.0001)
    }

    func testBucketPartitionMatchesHistoricalMappingForUnevenBinCounts() {
        // The per-bin ranges must reproduce the historical per-frame mapping
        // min(binCount - 1, Int(Double(f) * binCount / frameCount)) exactly,
        // including frame counts that are not multiples of the bin count and
        // bin counts larger than the frame count.
        for (frameCount, binCount) in [(7, 3), (10, 4), (5, 8), (240, 7)] {
            let samples = (0..<frameCount).map { Float($0 + 1) / Float(frameCount) }

            var expectedPeaks = [Double](repeating: 0, count: binCount)
            for frame in 0..<frameCount {
                let bin = min(binCount - 1, Int(Double(frame) * Double(binCount) / Double(frameCount)))
                expectedPeaks[bin] = max(expectedPeaks[bin], Double(abs(samples[frame])))
            }
            let maximum = expectedPeaks.max() ?? 0
            let expected = maximum > 0 ? expectedPeaks.map { min(1, max(0, $0 / maximum)) } : expectedPeaks

            let envelope = WaveformEnvelope.make(
                samples: samples,
                sampleRate: Double(frameCount),
                channelCount: 1,
                binCount: binCount
            )

            XCTAssertEqual(envelope.bins.count, binCount, "frameCount \(frameCount), binCount \(binCount)")
            for (index, amplitude) in envelope.bins.map(\.amplitude).enumerated() {
                XCTAssertEqual(
                    amplitude,
                    expected[index],
                    accuracy: 0.000001,
                    "bin \(index) for frameCount \(frameCount), binCount \(binCount)"
                )
            }
        }
    }
}
