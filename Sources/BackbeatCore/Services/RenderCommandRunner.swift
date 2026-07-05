import Foundation

/// Shared subprocess helpers for the renderers and analyzers: run-or-throw,
/// the Demucs MPS-to-CPU fallback, and output-file validation. Errors are
/// BoostedDrumsRenderError so user-visible messages are unchanged.
public struct RenderCommandRunner: Sendable {
    private let executor: any RenderCommandExecuting

    public init(executor: any RenderCommandExecuting) {
        self.executor = executor
    }

    public func runOrThrow(_ command: CommandSpec) async throws {
        let result = try await executor.run(command)
        guard result.terminationStatus == 0 else {
            throw BoostedDrumsRenderError.commandFailed(
                command: URL(fileURLWithPath: command.executablePath).lastPathComponent,
                status: result.terminationStatus,
                output: result.output
            )
        }
    }

    public func runDemucsWithFallback(
        demucsPath: String,
        sourceURL: URL,
        separationRootURL: URL,
        profile: DemucsSeparationProfile
    ) async throws {
        let primaryCommand = BoostedDrumsRenderPlan.demucsCommand(
            demucsPath: demucsPath,
            sourceURL: sourceURL,
            separationRootURL: separationRootURL,
            profile: profile
        )
        let primaryResult = try await executor.run(primaryCommand)
        guard primaryResult.terminationStatus != 0 else {
            return
        }

        guard let fallbackProfile = profile.fallbackProfile else {
            throw commandFailed(primaryCommand, result: primaryResult)
        }
        try resetSeparationDirectory(separationRootURL)

        let fallbackCommand = BoostedDrumsRenderPlan.demucsCommand(
            demucsPath: demucsPath,
            sourceURL: sourceURL,
            separationRootURL: separationRootURL,
            profile: fallbackProfile
        )
        let fallbackResult = try await executor.run(fallbackCommand)
        guard fallbackResult.terminationStatus == 0 else {
            throw commandFailed(fallbackCommand, result: fallbackResult)
        }
    }

    public static func requireExistingFile(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BoostedDrumsRenderError.missingStem(url)
        }
    }

    public static func requireNonEmptyFile(_ url: URL) throws {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize,
            size > 0
        else {
            throw BoostedDrumsRenderError.invalidOutput(url)
        }
    }

    private func commandFailed(_ command: CommandSpec, result: RenderCommandResult) -> BoostedDrumsRenderError {
        BoostedDrumsRenderError.commandFailed(
            command: URL(fileURLWithPath: command.executablePath).lastPathComponent,
            status: result.terminationStatus,
            output: result.output
        )
    }

    private func resetSeparationDirectory(_ separationRootURL: URL) throws {
        if FileManager.default.fileExists(atPath: separationRootURL.path) {
            try FileManager.default.removeItem(at: separationRootURL)
        }
        try FileManager.default.createDirectory(at: separationRootURL, withIntermediateDirectories: true)
    }
}
