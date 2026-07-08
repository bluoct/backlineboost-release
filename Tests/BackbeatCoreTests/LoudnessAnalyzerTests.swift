import XCTest
import AVFoundation
@testable import BackbeatCore

/// Tolerance contract for the native BS.1770-4 loudness analyzer that replaces the
/// ffmpeg `loudnorm` measurement pass. Each fixture is a deterministic signal
/// generated bit-identically here and (dev-side) fed to `ffmpeg -af loudnorm`; the
/// ffmpeg-measured `input_i` / `input_tp` are hard-coded as ground truth. The suite
/// asserts the native integrated LUFS lands within ±0.5 dB of ffmpeg and that the
/// resulting `suggestedGainDB` is byte-identical wherever the gain clamps to a flat
/// region (the app's real dependency). Fixtures are LCG white noise (broadband,
/// exercises the whole K-weighting curve) plus a tone; ffmpeg ground truth was
/// captured on ffmpeg 8.1.1.
final class LoudnessAnalyzerTests: XCTestCase {
    // MARK: - Ground truth (ffmpeg 8.1.1 `loudnorm=I=-12.0:TP=-1.0:LRA=11.0`)

    private struct GroundTruth {
        let name: String
        let channels: [[Float]]
        let ffmpegI: Double        // input_i (LUFS)
        let ffmpegTP: Double       // input_tp (dBTP)
        let gainIsByteIdentical: Bool // suggestedGainDB clamps to a flat region → exact match
    }

    private func groundTruths() -> [GroundTruth] {
        [
            // Loud broadband → integrated well above −10.5 → gain clamps to maxCut (−1.5).
            GroundTruth(name: "loud_stereo",
                        channels: [Fixture.noise(0.8, 0x1111_1111_0000_0001), Fixture.noise(0.8, 0x1111_1111_0000_0002)],
                        ffmpegI: -0.76, ffmpegTP: 3.69, gainIsByteIdentical: true),
            // Quiet + low peak → gain clamps to maxBoost (+6), peak headroom non-binding.
            GroundTruth(name: "quiet_stereo",
                        channels: [Fixture.noise(0.04, 0x2222_2222_0000_0001), Fixture.noise(0.04, 0x2222_2222_0000_0002)],
                        ffmpegI: -26.78, ffmpegTP: -22.28, gainIsByteIdentical: true),
            // Mid mono → gain is LUFS-limited (tolerance-only), exercises the mono path.
            GroundTruth(name: "mid_mono",
                        channels: [Fixture.noise(0.25, 0x3333_3333_0000_0001)],
                        ffmpegI: -13.88, ffmpegTP: -6.55, gainIsByteIdentical: false),
            // Mid stereo → gain clamps to maxCut (−1.5).
            GroundTruth(name: "mid_stereo",
                        channels: [Fixture.noise(0.3, 0x4444_4444_0000_0001), Fixture.noise(0.3, 0x4444_4444_0000_0002)],
                        ffmpegI: -9.28, ffmpegTP: -4.96, gainIsByteIdentical: true),
            // Loud first half, SILENT second half → exercises the −70 LKFS absolute gate.
            GroundTruth(name: "gated_stereo",
                        channels: [Fixture.twoLevel(0.5, 0.0, 0x5555_0000_0000_0001), Fixture.twoLevel(0.5, 0.0, 0x5555_0000_0000_0002)],
                        ffmpegI: -5.07, ffmpegTP: -0.93, gainIsByteIdentical: true),
            // Loud first half, ~20 dB-quieter second half → exercises the relative gate.
            GroundTruth(name: "twolevel_stereo",
                        channels: [Fixture.twoLevel(0.5, 0.05, 0x6666_0000_0000_0001), Fixture.twoLevel(0.5, 0.05, 0x6666_0000_0000_0002)],
                        ffmpegI: -5.07, ffmpegTP: -0.67, gainIsByteIdentical: true),
            // Pure tone → clean, well-defined true peak (validates the oversampler tightly).
            GroundTruth(name: "sine997",
                        channels: [Fixture.sine997(), Fixture.sine997()],
                        ffmpegI: -6.05, ffmpegTP: -6.02, gainIsByteIdentical: true),
        ]
    }

    // MARK: - Integrated LUFS within ±0.5 dB of ffmpeg, byte-identical suggested gain

