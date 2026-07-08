import XCTest
import AVFoundation
@testable import BackbeatCore

/// Hermetic pins for the custom engine's separation-input decode path (charter
/// Phase 1): channel-layout rules, zero-frame rejection, and — the review-D2 fix —
/// genuinely anti-aliased sample-rate conversion. All fixtures are synthesized
/// float WAVs in a temp directory; nothing external is required.
///
/// The R1 stall guard (mid-stream decoder stall → `truncatedDecode`) is structural:
/// it mirrors the `StemMixdown.decode` / `AudioPCMDecoder` pattern, and a stalling
/// container cannot be synthesized hermetically (AVAudioFile clamps a truncated
/// WAV's declared length to its decodable bytes).
final class SeparationInputLoaderTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeparationInputLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Channel layout (demucs convert_audio_channels semantics)

    func testStereo44kPassthroughIsExact() throws {
        let left = ramp(count: 4_410, seed: 1)
        let right = ramp(count: 4_410, seed: 2)
        let url = try writeFloatWAV(fixture("stereo.wav"), sampleRate: 44_100, channels: [left, right])

        let input = try SeparationInputLoader().load(url: url)

        XCTAssertEqual(input.sampleRate, 44_100)
        XCTAssertEqual(input.channels.count, 2)
        XCTAssertEqual(input.channels[0], left)
        XCTAssertEqual(input.channels[1], right)
    }

    func testMonoIsDuplicatedToBothChannels() throws {
        let mono = ramp(count: 4_410, seed: 3)
        let url = try writeFloatWAV(fixture("mono.wav"), sampleRate: 44_100, channels: [mono])

        let input = try SeparationInputLoader().load(url: url)

        XCTAssertEqual(input.channels.count, 2)
        XCTAssertEqual(input.channels[0], mono)
        XCTAssertEqual(input.channels[1], mono)
    }

    func testMoreThanStereoKeepsFirstTwoChannels() throws {
        let first = ramp(count: 2_048, seed: 4)
        let second = ramp(count: 2_048, seed: 5)
        let third = ramp(count: 2_048, seed: 6)
        let url = try writeFloatWAV(fixture("three.wav"), sampleRate: 44_100, channels: [first, second, third])

        let input = try SeparationInputLoader().load(url: url)

        XCTAssertEqual(input.channels.count, 2)
        XCTAssertEqual(input.channels[0], first)
        XCTAssertEqual(input.channels[1], second)
    }

    // MARK: - Rejection guards

    func testZeroFrameFileThrowsEmptyAudio() throws {
        let url = try writeFloatWAV(fixture("empty.wav"), sampleRate: 44_100, channels: [[]])
        XCTAssertThrowsError(try SeparationInputLoader().load(url: url)) {
            XCTAssertEqual($0 as? SeparationInputError, .emptyAudio(url))
        }
    }

    func testUnreadableFileThrows() {
        let url = directory.appendingPathComponent("missing.wav")
        XCTAssertThrowsError(try SeparationInputLoader().load(url: url)) {
            XCTAssertEqual($0 as? SeparationInputError, .unreadable(url))
        }
    }

    // MARK: - Sample-rate conversion (the review-D2 fix)

    func test48kResampleProducesExpectedLengthAndStereo() throws {
        let frames = 48_000
        let tone = sine(frequency: 440, rate: 48_000, count: frames, amplitude: 0.5)
        let url = try writeFloatWAV(fixture("srclen.wav"), sampleRate: 48_000, channels: [tone, tone])

        let input = try SeparationInputLoader().load(url: url)

        XCTAssertEqual(input.sampleRate, 44_100)
        XCTAssertEqual(input.channels.count, 2)
        XCTAssertEqual(input.channels[0].count, input.channels[1].count)
        // One second of 48 kHz audio is one second of 44.1 kHz audio, give or take
        // converter priming/drain at the edges.
        XCTAssertLessThanOrEqual(abs(input.frameCount - 44_100), 64)
        XCTAssertTrue(input.channels[0].allSatisfy(\.isFinite))
    }

    func test48kResampleIsAntiAliased() throws {
        // 10 kHz (passband) + 23.5 kHz (above the 22.05 kHz target Nyquist). A proper
        // anti-aliased SRC removes the 23.5 kHz tone; a 2-tap linear interpolator —
        // the vendored path this loader replaces — folds it to 44.1k − 23.5k = 20.6 kHz
        // at nearly full amplitude. Require the alias image ≥ 50 dB below the passband
        // tone, and the passband tone preserved within ±1 dB.
        let rate = 48_000.0
        let frames = 48_000
        var signal = sine(frequency: 10_000, rate: rate, count: frames, amplitude: 0.4)
        let ultrasonic = sine(frequency: 23_500, rate: rate, count: frames, amplitude: 0.4)
        for i in 0..<frames { signal[i] += ultrasonic[i] }
        let url = try writeFloatWAV(fixture("alias.wav"), sampleRate: rate, channels: [signal, signal])

        let input = try SeparationInputLoader().load(url: url)

        // Measure mid-signal (skipping converter priming) with a windowed correlation.
        let analysis = Array(input.channels[0][4_096..<(4_096 + 32_768)])
        let passband = toneAmplitude(analysis, frequency: 10_000, rate: 44_100)
        let aliasImage = toneAmplitude(analysis, frequency: 44_100 - 23_500, rate: 44_100)

        XCTAssertEqual(passband, 0.4, accuracy: 0.4 * 0.12, "passband tone must survive within ~1 dB")
        XCTAssertLessThanOrEqual(
            aliasImage, passband * pow(10, -50.0 / 20.0),
            "alias image at 20.6 kHz must sit ≥ 50 dB below the passband tone")
    }

    // MARK: - Fixture + analysis helpers

    private func fixture(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    private func ramp(count: Int, seed: Int) -> [Float] {
        (0..<count).map { Float(($0 * seed) % 997) / 997 - 0.5 }
    }

    private func sine(frequency: Double, rate: Double, count: Int, amplitude: Double) -> [Float] {
        let step = 2.0 * Double.pi * frequency / rate
        return (0..<count).map { Float(amplitude * sin(Double($0) * step)) }
    }

    /// Hann-windowed complex correlation → amplitude estimate of a tone at `frequency`.
    private func toneAmplitude(_ samples: [Float], frequency: Double, rate: Double) -> Double {
        let n = samples.count
        var real = 0.0
        var imaginary = 0.0
        var windowSum = 0.0
        for (i, value) in samples.enumerated() {
            let window = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(n))
            let phase = 2.0 * Double.pi * frequency * Double(i) / rate
            real += Double(value) * window * cos(phase)
            imaginary -= Double(value) * window * sin(phase)
            windowSum += window
        }
        return 2.0 * (real * real + imaginary * imaginary).squareRoot() / windowSum
    }

    /// Writes a 32-bit float WAV holding exactly `channels` (per-channel samples).
    /// `channels == [[]]` writes a valid header with zero frames (mirrors the
    /// `AudioPCMDecoderTests` fixture helper).
    @discardableResult
    private func writeFloatWAV(_ url: URL, sampleRate: Double, channels: [[Float]]) throws -> URL {
        let channelCount = AVAudioChannelCount(channels.count)
        let frames = AVAudioFrameCount(channels.map(\.count).max() ?? 0)
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
        // Use the file's own processing format: `standardFormatWithSampleRate` has no
        // standard layout for >2 channels and returns nil there.
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channelCount) {
            let pointer = buffer.floatChannelData![channel]
            let source = channels[channel]
            for i in 0..<Int(frames) {
                pointer[i] = i < source.count ? source[i] : 0
            }
        }
        try file.write(from: buffer)
        return url
    }
}
