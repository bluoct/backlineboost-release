import Foundation
import OSLog

/// Shared logging vocabulary for Backbeat.
///
/// All app logging funnels through the categorized `Logger`s here so a capture
/// (`Settings ▸ Diagnostics ▸ Write debug log`, or `./script/build_and_run.sh
/// --logs`) filters cleanly by category. The capture itself is process-wide —
/// it includes system-framework lines (e.g. `com.apple.CFPasteboard`) that are
/// often the crucial evidence, as the Apple Music drag diagnosis showed.
///
/// Message convention — write events as a dotted name followed by `key=value`
/// fields so a log is greppable and machine-parsable:
///
///     DebugLog.importing.notice("import.start file=\(name, privacy: .public) bytes=\(count)")
///     DebugLog.importing.notice("import.artwork present=\(hasArt) bytes=\(artBytes)")
///     DebugLog.importing.notice("import.done trackID=\(id, privacy: .public)")
///
/// Then `grep 'import\.' debug.log` shows the whole import lifecycle, and
/// `grep 'import.artwork' debug.log` isolates one field. Keep the event name in
/// the `area.event` shape; put variable data only in `key=value` pairs.
public enum DebugLog {
    public static let subsystem = "com.bluoct.backlineboost"

    // One logger per subsystem area. Add a category here rather than spinning
    // up ad-hoc `Logger`s at call sites, so `debug.log` stays filterable.
    public static let importing = Logger(subsystem: subsystem, category: "import")
    public static let render = Logger(subsystem: subsystem, category: "render")
    public static let drop = Logger(subsystem: subsystem, category: "MusicDrop")
    public static let playback = Logger(subsystem: subsystem, category: "playback")
    public static let library = Logger(subsystem: subsystem, category: "library")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")

    // MARK: - Capture setting (machine-local, UserDefaults)

    static let enabledDefaultsKey = "BackbeatDebugLog.enabled"

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledDefaultsKey)
    }

    public static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledDefaultsKey)
    }

    /// PID of the live `log stream` capture child, persisted so the next launch
    /// can reap it if an unclean exit (crash/SIGKILL) left it orphaned — clean
    /// quit terminates it directly and clears this.
    static let captureChildPIDKey = "BackbeatDebugLog.captureChildPID"

    public static func lastCaptureChildPID(defaults: UserDefaults = .standard) -> Int32? {
        let value = defaults.integer(forKey: captureChildPIDKey)
        return value > 0 ? Int32(value) : nil
    }

    public static func setLastCaptureChildPID(_ pid: Int32?, defaults: UserDefaults = .standard) {
        if let pid, pid > 0 {
            defaults.set(Int(pid), forKey: captureChildPIDKey)
        } else {
            defaults.removeObject(forKey: captureChildPIDKey)
        }
    }

    /// Where the captured `log stream` output is written. Prefers the dev
    /// project root — the "working directory" during development, where the
    /// file sits alongside the source for easy sharing — and falls back to
    /// Application Support when that path does not exist (a distributed build,
    /// whose compile-time `#filePath` root is gone).
    public static var fileURL: URL {
        let projectRoot = BackbeatFileLocations.projectRoot
        if FileManager.default.fileExists(atPath: projectRoot.path) {
            return projectRoot.appendingPathComponent("debug.log")
        }
        return BackbeatFileLocations.applicationSupportDirectory
            .appendingPathComponent("debug.log")
    }
}