    func testIntegratedLoudnessMatchesFfmpegWithinHalfDB() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        for gt in groundTruths() {
            let url = try writeFloatWAV(dir.appendingPathComponent("\(gt.name).wav"), sampleRate: Fixture.sampleRate, channels: gt.channels)
            let measurement = try LoudnessAnalyzer().analyze(url: url)

            XCTAssertEqual(measurement.integratedLUFS, gt.ffmpegI, accuracy: 0.5,
                           "\(gt.name): integrated LUFS \(measurement.integratedLUFS) drifted > 0.5 dB from ffmpeg \(gt.ffmpegI)")
        }
    }

    func testSuggestedGainIsByteIdenticalWhereGainClampsToAFlatRegion() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let settings = PlaybackNormalizationSettings.default
        for gt in groundTruths() {
            let url = try writeFloatWAV(dir.appendingPathComponent("\(gt.name).wav"), sampleRate: Fixture.sampleRate, channels: gt.channels)
            let measurement = try LoudnessAnalyzer().analyze(url: url)

            let nativeGain = settings.suggestedGainDB(
                integratedLUFS: measurement.integratedLUFS, samplePeakDBFS: measurement.truePeakDBFS)
            let ffmpegGain = settings.suggestedGainDB(
                integratedLUFS: gt.ffmpegI, samplePeakDBFS: gt.ffmpegTP)

            if gt.gainIsByteIdentical {
                XCTAssertEqual(nativeGain, ffmpegGain,
                               "\(gt.name): suggestedGainDB \(nativeGain) is not byte-identical to the ffmpeg-derived \(ffmpegGain)")
            } else {
                // LUFS-limited region: gain tracks the ±0.5 dB LUFS tolerance.
                XCTAssertEqual(nativeGain, ffmpegGain, accuracy: 0.5,
                               "\(gt.name): suggestedGainDB \(nativeGain) drifted > 0.5 dB from ffmpeg-derived \(ffmpegGain)")
            }
        }
    }

    // MARK: - True peak

    func testTruePeakIsExactOnAToneAndReasonableOnBroadbandNoise() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A tone has negligible inter-sample overshoot: the oversampler must nail it.
        let sineURL = try writeFloatWAV(dir.appendingPathComponent("sine.wav"),
                                        sampleRate: Fixture.sampleRate, channels: [Fixture.sine997(), Fixture.sine997()])
        let sinePeak = try XCTUnwrap(try LoudnessAnalyzer().analyze(url: sineURL).truePeakDBFS)
        XCTAssertEqual(sinePeak, -6.02, accuracy: 0.2, "tone true peak should match ffmpeg tightly")

        // Full-band noise is the worst case (a 4× oversampler reads a little low vs
        // ffmpeg's 192 kHz resample); confirm it is still in the right ballpark.
        let noiseURL = try writeFloatWAV(dir.appendingPathComponent("noise.wav"),
                                         sampleRate: Fixture.sampleRate,
                                         channels: [Fixture.noise(0.25, 0x3333_3333_0000_0001)])
        let noisePeak = try XCTUnwrap(try LoudnessAnalyzer().analyze(url: noiseURL).truePeakDBFS)
        XCTAssertEqual(noisePeak, -6.55, accuracy: 1.5, "broadband true peak should stay within a bounded artifact of ffmpeg")
    }

    // MARK: - K-weighting coefficients (libebur128, generated per sample rate)

    func testKWeightingCoefficientsMatchLibebur128() {
        // 48 kHz reproduces the BS.1770-4 published table; 44.1 kHz is the app's real
        // rate. Both from libebur128's parametric constants, to full double precision.
        let shelf48 = LoudnessAnalyzer.kWeightingShelf(sampleRate: 48_000)
        XCTAssertEqual(shelf48.b0, 1.5351248595869702, accuracy: 1e-12)
        XCTAssertEqual(shelf48.b1, -2.6916961894063807, accuracy: 1e-12)
        XCTAssertEqual(shelf48.b2, 1.1983928108528501, accuracy: 1e-12)
        XCTAssertEqual(shelf48.a1, -1.6906592931824103, accuracy: 1e-12)
        XCTAssertEqual(shelf48.a2, 0.73248077421585012, accuracy: 1e-12)
        let hp48 = LoudnessAnalyzer.kWeightingHighpass(sampleRate: 48_000)
        XCTAssertEqual(hp48.b0, 1, accuracy: 1e-12)
        XCTAssertEqual(hp48.b1, -2, accuracy: 1e-12)
        XCTAssertEqual(hp48.b2, 1, accuracy: 1e-12)
        XCTAssertEqual(hp48.a1, -1.9900474548339797, accuracy: 1e-12)
        XCTAssertEqual(hp48.a2, 0.99007225036620994, accuracy: 1e-12)

        let shelf44 = LoudnessAnalyzer.kWeightingShelf(sampleRate: 44_100)
        XCTAssertEqual(shelf44.b0, 1.5308412300503478, accuracy: 1e-12)
        XCTAssertEqual(shelf44.b1, -2.6509799951547297, accuracy: 1e-12)
        XCTAssertEqual(shelf44.b2, 1.1690790799215871, accuracy: 1e-12)
        XCTAssertEqual(shelf44.a1, -1.6636551132560204, accuracy: 1e-12)
        XCTAssertEqual(shelf44.a2, 0.7125954280732254, accuracy: 1e-12)
        let hp44 = LoudnessAnalyzer.kWeightingHighpass(sampleRate: 44_100)
        XCTAssertEqual(hp44.a1, -1.9891696736297959, accuracy: 1e-12)
        XCTAssertEqual(hp44.a2, 0.98919903578703927, accuracy: 1e-12)
    }

    // MARK: - Block windowing

    func testBlockCountDropsTheIncompleteTrailingBlock() {
        // 20 s @ 44.1 kHz: samples_in_100ms = 4410, block = 17640; 200 whole 100 ms
        // segments → 197 blocks (first at 400 ms, then every 100 ms).
        XCTAssertEqual(LoudnessAnalyzer.blockCount(frameCount: 20 * 44_100, sampleRate: 44_100), 197)
        // Shorter than one 400 ms block → no blocks at all.
        XCTAssertEqual(LoudnessAnalyzer.blockCount(frameCount: 17_639, sampleRate: 44_100), 0)
        XCTAssertEqual(LoudnessAnalyzer.blockCount(frameCount: 17_640, sampleRate: 44_100), 1)
    }

    // MARK: - Silence

    func testSilenceMeasuresAsNegativeInfinityWithNoPeak() {
        let silence = [[Float]](repeating: [Float](repeating: 0, count: 44_100), count: 2)
        let measurement = LoudnessAnalyzer().measure(channels: silence, sampleRate: 44_100)
        XCTAssertFalse(measurement.integratedLUFS.isFinite)
        XCTAssertLessThan(measurement.integratedLUFS, 0)
        XCTAssertNil(measurement.truePeakDBFS)
    }

    // MARK: - Decode round-trip: measuring the file equals measuring the buffers

    func testFileMeasurementEqualsBufferMeasurement() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let channels = [Fixture.noise(0.3, 0x4444_4444_0000_0001), Fixture.noise(0.3, 0x4444_4444_0000_0002)]
        let url = try writeFloatWAV(dir.appendingPathComponent("rt.wav"), sampleRate: Fixture.sampleRate, channels: channels)

        let fromFile = try LoudnessAnalyzer().analyze(url: url)
        let fromBuffers = LoudnessAnalyzer().measure(channels: channels, sampleRate: Fixture.sampleRate)
        // 32-bit float WAV round-trips exactly, so the two paths must agree.
        XCTAssertEqual(fromFile.integratedLUFS, fromBuffers.integratedLUFS, accuracy: 1e-9)
        XCTAssertEqual(fromFile.truePeakDBFS ?? 0, fromBuffers.truePeakDBFS ?? 0, accuracy: 1e-9)
    }

    // MARK: - Decode errors

    func testAnalyzeThrowsUnreadableForNonAudioFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bogus = dir.appendingPathComponent("garbage.wav")
        try Data("not audio".utf8).write(to: bogus)

        XCTAssertThrowsError(try LoudnessAnalyzer().analyze(url: bogus)) { error in
            guard case LoudnessAnalyzer.Failure.unreadable = error else {
                return XCTFail("expected unreadable, got \(error)")
            }
        }
    }

    // MARK: - Fixtures (bit-identical to the dev-side generator fed to ffmpeg)

    private enum Fixture {
        static let sampleRate = 44_100.0
        static let frames = Int(44_100.0 * 6) // 6 s

        /// Deterministic LCG white noise: pure integer state, bit-reproducible.
        struct LCG {
            var state: UInt64
            mutating func nextUnit() -> Float {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let bits = UInt32(truncatingIfNeeded: state >> 40) & 0x00FF_FFFF
                return Float(bits) / Float(1 << 24) * 2 - 1
            }
        }

        static func noise(_ amp: Float, _ seed: UInt64) -> [Float] {
            noise(count: frames, amp: amp, seed: seed)
        }

        static func noise(count: Int, amp: Float, seed: UInt64) -> [Float] {
            var lcg = LCG(state: seed)
            var out = [Float](repeating: 0, count: count)
            for i in 0..<count { out[i] = amp * lcg.nextUnit() }
            return out
        }

        static func twoLevel(_ ampA: Float, _ ampB: Float, _ seed: UInt64) -> [Float] {
            let half = frames / 2
            return noise(count: half, amp: ampA, seed: seed)
                + noise(count: frames - half, amp: ampB, seed: seed ^ 0xDEAD_BEEF)
        }

        static func sine997() -> [Float] {
            (0..<frames).map { 0.5 * sin(2 * Float.pi * 997 * Float($0) / Float(sampleRate)) }
        }
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writeFloatWAV(_ url: URL, sampleRate: Double, channels: [[Float]]) throws -> URL {
        let channelCount = AVAudioChannelCount(channels.count)
        let frames = AVAudioFrameCount(channels.map(\.count).max() ?? 0)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard frames > 0 else { return url }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(channelCount) {
            let ptr = buffer.floatChannelData![c]
            let src = channels[c]
            for i in 0..<Int(frames) { ptr[i] = i < src.count ? src[i] : 0 }
        }
        try file.write(from: buffer)
        return url
    }
}
