import Foundation
import os

public enum RenderPreflightResult: Equatable, Sendable {
    case ready(demucsPath: String)
    case missingDemucs

    public var message: String {
        switch self {
        case .ready:
            "Ready to render."
        case .missingDemucs:
            "Demucs is not installed. Install or configure Demucs before rendering boosted-drums tracks."
        }
    }
}

public struct RenderPreflight: Sendable {
    public typealias CommandResolver = @Sendable (String) -> String?

    public static let standardCommandSearchDirectories: [URL] = [
        URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
        URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        URL(fileURLWithPath: "/opt/local/bin", isDirectory: true)
    ]

    /// Packaged-app landing zone: a future install flow drops third-party
    /// tools here after the user acknowledges their licenses.
    public static var managedToolsBinDirectory: URL {
        BackbeatFileLocations.applicationSupportDirectory
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    private let commandResolver: CommandResolver

    public init(commandResolver: @escaping CommandResolver = RenderPreflight.resolveCommand(_:)) {
        self.commandResolver = commandResolver
    }

    public func check() async -> RenderPreflightResult {
        guard let demucsPath = commandResolver("demucs"), !demucsPath.isEmpty else {
            return .missingDemucs
        }
        return .ready(demucsPath: demucsPath)
    }

    private static let resolvedCommandCache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    public static func resolveCommand(_ command: String) -> String? {
        memoizedResolveCommand(command, cache: resolvedCommandCache) {
            resolveCommand(
                $0,
                projectRoot: BackbeatFileLocations.projectRoot,
                pathResolver: RenderPreflight.resolvePathCommand(_:),
                standardSearchDirectories: standardCommandSearchDirectories,
                overridePath: overridePath(for: $0),
                managedToolsDirectory: managedToolsBinDirectory,
                loginShellResolver: RenderPreflight.resolveLoginShellCommand(_:)
            )
        }
    }

    static func memoizedResolveCommand(
        _ command: String,
        cache: OSAllocatedUnfairLock<[String: String]>,
        resolve: (String) -> String?
    ) -> String? {
        if let cached = cache.withLock({ $0[command] }) {
            return cached
        }
        // Resolution runs OUTSIDE the lock — never hold it across a process
        // spawn; a rare duplicate concurrent probe is harmless. nil results
        // are deliberately not cached so check() recovers when the user
        // installs demucs mid-session.
        let resolved = resolve(command)
        if let resolved {
            cache.withLock { $0[command] = resolved }
        }
        return resolved
    }

    /// Settings changes must take effect without relaunching, so an override
    /// edit clears the successful-resolution cache.
    public static func invalidateResolvedCommandCache() {
        resolvedCommandCache.withLock { $0.removeAll() }
    }

    // MARK: - User-configured tool overrides

    static let overrideDefaultsKeyPrefix = "BackbeatToolPath."

    public static func overridePath(for command: String) -> String? {
        let value = UserDefaults.standard.string(forKey: overrideDefaultsKeyPrefix + command)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    public static func setOverridePath(_ path: String?, for command: String) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: overrideDefaultsKeyPrefix + command)
        } else {
            UserDefaults.standard.removeObject(forKey: overrideDefaultsKeyPrefix + command)
        }
        invalidateResolvedCommandCache()
    }

    // MARK: - Resolution

    public static func resolveCommand(
        _ command: String,
        projectRoot: URL,
        pathResolver: CommandResolver
    ) -> String? {
        resolveCommand(
            command,
            projectRoot: projectRoot,
            pathResolver: pathResolver,
            standardSearchDirectories: standardCommandSearchDirectories
        )
    }

    public static func resolveCommand(
        _ command: String,
        projectRoot: URL,
        pathResolver: CommandResolver,
        standardSearchDirectories: [URL],
        overridePath: String? = nil,
        managedToolsDirectory: URL? = nil,
        loginShellResolver: CommandResolver? = nil
    ) -> String? {
        // A configured override wins outright; a stale one falls through so a
        // bad Settings entry degrades to the automatic probes instead of
        // breaking rendering.
        if let overridePath, FileManager.default.isExecutableFile(atPath: overridePath) {
            return overridePath
        }
        if let managedToolsDirectory {
            let managedCommandURL = managedToolsDirectory.appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: managedCommandURL.path) {
                return managedCommandURL.path
            }
        }
        let localCommandURL = projectRoot
            .appendingPathComponent(".venv", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(command)
        if FileManager.default.isExecutableFile(atPath: localCommandURL.path) {
            return localCommandURL.path
        }
        if let pathCommand = pathResolver(command) {
            return pathCommand
        }
        if let loginShellCommand = loginShellResolver?(command) {
            return loginShellCommand
        }
        return standardSearchDirectories
            .map { $0.appendingPathComponent(command) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }?
            .path
    }

    public static func resolvePathCommand(_ command: String) -> String? {
        runResolver(executablePath: "/usr/bin/env", arguments: ["which", command])
    }

    /// GUI apps launched by launchd get a minimal PATH; a login shell sees the
    /// same tools the user's terminal does (pipx, ~/.local/bin, custom dirs).
    public static func resolveLoginShellCommand(_ command: String) -> String? {
        guard command.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        return runResolver(executablePath: "/bin/zsh", arguments: ["-lc", "command -v \(command)"])
    }

    private static func runResolver(executablePath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, output.hasPrefix("/") else { return nil }
        return output
    }

    // MARK: - Subprocess environment

    /// Environment for tool subprocesses. Demucs shells out to `ffmpeg` by
    /// PATH lookup, and under launchd the inherited PATH is just the system
    /// directories — so the child PATH is rebuilt to include every directory
    /// the app itself would search.
    public static func subprocessEnvironment(executablePath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var directories = [URL(fileURLWithPath: executablePath).deletingLastPathComponent().path]
        if let ffmpegPath = resolveCommand("ffmpeg") {
            directories.append(URL(fileURLWithPath: ffmpegPath).deletingLastPathComponent().path)
        }
        directories.append(managedToolsBinDirectory.path)
        directories.append(contentsOf: standardCommandSearchDirectories.map(\.path))
        environment["PATH"] = augmentedPATHValue(directories: directories, existingPATH: environment["PATH"])
        return environment
    }

    static func augmentedPATHValue(directories: [String], existingPATH: String?) -> String {
        var seen = Set<String>()
        var entries: [String] = []
        for directory in directories + (existingPATH?.components(separatedBy: ":") ?? []) {
            guard !directory.isEmpty, seen.insert(directory).inserted else { continue }
            entries.append(directory)
        }
        return entries.joined(separator: ":")
    }
}
