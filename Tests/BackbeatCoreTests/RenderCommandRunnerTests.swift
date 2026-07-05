import XCTest
@testable import BackbeatCore

final class RenderCommandRunnerTests: XCTestCase {
    func testRunOrThrowReturnsSilentlyOnZeroExit() async throws {
        let executor = ScriptedRenderCommandExecutor(results: [
            RenderCommandResult(terminationStatus: 0, output: "ok")
        ])
        let runner = RenderCommandRunner(executor: executor)

        try await runner.runOrThrow(CommandSpec(executablePath: "/usr/local/bin/ffmpeg", arguments: ["-y"]))

        let commands = await executor.recordedCommands()
        XCTAssertEqual(commands.count, 1)
    }

    func testRunOrThrowThrowsCommandFailedOnNonzeroExit() async {
        let executor = ScriptedRenderCommandExecutor(results: [
            RenderCommandResult(terminationStatus: 3, output: "boom")
        ])
        let runner = RenderCommandRunner(executor: executor)

        do {
            try await runner.runOrThrow(CommandSpec(executablePath: "/usr/local/bin/ffmpeg", arguments: ["-y"]))
            XCTFail("Expected commandFailed to be thrown")
        } catch BoostedDrumsRenderError.commandFailed(let command, let status, let output) {
            XCTAssertEqual(command, "ffmpeg")
            XCTAssertEqual(status, 3)
            XCTAssertEqual(output, "boom")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunDemucsWithFallbackRetriesWithoutDeviceAndResetsSeparationDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let separationRootURL = root.appendingPathComponent("separated", isDirectory: true)
        let staleFileURL = separationRootURL.appendingPathComponent("partial.tmp")
        try FileManager.default.createDirectory(at: separationRootURL, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: staleFileURL)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let executor = ScriptedRenderCommandExecutor(results: [
            RenderCommandResult(terminationStatus: 1, output: "MPS backend unavailable"),
            RenderCommandResult(terminationStatus: 0, output: "")
        ])
        let runner = RenderCommandRunner(executor: executor)

        try await runner.runDemucsWithFallback(
            demucsPath: "/usr/local/bin/demucs",
            sourceURL: URL(fileURLWithPath: "/tmp/source.m4a"),
            separationRootURL: separationRootURL,
            profile: .accelerated
        )

        let commands = await executor.recordedCommands()
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands[0].arguments.contains("-d"))
        XCTAssertTrue(commands[0].arguments.contains("mps"))
        XCTAssertFalse(commands[1].arguments.contains("-d"))
        XCTAssertFalse(commands[1].arguments.contains("mps"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: separationRootURL.path))
    }

    func testRunDemucsWithFallbackThrowsImmediatelyForTunedCPUProfile() async {
        let executor = ScriptedRenderCommandExecutor(results: [
            RenderCommandResult(terminationStatus: 1, output: "cpu failed")
        ])
        let runner = RenderCommandRunner(executor: executor)

        do {
            try await runner.runDemucsWithFallback(
                demucsPath: "/usr/local/bin/demucs",
                sourceURL: URL(fileURLWithPath: "/tmp/source.m4a"),
                separationRootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true),
                profile: .tunedCPU
            )
            XCTFail("Expected commandFailed to be thrown")
        } catch BoostedDrumsRenderError.commandFailed(let command, let status, let output) {
            XCTAssertEqual(command, "demucs")
            XCTAssertEqual(status, 1)
            XCTAssertEqual(output, "cpu failed")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let commands = await executor.recordedCommands()
        XCTAssertEqual(commands.count, 1)
    }

    func testRequireNonEmptyFileThrowsInvalidOutputForMissingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        XCTAssertThrowsError(try RenderCommandRunner.requireNonEmptyFile(url)) { error in
            guard case BoostedDrumsRenderError.invalidOutput(let failedURL) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failedURL, url)
        }
    }

    func testRequireNonEmptyFileThrowsInvalidOutputForEmptyFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        XCTAssertThrowsError(try RenderCommandRunner.requireNonEmptyFile(url)) { error in
            guard case BoostedDrumsRenderError.invalidOutput(let failedURL) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failedURL, url)
        }
    }
}

private actor ScriptedRenderCommandExecutor: RenderCommandExecuting {
    private var results: [RenderCommandResult]
    private var commands: [CommandSpec] = []

    init(results: [RenderCommandResult]) {
        self.results = results
    }

    func recordedCommands() -> [CommandSpec] {
        commands
    }

    func run(_ command: CommandSpec) async throws -> RenderCommandResult {
        commands.append(command)
        guard !results.isEmpty else {
            return RenderCommandResult(terminationStatus: 0, output: "")
        }
        return results.removeFirst()
    }
}
