import XCTest
@testable import BackbeatCore

final class ProcessRenderCommandExecutorTests: XCTestCase {
    func testRunDrainsOutputLargerThanPipeBuffer() async throws {
        let executor = ProcessRenderCommandExecutor()

        let result = try await executor.run(
            CommandSpec(executablePath: "/bin/sh", arguments: ["-c", "yes | head -n 100000"])
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertGreaterThan(result.output.utf8.count, 65_536)
    }

    func testRunCombinesStandardOutputAndStandardError() async throws {
        let executor = ProcessRenderCommandExecutor()

        let result = try await executor.run(
            CommandSpec(executablePath: "/bin/sh", arguments: ["-c", "echo out; echo err 1>&2; exit 3"])
        )

        XCTAssertEqual(result.terminationStatus, 3)
        XCTAssertTrue(result.output.contains("out"))
        XCTAssertTrue(result.output.contains("err"))
    }

    func testRunTerminatesProcessWhenTaskIsCancelled() async throws {
        let executor = ProcessRenderCommandExecutor()
        let started = Date()

        let task = Task {
            try await executor.run(CommandSpec(executablePath: "/bin/sleep", arguments: ["30"]))
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.result

        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        switch result {
        case .success(let commandResult):
            XCTFail("expected cancellation, got termination status \(commandResult.terminationStatus)")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
    }

    func testCancellationDoesNotHangWhenChildLeavesOrphanHoldingPipe() async throws {
        let executor = ProcessRenderCommandExecutor()
        let started = Date()

        // The backgrounded sleep inherits the stdout write end, so EOF never
        // arrives after the shell exits; cancellation must still unblock.
        let task = Task {
            try await executor.run(CommandSpec(executablePath: "/bin/sh", arguments: ["-c", "sleep 30 & wait"]))
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = await task.result

        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testRunInjectsAugmentedPATHIntoChildEnvironment() async throws {
        let executor = ProcessRenderCommandExecutor()

        let result = try await executor.run(
            CommandSpec(executablePath: "/bin/sh", arguments: ["-c", "printf %s \"$PATH\""])
        )

        XCTAssertEqual(result.terminationStatus, 0)
        let entries = result.output.components(separatedBy: ":")
        // The executable's own directory leads, and the standard tool
        // directories demucs needs for its internal ffmpeg lookup follow.
        XCTAssertEqual(entries.first, "/bin")
        XCTAssertTrue(entries.contains("/opt/homebrew/bin"))
        XCTAssertTrue(entries.contains(RenderPreflight.managedToolsBinDirectory.path))
    }

    func testRunThrowsWhenExecutableIsMissing() async {
        let executor = ProcessRenderCommandExecutor()

        do {
            _ = try await executor.run(
                CommandSpec(executablePath: "/nonexistent/backbeat-test-tool", arguments: [])
            )
            XCTFail("expected launch failure")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }
}
