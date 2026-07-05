import BackbeatCore
import Foundation
import Observation

/// Captures the running app's unified-log stream to `debug.log` while enabled —
/// the same mechanism as `./script/build_and_run.sh --logs`, redirected to a
/// file instead of the terminal. The predicate matches this process by name,
/// so the file carries the full stream (our `DebugLog` categories plus the
/// system-framework lines that are often the real evidence).
///
/// The setting persists in `DebugLog` (UserDefaults); this controller owns the
/// live `/usr/bin/log stream` child process and the file handle it writes to.
@MainActor
@Observable
final class DebugLogController {
    private(set) var isEnabled: Bool
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var fileHandle: FileHandle?

    init() {
        isEnabled = DebugLog.isEnabled()
    }

    var logFileURL: URL { DebugLog.fileURL }
    var logFilePath: String { DebugLog.fileURL.path }
    var logFileExists: Bool { FileManager.default.fileExists(atPath: DebugLog.fileURL.path) }

    /// Called once at launch: resumes capture if the user left it on.
    func startIfEnabled() {
        if isEnabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        DebugLog.setEnabled(enabled)
        if enabled { start() } else { stop() }
    }

    /// Terminate the capture child on app quit so it does not outlive the app.
    func shutdown() {
        stop()
    }

    private func start() {
        guard process == nil else { return }
        reapOrphanedChild()
        let url = DebugLog.fileURL
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Fresh capture per session: truncate and stamp a header.
        let header = "=== Backbeat debug log — capture started (pid \(ProcessInfo.processInfo.processIdentifier)) ===\n"
        fileManager.createFile(atPath: url.path, contents: Data(header.utf8))
        guard let handle = try? FileHandle(forWritingTo: url) else {
            DebugLog.library.error("debug-log: could not open \(url.path, privacy: .public) for writing")
            return
        }
        handle.seekToEndOfFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--info", "--style", "compact",
            "--predicate", "process == \"\(ProcessInfo.processInfo.processName)\""
        ]
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
        } catch {
            DebugLog.library.error("debug-log: log stream failed to start: \(error.localizedDescription, privacy: .public)")
            try? handle.close()
            return
        }
        self.process = process
        self.fileHandle = handle
        DebugLog.setLastCaptureChildPID(process.processIdentifier)
        // Emitted after the stream is live, so it lands in the file itself.
        DebugLog.library.notice("debug-log capture started -> \(url.path, privacy: .public)")
    }

    private func stop() {
        DebugLog.library.notice("debug-log capture stopping")
        process?.terminate()
        process = nil
        try? fileHandle?.close()
        fileHandle = nil
        DebugLog.setLastCaptureChildPID(nil)
    }

    /// A crash/SIGKILL skips `applicationWillTerminate`, so a prior capture
    /// child can outlive the app. On the next start, terminate the recorded
    /// PID if it is still a live `log` process — guarded against PID reuse so
    /// we never signal an unrelated process that inherited the number.
    private func reapOrphanedChild() {
        guard let pid = DebugLog.lastCaptureChildPID() else { return }
        DebugLog.setLastCaptureChildPID(nil)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }

        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/ps")
        check.arguments = ["-p", "\(pid)", "-o", "comm="]
        let pipe = Pipe()
        check.standardOutput = pipe
        check.standardError = FileHandle.nullDevice
        guard (try? check.run()) != nil else { return }
        check.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let command = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard command.hasSuffix("/log") || command == "log" else { return }

        kill(pid, SIGTERM)
        DebugLog.library.notice("debug-log reaped orphaned capture child pid \(pid, privacy: .public)")
    }
}
