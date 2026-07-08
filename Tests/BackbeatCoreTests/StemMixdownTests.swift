import XCTest
import AVFoundation
@testable import BackbeatCore

/// Contract for the native stem mixer that replaces the two LIVE render ffmpeg
/// builders (`drumlessMixCommand`, `drumsStemCommand`).
///
/// Two layers are covered:
///  - the pure DSP (unity sum, look-ahead peak limiter) is tested hermetically
///    on `[Float]` buffers so there is no AAC round-trip in the numeric asserts
///    (G2: no numeric comparison across AAC encoders);
///  - the file entry points are tested end-to-end against synthetic WAV stems,
///    asserting the output is a valid `.m4a`, at the right level, with duration
///    parity, and that the error taxonomy fires on unusable input.
final class StemMixdownTests: XCTestCase {
    // MARK: - (a) pre-limiter null: unity sum, no normalization

    func testUnitySumMatchesSampleWiseSum() {
        let bass: [Float] = [0.10, -0.20, 0.30, -0.40, 0.05]
        let other: [Float] = [0.01, 0.02, -0.03, 0.04, -0.05]
        let vocals: [Float] = [-0.11, 0.22, 0.13, -0.24, 0.15]

        let summed = StemMixdown.unitySum([bass, other, vocals])

        XCTAssertEqual(summed.count, bass.count)
        for i in 0..<bass.count {
            XCTAssertEqual(summed[i], bass[i] + other[i] + vocals[i], accuracy: 1e-6)
        }
    }

    func testUnitySumPadsToLongestBufferWithoutNormalizing() {
        // Mirrors ffmpeg amix duration=longest: shorter inputs pad with silence.
        let a: [Float] = [1.0, 1.0, 1.0]
        let b: [Float] = [0.5]
        let summed = StemMixdown.unitySum([a, b])
        XCTAssertEqual(summed, [1.5, 1.0, 1.0])
    }

    // MARK: - (b) limiter: output ceiling <= 0.98

    func testPeakLimiterHoldsCeilingForOverThresholdSignal() {
        // A signal that swings well past the ceiling must come out at or under it.
        let loud: [Float] = (0..<2_048).map { i -> Float in
            let sign: Float = (i % 2 == 0) ? 2.5 : -3.1
            let ramp: Float = 1.0 + 0.001 * Float(i)
            return sign * ramp
        }
        let limited = StemMixdown.peakLimited([loud], sampleRate: 44_100, ceiling: 0.98)

        let peak = limited[0].map(abs).max() ?? 0
        XCTAssertLessThanOrEqual(peak, 0.98 + 1e-6)
        // It should actually be limiting near the ceiling, not crushing to silence.
        XCTAssertGreaterThan(peak, 0.90)
    }

    func testPeakLimiterKeepsBelowCeilingSignalUnchanged() {
        // A stereo pair entirely under the ceiling passes through at unity gain.
        let left: [Float] = (0..<1_024).map { sin(Float($0) * 0.05) * 0.5 }
        let right: [Float] = (0..<1_024).map { cos(Float($0) * 0.05) * 0.4 }
        let limited = StemMixdown.peakLimited([left, right], sampleRate: 44_100, ceiling: 0.98)

        for i in 0..<left.count {
            XCTAssertEqual(limited[0][i], left[i], accuracy: 1e-6)
            XCTAssertEqual(limited[1][i], right[i], accuracy: 1e-6)
        }
    }

    func testPeakLimiterAppliesOneGainAcrossChannels() {
        // The gain is derived from the max across channels, so both channels get
        // the same reduction (no stereo image shift). A peak in ONE channel must
        // still pull the OTHER channel down by the same factor.
        let hot: [Float] = [2.0, 2.0, 2.0, 2.0]
        let quiet: [Float] = [0.2, 0.2, 0.2, 0.2]
        let limited = StemMixdown.peakLimited([hot, quiet], sampleRate: 44_100, ceiling: 0.98)

        for i in 0..<hot.count {
            let ratio = limited[1][i] / quiet[i]
            let hotGain = limited[0][i] / hot[i]
            XCTAssertEqual(ratio, hotGain, accuracy: 1e-5)
        }
        XCTAssertLessThanOrEqual(limited[0].map(abs).max() ?? 0, 0.98 + 1e-6)
    }

