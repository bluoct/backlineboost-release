import XCTest
import AVFoundation
@testable import BackbeatCore

/// Orchestration contract for `TrackLoudnessAnalyzer`: it decodes a source file,
/// runs the native BS.1770-4 `LoudnessAnalyzer`, and folds the measurement into a
/// `TrackLoudnessProfile` via the injected `PlaybackNormalizationSettings`. The
/// measurement tolerance itself (vs ffmpeg ground truth) lives in
/// `LoudnessAnalyzerTests`; this suite pins the profile assembly, settings
/// plumbing, and error taxonomy.
final class TrackLoudnessAnalyzerTests: XCTestCase {
    func testAnalyzeBuildsProfileFromNativeMeasurement() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A loud broadband fixture: ffmpeg loudnorm measures −0.76 LUFS, which drives
        // the suggested gain hard into the maxCut clamp (−1.5 dB).
        let url = try writeNoiseWAV(dir.appendingPathComponent("loud.wav"), amp: 0.8)

        let analyzedAt = Date(timeIntervalSince1970: 1234)
        let profile = try await TrackLoudnessAnalyzer(settings: .default).analyze(sourceURL: url, analyzedAt: analyzedAt)

        XCTAssertEqual(profile.integratedLUFS, -0.76, accuracy: 0.5)
        XCTAssertNotNil(profile.samplePeakDBFS)
        XCTAssertEqual(profile.suggestedGainDB, -1.5, accuracy: 1e-12, "loud track clamps to maxCut")
        XCTAssertEqual(profile.analyzerVersion, TrackLoudnessAnalyzerVersion.current)
        XCTAssertEqual(profile.analyzedAt, analyzedAt)
    }

    func testSuggestedGainReflectsInjectedSettings() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A quiet fixture (−26.78 LUFS) wants a large boost; the settings' maxBoost caps it.
        let url = try writeNoiseWAV(dir.appendingPathComponent("quiet.wav"), amp: 0.04)

        let strict = PlaybackNormalizationSettings(
            isEnabled: true, targetLUFS: -12, maxBoostDB: 3, maxCutDB: -1.5, outputCeilingDBFS: -1)
        let generous = PlaybackNormalizationSettings(
            isEnabled: true, targetLUFS: -12, maxBoostDB: 9, maxCutDB: -1.5, outputCeilingDBFS: -1)

        let strictGain = try await TrackLoudnessAnalyzer(settings: strict).analyze(sourceURL: url).suggestedGainDB
        let generousGain = try await TrackLoudnessAnalyzer(settings: generous).analyze(sourceURL: url).suggestedGainDB

        XCTAssertEqual(strictGain, 3, accuracy: 1e-12)
        XCTAssertEqual(generousGain, 9, accuracy: 1e-12)
    }

    func testProfileGainMatchesSettingsAppliedToTheMeasurement() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeNoiseWAV(dir.appendingPathComponent("mid.wav"), amp: 0.25, channels: 1)

        let settings = PlaybackNormalizationSettings.default
        let profile = try await TrackLoudnessAnalyzer(settings: settings).analyze(sourceURL: url)

        // The profile's gain must be exactly the settings applied to its own measured
        // loudness/peak — no drift between what is stored and what drives playback.
        let expected = settings.suggestedGainDB(
            integratedLUFS: profile.integratedLUFS, samplePeakDBFS: profile.samplePeakDBFS)
        XCTAssertEqual(profile.suggestedGainDB, expected)
    }

    func testThrowsMissingMeasuredLoudnessForSilence() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeFloatWAV(dir.appendingPathComponent("silence.wav"),
                                    sampleRate: 44_100, channels: [[Float](repeating: 0, count: 44_100)])

        await XCTAssertThrowsErrorAsync(try await TrackLoudnessAnalyzer().analyze(sourceURL: url)) { error in
            guard case TrackLoudnessAnalyzer.Error.missingMeasuredLoudness = error else {
                return XCTFail("expected missingMeasuredLoudness, got \(error)")
            }
        }
    }

    func testThrowsDecodeFailedForUnreadableFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bogus = dir.appendingPathComponent("garbage.m4a")
        try Data("not audio".utf8).write(to: bogus)

        await XCTAssertThrowsErrorAsync(try await TrackLoudnessAnalyzer().analyze(sourceURL: bogus)) { error in
            guard case TrackLoudnessAnalyzer.Error.decodeFailed = error else {
                return XCTFail("expected decodeFailed, got \(error)")
            }
        }
    }

    // MARK: - Fixtures

    /// Deterministic LCG noise, bit-identical to the dev-side generator whose output
    /// was measured by ffmpeg (so the hard-coded LUFS numbers apply). Uses the same
    /// seeds as `LoudnessAnalyzerTests` for `amp` 0.8 (loud), 0.04 (quiet), 0.25 (mid).
    private func writeNoiseWAV(_ url: URL, amp: Float, channels: Int = 2) throws -> URL {
        let frames = Int(44_100.0 * 6)
        let seeds: [UInt64]
        switch amp {
        case 0.8: seeds = [0x1111_1111_0000_0001, 0x1111_1111_0000_0002]
        case 0.04: seeds = [0x2222_2222_0000_0001, 0x2222_2222_0000_0002]
        default: seeds = [0x3333_3333_0000_0001, 0x4444_4444_0000_0002]
        }
        var chans = [[Float]]()
        for c in 0..<channels {
            var state = seeds[c]
            var out = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let bits = UInt32(truncatingIfNeeded: state >> 40) & 0x00FF_FFFF
                out[i] = amp * (Float(bits) / Float(1 << 24) * 2 - 1)
            }
            chans.append(out)
        }
        return try writeFloatWAV(url, sampleRate: 44_100, channels: chans)
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
