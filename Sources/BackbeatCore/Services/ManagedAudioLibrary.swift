import Foundation

public struct ManagedAudioLibrary: Sendable {
    public let sourceDirectory: URL

    public init(sourceDirectory: URL = BackbeatFileLocations.managedSourceDirectory) {
        self.sourceDirectory = sourceDirectory
    }

    public func storeSourceFile(_ sourceURL: URL) throws -> URL {
        let trackDirectory = sourceDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: trackDirectory, withIntermediateDirectories: true)

        let destinationURL = trackDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            // A failed copy (disk full, source volume gone mid-copy) must not
            // strand its own just-created directory — possibly holding a
            // truncated audio file — invisible to the library (COR-012b).
            try? FileManager.default.removeItem(at: trackDirectory)
            throw error
        }
        return destinationURL
    }

    /// Removes the per-track UUID directory left empty after its source file is
    /// deleted (COR-012c). Guarded twice: the directory must be a DIRECT child
    /// of the managed source root, and must hold no visible files — hidden
    /// litter (a Finder .DS_Store) must not block the prune forever, and
    /// removeItem deletes it along with the directory. A sourceURL outside the
    /// managed tree (legacy/user paths) is never touched.
    public static func pruneEmptySourceDirectory(
        after sourceURL: URL,
        root: URL = BackbeatFileLocations.managedSourceDirectory
    ) {
        let parent = sourceURL.deletingLastPathComponent().standardizedFileURL
        guard parent.deletingLastPathComponent().path == root.standardizedFileURL.path else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ), contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: parent)
    }
}