    func testPeakLimiterHoldsCeilingForRaggedChannels() {
        // A channel LONGER than the others must still be limited over its full
        // length — the envelope spans the longest channel, not the first.
        let short: [Float] = [0.0]
        let long: [Float] = [2.0, 2.0, 3.0, -4.0, 5.0]
        let limited = StemMixdown.peakLimited([short, long], sampleRate: 44_100, ceiling: 0.98)

        XCTAssertLessThanOrEqual(limited[0].map(abs).max() ?? 0, 0.98 + 1e-6)
        XCTAssertLessThanOrEqual(limited[1].map(abs).max() ?? 0, 0.98 + 1e-6)
        // And it is actually limiting the loud tail, not zeroing it.
        XCTAssertGreaterThan(limited[1].map(abs).max() ?? 0, 0.90)
    }

    // MARK: - (c) drums passthrough: no gain, no limiter

    func testWriteDrumsIsAPassthroughReEncode() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let amplitude: Float = 0.5
        // Distinct files at distinct levels: reading the wrong stem (e.g. bass at
        // 0.9) would change the decoded peak and fail this assertion.
        let drums = try writeSineWAV(dir.appendingPathComponent("drums.wav"), amplitude: amplitude, frequency: 220)
        let stems = FourStemURLs(
            drums: drums,
            bass: try writeSineWAV(dir.appendingPathComponent("bass.wav"), amplitude: 0.9, frequency: 110),
            other: try writeSineWAV(dir.appendingPathComponent("other.wav"), amplitude: 0.9, frequency: 330),
            vocals: try writeSineWAV(dir.appendingPathComponent("vocals.wav"), amplitude: 0.9, frequency: 550)
        )
        let output = dir.appendingPathComponent("drums.m4a")

        try await StemMixdown().writeDrums(stems: stems, outputURL: output, bitrate: .kbps256)

