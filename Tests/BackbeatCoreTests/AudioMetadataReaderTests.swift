import XCTest
import AVFoundation
@testable import BackbeatCore

final class AudioMetadataReaderTests: XCTestCase {
    func testPreciseDurationMatchesKnownFixtureDuration() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleRate = 44_100.0
        let durationSeconds = 2.0
        let frames = AVAudioFrameCount(sampleRate * durationSeconds)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let url = dir.appendingPathComponent("fixture.wav")
        // Scope the writer: AVAudioFile finalizes the WAV header on
        // deallocation, and the probe must read a finished file.
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            let ptr = buffer.floatChannelData![0]
            for i in 0..<Int(frames) {
                ptr[i] = Float((Double(i % 441) / 441.0) - 0.5)
            }
            try file.write(from: buffer)
        }

        let duration = try await AudioMetadataReader().preciseDuration(url: url)

        XCTAssertEqual(duration, durationSeconds, accuracy: 0.001)
    }

    func testReadsMetadataFromFullSongM4A() async throws {
        guard let path = ProcessInfo.processInfo.environment["BACKBEAT_TEST_AUDIO"] else {
            throw XCTSkip("Set BACKBEAT_TEST_AUDIO to a local audio file to run this test.")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("BACKBEAT_TEST_AUDIO does not point to an existing file.")
        }

        let metadata = try await AudioMetadataReader().read(url: url)

        XCTAssertFalse(metadata.fileName.isEmpty)
        XCTAssertGreaterThan(metadata.duration, 0)
        XCTAssertGreaterThan(metadata.sampleRate, 0)
        XCTAssertGreaterThanOrEqual(metadata.channelCount, 1)
    }

    func testReaderRequestsPreciseDurationForVBRAccuracy() throws {
        // Hermetic guard for F1(b): without the precise-timing key, a VBR MP3
        // persists AVFoundation's fast estimate, which can drift far enough to
        // block Drum Boost. (A behavioral assertion would need a known-VBR
        // fixture with a known true duration; this pins the request itself.)
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/BackbeatCore/Services/AudioMetadataReader.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("AVURLAssetPreferPreciseDurationAndTimingKey: true"),
            "Metadata reads must request precise duration so new imports persist accurate durations (F1)."
        )
    }
}
