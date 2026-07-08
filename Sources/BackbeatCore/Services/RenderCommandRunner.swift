import Foundation

/// Output-file validation for the renderer. This was the demucs/ffmpeg subprocess
/// runner until the native MLX engine (Task 8) removed separation subprocesses and
/// Task 9 removed the tool-resolution apparatus; the run-or-throw executor and its
/// `RenderCommandExecuting` seam went with them. What remains is the one non-empty
/// output check the renderer still calls after writing its `.m4a` files.
public enum RenderCommandRunner {
    public static func requireNonEmptyFile(_ url: URL) throws {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize,
            size > 0
        else {
            throw BoostedDrumsRenderError.invalidOutput(url)
        }
    }
}