        let decoded = try decodePeakAndDuration(output)
        // Passthrough: no boost, no limiting, correct stem — level stays close to
        // the 0.5 drums input (a small band absorbs AAC quantization).
        XCTAssertEqual(decoded.peak, amplitude, accuracy: 0.08)
        XCTAssertEqual(decoded.duration, 1.0, accuracy: 0.1)
    }

    func testWriteDrumsAppliesNoLimiter() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A drums stem that peaks WELL above the 0.98 ceiling must pass through
        // unchanged: a limiter regression would clamp it to ~0.98.
        let drums = try writeSineWAV(dir.appendingPathComponent("drums.wav"), amplitude: 1.5, frequency: 220)
        let stems = FourStemURLs(drums: drums, bass: drums, other: drums, vocals: drums)
        let output = dir.appendingPathComponent("drums.m4a")

        try await StemMixdown().writeDrums(stems: stems, outputURL: output, bitrate: .kbps256)

        let decoded = try decodePeakAndDuration(output)
        // ~1.5 through AAC (no limiting). If a limiter were applied it would be <= ~0.98.
        XCTAssertGreaterThan(decoded.peak, 1.1)
    }

    // MARK: - (d) drumless output is a valid .m4a, at level, with duration parity

    func testWriteDrumlessProducesDecodableM4AWithinDurationTolerance() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Odd harmonics of 110 Hz at 0.5 each sum constructively past the ceiling,
        // so a correct sum+limit lands near 0.98.
        let bass = try writeSineWAV(dir.appendingPathComponent("bass.wav"), amplitude: 0.5, frequency: 110)
        let other = try writeSineWAV(dir.appendingPathComponent("other.wav"), amplitude: 0.5, frequency: 330)
        let vocals = try writeSineWAV(dir.appendingPathComponent("vocals.wav"), amplitude: 0.5, frequency: 550)
        let drums = try writeSineWAV(dir.appendingPathComponent("drums.wav"), amplitude: 0.5, frequency: 220)
        let stems = FourStemURLs(drums: drums, bass: bass, other: other, vocals: vocals)
        let output = dir.appendingPathComponent("drumless.m4a")

        try await StemMixdown().writeDrumless(stems: stems, outputURL: output, bitrate: .kbps256)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let decoded = try decodePeakAndDuration(output)
        XCTAssertEqual(decoded.duration, 1.0, accuracy: 0.1)
        // Upper bound: the limiter pulled the summed peak down to <= 0.98.
        XCTAssertLessThanOrEqual(decoded.peak, 0.98 + 0.02)
        // Lower bound: it actually summed the three stems (rejects a single-stem
        // re-encode ~0.5 or a near-silent output).
        XCTAssertGreaterThan(decoded.peak, 0.85)
    }

    func testWriteDrumlessFileExcludesTheDrumsStem() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Low-amplitude backing so the 3-stem sum stays well under the 0.98 ceiling (the
        // limiter never engages), against a HOT drums stem. If drums leaked into the mix
        // the sum would be pushed to ~0.98 by the limiter, so a peak far below the
        // ceiling proves the drums stem was excluded — a check the ~0.98-clamped
        // level-parity tests cannot make.
        let bass = try writeSineWAV(dir.appendingPathComponent("bass.wav"), amplitude: 0.1, frequency: 110)
        let other = try writeSineWAV(dir.appendingPathComponent("other.wav"), amplitude: 0.1, frequency: 330)
        let vocals = try writeSineWAV(dir.appendingPathComponent("vocals.wav"), amplitude: 0.1, frequency: 550)
        let drums = try writeSineWAV(dir.appendingPathComponent("drums.wav"), amplitude: 1.5, frequency: 220)
        let stems = FourStemURLs(drums: drums, bass: bass, other: other, vocals: vocals)
        let output = dir.appendingPathComponent("drumless.m4a")

        try await StemMixdown().writeDrumless(stems: stems, outputURL: output, bitrate: .kbps256)

        let decoded = try decodePeakAndDuration(output)
        XCTAssertLessThan(decoded.peak, 0.6, "drumless must exclude the drums stem (a leak would be limited to ~0.98)")
        XCTAssertGreaterThan(decoded.peak, 0.05, "the backing stems must actually be summed, not silent")
    }

    func testWriteDrumlessBufferExcludesTheDrumsStem() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Buffer-entry twin of the file test above: hot drums, quiet backing; a
        // below-ceiling peak proves the drums stem is not summed into drumless.
        let stems = SeparatedStems(
            sampleRate: 44_100,
            drums: sineChannels(amplitude: 1.5, frequency: 220),
            bass: sineChannels(amplitude: 0.1, frequency: 110),
            other: sineChannels(amplitude: 0.1, frequency: 330),
            vocals: sineChannels(amplitude: 0.1, frequency: 550)
        )
        let output = dir.appendingPathComponent("drumless.m4a")

        try await StemMixdown().writeDrumless(stems: stems, outputURL: output, bitrate: .kbps256)

        let decoded = try decodePeakAndDuration(output)
        XCTAssertLessThan(decoded.peak, 0.6, "drumless must exclude the drums stem (a leak would be limited to ~0.98)")
        XCTAssertGreaterThan(decoded.peak, 0.05, "the backing stems must actually be summed, not silent")
    }

    // MARK: - Error taxonomy on the real implementation

    func testWriteDrumsThrowsMissingStemForUndecodableStem() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A file that exists but is not decodable audio (corrupt/truncated stem).
        let bogus = dir.appendingPathComponent("drums.wav")
        try Data("this is not audio".utf8).write(to: bogus)
        let stems = FourStemURLs(drums: bogus, bass: bogus, other: bogus, vocals: bogus)
        let output = dir.appendingPathComponent("drums.m4a")

        await XCTAssertThrowsErrorAsync(
            try await StemMixdown().writeDrums(stems: stems, outputURL: output, bitrate: .kbps256)
        ) { error in
            guard case BoostedDrumsRenderError.missingStem = error else {
                return XCTFail("expected missingStem, got \(error)")
            }
        }
    }

    func testWriteDrumlessThrowsInvalidOutputForMismatchedStemFormats() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A stem at a different sample rate trips the format guard.
        let bass = try writeSineWAV(dir.appendingPathComponent("bass.wav"), sampleRate: 44_100, frames: 44_100)
        let other = try writeSineWAV(dir.appendingPathComponent("other.wav"), sampleRate: 22_050, frames: 22_050)
        let vocals = try writeSineWAV(dir.appendingPathComponent("vocals.wav"), sampleRate: 44_100, frames: 44_100)
        let stems = FourStemURLs(drums: bass, bass: bass, other: other, vocals: vocals)
        let output = dir.appendingPathComponent("drumless.m4a")

        await XCTAssertThrowsErrorAsync(
            try await StemMixdown().writeDrumless(stems: stems, outputURL: output, bitrate: .kbps256)
        ) { error in
            guard case BoostedDrumsRenderError.invalidOutput = error else {
                return XCTFail("expected invalidOutput, got \(error)")
            }
        }
    }

    // MARK: - Buffer entry points (MLX-era): consume in-memory SeparatedStems

    func testWriteDrumsBufferIsAPassthroughReEncode() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let amplitude: Float = 0.5
        // Distinct levels per stem: reading the wrong stem (e.g. bass at 0.9) would
        // change the decoded peak and fail this assertion.
        let stems = SeparatedStems(
            sampleRate: 44_100,
            drums: sineChannels(amplitude: amplitude, frequency: 220),
            bass: sineChannels(amplitude: 0.9, frequency: 110),
            other: sineChannels(amplitude: 0.9, frequency: 330),
            vocals: sineChannels(amplitude: 0.9, frequency: 550)
        )
        let output = dir.appendingPathComponent("drums.m4a")

        try await StemMixdown().writeDrums(stems: stems, outputURL: output, bitrate: .kbps256)

        let decoded = try decodePeakAndDuration(output)
        XCTAssertEqual(decoded.peak, amplitude, accuracy: 0.08)
        XCTAssertEqual(decoded.duration, 1.0, accuracy: 0.1)
    }

    func testWriteDrumsBufferAppliesNoLimiter() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A drums stem peaking WELL above 0.98 must pass through unchanged.
        let hot = sineChannels(amplitude: 1.5, frequency: 220)
        let stems = SeparatedStems(sampleRate: 44_100, drums: hot, bass: hot, other: hot, vocals: hot)
        let output = dir.appendingPathComponent("drums.m4a")

        try await StemMixdown().writeDrums(stems: stems, outputURL: output, bitrate: .kbps256)

        let decoded = try decodePeakAndDuration(output)
        XCTAssertGreaterThan(decoded.peak, 1.1)
    }

    func testWriteDrumlessBufferProducesDecodableM4AWithinDurationTolerance() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Odd harmonics of 110 Hz at 0.5 each sum constructively past the ceiling,
        // so a correct sum+limit lands near 0.98.
        let stems = SeparatedStems(
            sampleRate: 44_100,
            drums: sineChannels(amplitude: 0.5, frequency: 220),
            bass: sineChannels(amplitude: 0.5, frequency: 110),
            other: sineChannels(amplitude: 0.5, frequency: 330),
            vocals: sineChannels(amplitude: 0.5, frequency: 550)
        )
        let output = dir.appendingPathComponent("drumless.m4a")

        try await StemMixdown().writeDrumless(stems: stems, outputURL: output, bitrate: .kbps256)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let decoded = try decodePeakAndDuration(output)
        XCTAssertEqual(decoded.duration, 1.0, accuracy: 0.1)
        // Upper bound: the limiter pulled the summed peak down to <= 0.98.
        XCTAssertLessThanOrEqual(decoded.peak, 0.98 + 0.02)
        // Lower bound: it actually summed the three stems (rejects a single-stem
        // re-encode ~0.5 or a near-silent output). Drums are deliberately omitted.
        XCTAssertGreaterThan(decoded.peak, 0.85)
    }

    func testWriteDrumsBufferThrowsInvalidOutputForEmptyStem() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // An engine that returned an empty drums buffer must not yield a header-only
        // "valid" output; the encode guard rejects it.
        let stems = SeparatedStems(sampleRate: 44_100, drums: [], bass: [], other: [], vocals: [])
        let output = dir.appendingPathComponent("drums.m4a")

        await XCTAssertThrowsErrorAsync(
            try await StemMixdown().writeDrums(stems: stems, outputURL: output, bitrate: .kbps256)
        ) { error in
            guard case BoostedDrumsRenderError.invalidOutput = error else {
                return XCTFail("expected invalidOutput, got \(error)")
            }
        }
    }

    func testWriteDrumlessBufferThrowsInvalidOutputForMismatchedChannelCounts() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A backing stem with a different channel count trips the summation guard.
        let stems = SeparatedStems(
            sampleRate: 44_100,
            drums: sineChannels(channels: 2),
            bass: sineChannels(channels: 2, amplitude: 0.4),
            other: sineChannels(channels: 1, amplitude: 0.4),
            vocals: sineChannels(channels: 2, amplitude: 0.4)
        )
        let output = dir.appendingPathComponent("drumless.m4a")

        await XCTAssertThrowsErrorAsync(
            try await StemMixdown().writeDrumless(stems: stems, outputURL: output, bitrate: .kbps256)
        ) { error in
            guard case BoostedDrumsRenderError.invalidOutput = error else {
                return XCTFail("expected invalidOutput, got \(error)")
            }
        }
    }

    // MARK: - Fixtures

    /// In-memory non-interleaved sine channels, mirroring what a `StemSeparating`
    /// engine returns (no file round-trip).
    private func sineChannels(
        channels: Int = 2,
        frames: Int = 44_100,
        sampleRate: Double = 44_100,
        amplitude: Float = 0.5,
        frequency: Float = 220
    ) -> [[Float]] {
        let step = 2 * Float.pi * frequency / Float(sampleRate)
        let channel = (0..<frames).map { amplitude * sin(step * Float($0)) }
        return Array(repeating: channel, count: channels)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a 32-bit float WAV (so amplitudes above 1.0 are representable).
    private func writeSineWAV(
        _ url: URL,
        sampleRate: Double = 44_100,
        channels: AVAudioChannelCount = 2,
        frames: AVAudioFrameCount = 44_100,
        amplitude: Float = 0.5,
        frequency: Float = 220
    ) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let step = 2 * Float.pi * frequency / Float(sampleRate)
        for c in 0..<Int(channels) {
            let ptr = buffer.floatChannelData![c]
            for i in 0..<Int(frames) {
                ptr[i] = amplitude * sin(step * Float(i))
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func decodePeakAndDuration(_ url: URL) throws -> (peak: Float, duration: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        let duration = Double(file.length) / format.sampleRate
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return (0, duration)
        }
        try file.read(into: buffer)
        var peak: Float = 0
        if let data = buffer.floatChannelData {
            for c in 0..<Int(format.channelCount) {
                for i in 0..<Int(buffer.frameLength) {
                    peak = max(peak, abs(data[c][i]))
                }
            }
        }
        return (peak, duration)
    }
}

/// Async variant of XCTAssertThrowsError (the stock macro is synchronous only).
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error to be thrown", file: file, line: line)
    } catch {
        handler(error)
    }
}
