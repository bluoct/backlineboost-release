import XCTest
@testable import BackbeatCore

final class MonoPCMDecoderTests: XCTestCase {
    func testDecodeSamplesReturnsFloatsWrittenByDecodeCommand() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        let samples: [Float] = [0.25, -0.5, 1.0, 0]
        let decoder = MonoPCMDecoder(
            sampleRate: 22_050,
            temporaryRootURL: temporaryRoot,
            commandResolver: { command in "/usr/local/bin/\(command)" },
            commandExecutor: PCMWritingRenderCommandExecutor(behavior: .writeSamples(samples))
        )

        let decoded = try await decoder.decodeSamples(url: URL(fileURLWithPath: "/tmp/song.m4a"))

        XCTAssertEqual(decoded, samples)
    }

    func testDecodeSamplesThrowsCommandFailedOnNonzeroExit() async {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        let decoder = MonoPCMDecoder(
            sampleRate: 22_050,
            temporaryRootURL: temporaryRoot,
            commandResolver: { command in "/usr/local/bin/\(command)" },
            commandExecutor: PCMWritingRenderCommandExecutor(behavior: .fail(status: 1, output: "decode failed"))
        )

        do {
            _ = try await decoder.decodeSamples(url: URL(fileURLWithPath: "/tmp/song.m4a"))
            XCTFail("Expected commandFailed to be thrown")
        } catch BoostedDrumsRenderError.commandFailed(let command, let status, let output) {
            XCTAssertEqual(command, "ffmpeg")
            XCTAssertEqual(status, 1)
            XCTAssertEqual(output, "decode failed")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDecodeSamplesThrowsInvalidOutputForEmptyPCMFile() async {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        let decoder = MonoPCMDecoder(
            sampleRate: 22_050,
            temporaryRootURL: temporaryRoot,
            commandResolver: { command in "/usr/local/bin/\(command)" },
            commandExecutor: PCMWritingRenderCommandExecutor(behavior: .writeEmptyFile)
        )

        do {
            _ = try await decoder.decodeSamples(url: URL(fileURLWithPath: "/tmp/song.m4a"))
            XCTFail("Expected invalidOutput to be thrown")
        } catch BoostedDrumsRenderError.invalidOutput {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private struct PCMWritingRenderCommandExecutor: RenderCommandExecuting {
    enum Behavior: Sendable {
        case writeSamples([Float])
        case writeEmptyFile
        case fail(status: Int32, output: String)
    }

    let behavior: Behavior

    func run(_ command: CommandSpec) async throws -> RenderCommandResult {
        guard let outputPath = command.arguments.last else {
            return RenderCommandResult(terminationStatus: 1, output: "missing output path")
        }
        switch behavior {
        case .writeSamples(let samples):
            let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            try data.write(to: URL(fileURLWithPath: outputPath))
            return RenderCommandResult(terminationStatus: 0, output: "")
        case .writeEmptyFile:
            try Data().write(to: URL(fileURLWithPath: outputPath))
            return RenderCommandResult(terminationStatus: 0, output: "")
        case .fail(let status, let output):
            return RenderCommandResult(terminationStatus: status, output: output)
        }
    }
}
