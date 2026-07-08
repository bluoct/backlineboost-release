import XCTest
import AVFoundation
@testable import BackbeatCore

/// Contract for the native, in-process PCM decoder that replaces the old ffmpeg
/// mono-PCM decode path (downmix to one channel, resample to the caller's rate).
/// It decodes any audio file to mono Float32 at a requested sample rate via
/// `AVAudioFile` + `AVAudioConverter`, with no subprocess. The waveform analyzer
/// is its only consumer.
final class AudioPCMDecoderTests: XCTestCase {
    // MARK: - Happy path: mono at the requested rate

    func testDecodesMonoFixtureToExpectedSampleCount() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 0.5 s of mono audio at exactly the decoder's rate: identity decode.
        let frames = 11_025
        let expected = ramp(count: frames)
        let url = try writeFloatWAV(dir.appendingPathComponent("mono.wav"), sampleRate: 22_050, channels: [expected])

        let decoded = try await AudioPCMDecoder(sampleRate: 22_050).decodeSamples(url: url)

        // count ≈ duration × rate (identity, so exact within a couple frames).
        XCTAssertEqual(Double(decoded.count), Double(frames), accuracy: 4)
    }

    func testDecodedMonoValuesMatchFixtureWithinTolerance() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A known sine written mono at the target rate: an identity conversion
        // (same rate, same channel count) must reproduce the samples faithfully.
        let sampleRate = 22_050.0
        let expected: [Float] = (0..<8_820).map { i in
            0.5 * sin(2 * Float.pi * 220 * Float(i) / Float(sampleRate))
        }
        let url = try writeFloatWAV(dir.appendingPathComponent("sine.wav"), sampleRate: sampleRate, channels: [expected])

        let decoded = try await AudioPCMDecoder(sampleRate: sampleRate).decodeSamples(url: url)

        XCTAssertEqual(decoded.count, expected.count)
        for i in 0..<min(decoded.count, expected.count) {
            XCTAssertEqual(decoded[i], expected[i], accuracy: 1e-4, "sample \(i) diverged")
        }
    }

    // MARK: - Resample + downmix (the ffmpeg `-ar`/`-ac 1` behavior)

    func testResamplesHigherRateSourceToRequestedRate() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1 s of 44.1 kHz mono decoded at 22.05 kHz should yield ~half the frames.
        let expected = ramp(count: 44_100)
        let url = try writeFloatWAV(dir.appendingPathComponent("hi.wav"), sampleRate: 44_100, channels: [expected])

        let decoded = try await AudioPCMDecoder(sampleRate: 22_050).decodeSamples(url: url)

        // ~22 050 frames; SRC filter edges move it by a few frames, allow 2%.
        XCTAssertEqual(Double(decoded.count), 22_050, accuracy: 22_050 * 0.02)
    }

    func testDownmixesStereoSourceToMono() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Distinct L/R content at the target rate: output is a single mono track
        // (~frames samples, not 2×frames interleaved) and is not silent.
        let frames = 11_025
        let left: [Float] = (0..<frames).map { 0.5 * sin(2 * Float.pi * 220 * Float($0) / 22_050) }
        let right: [Float] = (0..<frames).map { 0.5 * sin(2 * Float.pi * 440 * Float($0) / 22_050) }
        let url = try writeFloatWAV(dir.appendingPathComponent("stereo.wav"), sampleRate: 22_050, channels: [left, right])

        let decoded = try await AudioPCMDecoder(sampleRate: 22_050).decodeSamples(url: url)

        XCTAssertEqual(Double(decoded.count), Double(frames), accuracy: 4)
        XCTAssertGreaterThan(decoded.map(abs).max() ?? 0, 0.1)
    }

    // MARK: - Error taxonomy (mirrors the current taxonomy)

    func testThrowsInvalidOutputForNonAudioFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bogus = dir.appendingPathComponent("garbage.wav")
        try Data("this is not audio".utf8).write(to: bogus)

        await XCTAssertThrowsErrorAsync(
            try await AudioPCMDecoder(sampleRate: 22_050).decodeSamples(url: bogus)
        ) { error in
            guard case BoostedDrumsRenderError.invalidOutput = error else {
                return XCTFail("expected invalidOutput, got \(error)")
            }
        }
    }

    func testThrowsInvalidOutputForZeroFrameAudioFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A well-formed but empty audio file (opens fine, zero frames) is unusable.
        let empty = try writeFloatWAV(dir.appendingPathComponent("empty.wav"), sampleRate: 22_050, channels: [[]])

        await XCTAssertThrowsErrorAsync(
            try await AudioPCMDecoder(sampleRate: 22_050).decodeSamples(url: empty)
        ) { error in
            guard case BoostedDrumsRenderError.invalidOutput = error else {
                return XCTFail("expected invalidOutput, got \(error)")
            }
        }
    }

    func testThrowsInvalidOutputForMissingFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let missing = dir.appendingPathComponent("does-not-exist.wav")

        await XCTAssertThrowsErrorAsync(
            try await AudioPCMDecoder(sampleRate: 22_050).decodeSamples(url: missing)
        ) { error in
            guard case BoostedDrumsRenderError.invalidOutput = error else {
                return XCTFail("expected invalidOutput, got \(error)")
            }
        }
    }

    // MARK: - Multi-chunk drain loop (the real production path)

    func testDecodesLongInputAcrossMultipleDrainIterations() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Larger than the 65_536-frame convert chunk, so the drain loop iterates
        // several times and cross-iteration `append(contentsOf:)` accumulation is
        // exercised — the path every real track (> ~3 s at 22_050) takes. Identity
        // rate keeps the decode exact so values past the chunk boundaries can be
        // spot-checked; a `samples = ...`-instead-of-`append` or break-on-first-
        // `.haveData` regression would truncate here.
        let frames = 150_000
        let expected = ramp(count: frames)
        let url = try writeFloatWAV(dir.appendingPathComponent("long.wav"), sampleRate: 22_050, channels: [expected])

        let decoded = try await AudioPCMDecoder(sampleRate: 22_050).decodeSamples(url: url)

        XCTAssertEqual(Double(decoded.count), Double(frames), accuracy: 4)
        for i in [0, 65_536, 100_000, 131_072, frames - 1] where i < decoded.count {
            XCTAssertEqual(decoded[i], expected[i], accuracy: 1e-4, "sample \(i) past a chunk boundary diverged")
        }
    }

    func testResampledSignalPreservesAmplitudeAndFrequencyAcrossChunks() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A 300 Hz sine sits well under the 11_025 Hz post-resample Nyquist, so it
        // survives the anti-alias filter and the 44_100→22_050 decode must reproduce
        // it. 200_000 input frames → ~100_000 output frames (> 65_536), so this also
        // covers the resampler's flush tail arriving in a trailing `.endOfStream`
        // convert call after full `.haveData` buffers. Values are checked via the
        // delay-invariant RMS/peak amplitude and the zero-crossing rate, so no
        // brittle alignment against the converter's group delay is needed.
        let inputRate = 44_100.0
        let outputRate = 22_050.0
        let inputFrames = 200_000
        let freq: Float = 300
        let amplitude: Float = 0.5
        let input: [Float] = (0..<inputFrames).map { amplitude * sin(2 * Float.pi * freq * Float($0) / Float(inputRate)) }
        let url = try writeFloatWAV(dir.appendingPathComponent("sine44k.wav"), sampleRate: inputRate, channels: [input])

        let decoded = try await AudioPCMDecoder(sampleRate: outputRate).decodeSamples(url: url)

        XCTAssertEqual(Double(decoded.count), Double(inputFrames) * outputRate / inputRate, accuracy: Double(inputFrames) * 0.01)
        // Amplitude survives: peak ≈ A and RMS ≈ A/√2 (both hold regardless of the
        // converter's phase/group delay). A broken resample would attenuate or alias.
        let peak = decoded.map(abs).max() ?? 0
        XCTAssertEqual(peak, amplitude, accuracy: 0.05)
        let rms = (decoded.map { $0 * $0 }.reduce(0, +) / Float(decoded.count)).squareRoot()
        XCTAssertEqual(rms, amplitude / Float(2).squareRoot(), accuracy: 0.03)
        // Frequency survives: a 300 Hz sine crosses zero ~2·f·T times.
        let duration = Double(decoded.count) / outputRate
        let expectedCrossings = 2.0 * Double(freq) * duration
        var crossings = 0
        for i in 1..<decoded.count where (decoded[i - 1] < 0) != (decoded[i] < 0) { crossings += 1 }
        XCTAssertEqual(Double(crossings), expectedCrossings, accuracy: expectedCrossings * 0.05)
    }

    // MARK: - Truncated file: decode the available frames, never pad or crash

    func testTruncatedFileDecodesAvailableFramesWithoutPaddingOrCrash() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A valid multi-chunk WAV whose bytes are then cut on disk. AVAudioFile
        // re-derives length from the physical bytes on open, so the decoder returns
        // exactly the decodable frames: NOT zero-padded up to the original length,
        // NOT a crash, and (because AVAudioFile clamps a truncated WAV's length) NOT
        // the mid-stream stall path. This pins the observable truncation contract;
        // the stall→invalidOutput guard defends compressed containers whose metadata
        // length can exceed their bytes, which WAV truncation cannot reproduce.
        let fullFrames = 150_000
        let url = try writeFloatWAV(dir.appendingPathComponent("truncated.wav"), sampleRate: 22_050, channels: [ramp(count: fullFrames)])
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size / 4))
        try handle.close()

        let clampedLength = Int(try AVAudioFile(forReading: url).length)
        XCTAssertGreaterThan(clampedLength, 0)
        XCTAssertLessThan(clampedLength, fullFrames)

        let decoded = try await AudioPCMDecoder(sampleRate: 22_050).decodeSamples(url: url)
        // Exactly the decodable frames at the identity rate — no padding to fullFrames.
        XCTAssertEqual(Double(decoded.count), Double(clampedLength), accuracy: 4)
        XCTAssertLessThan(decoded.count, fullFrames)
    }

    // MARK: - Downmix actually mixes both channels (not a channel drop)

    func testDownmixPreservesContentFromEitherChannel() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Content in only ONE channel must still reach the mono output. Testing both
        // L-silent and R-silent forces a genuine two-channel downmix: a "keep only
        // channel 0" (or only channel 1) regression drops one of the two and fails.
        let frames = 11_025
        let tone: [Float] = (0..<frames).map { 0.8 * sin(2 * Float.pi * 220 * Float($0) / 22_050) }
        let silence = [Float](repeating: 0, count: frames)

        for (channels, label) in [([silence, tone], "left-silent"), ([tone, silence], "right-silent")] {
            let url = try writeFloatWAV(dir.appendingPathComponent("\(label).wav"), sampleRate: 22_050, channels: channels)
            let decoded = try await AudioPCMDecoder(sampleRate: 22_050).decodeSamples(url: url)
            XCTAssertGreaterThan(decoded.map(abs).max() ?? 0, 0.1, "\(label): the non-silent channel must survive the downmix")
        }
    }

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A gentle deterministic ramp in [-0.5, 0.5] — content that survives resampling
    /// without ringing hard, and whose peak is comfortably non-silent.
    private func ramp(count: Int) -> [Float] {
        (0..<count).map { i in Float((Double(i % 441) / 441.0) - 0.5) }
    }

    /// Writes a 32-bit float WAV holding exactly `channels` (per-channel samples).
    /// `channels == [[]]` writes a valid header with zero frames.
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
            for i in 0..<Int(frames) {
                ptr[i] = i < src.count ? src[i] : 0
            }
        }
        try file.write(from: buffer)
        return url
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
