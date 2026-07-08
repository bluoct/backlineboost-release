import Foundation

public enum BackbeatFileLocations {
    /// Dev-machine only: #filePath is baked in at compile time, so this
    /// resolves to a nonexistent path in distributed builds. Consumers must
    /// treat it as best-effort (the legacy in-repo migration paths fail soft).
    public static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    public static var applicationSupportDirectory: URL {
        userDirectory(.applicationSupportDirectory)
            .appendingPathComponent("Backbeat", isDirectory: true)
    }

    public static var cachesDirectory: URL {
        userDirectory(.cachesDirectory)
            .appendingPathComponent("Backbeat", isDirectory: true)
    }

    public static var managedSourceDirectory: URL {
        applicationSupportDirectory
            .appendingPathComponent("AppAudioLibrary", isDirectory: true)
            .appendingPathComponent("sources", isDirectory: true)
    }

    public static var legacyManagedSourceDirectory: URL {
        projectRoot
            .appendingPathComponent("AppAudioLibrary", isDirectory: true)
            .appendingPathComponent("sources", isDirectory: true)
    }

    public static var librarySnapshotURL: URL {
        applicationSupportDirectory
            .appendingPathComponent("AppAudioLibrary", isDirectory: true)
            .appendingPathComponent("library.json")
    }

    public static var legacyLibrarySnapshotURL: URL {
        projectRoot
            .appendingPathComponent("AppAudioLibrary", isDirectory: true)
            .appendingPathComponent("library.json")
    }

    public static var renderRootDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("renders", isDirectory: true)
    }

    public static var artworkDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("artwork", isDirectory: true)
    }

    /// The converted MLX model cache lives here (`mlx-htdemucs-v*/`), produced in-process
    /// from the htdemucs checkpoint that ships in the app bundle. This directory is
    /// writable — the read-only bundled `.th` is never written beside — and the cache is
    /// regenerated on a miss (e.g. a schema bump).
    public static var modelsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    public static var legacyRenderRootDirectory: URL {
        projectRoot.appendingPathComponent("renders", isDirectory: true)
    }

    public static var temporaryDirectory: URL {
        cachesDirectory.appendingPathComponent("Temporary", isDirectory: true)
    }

    /// Scratch area where Music-app drags materialize their promised files
    /// before import copies them into the managed library. The drop shim
    /// creates one UUID subdirectory per drop and removes it afterwards.
    public static var musicDropsDirectory: URL {
        temporaryDirectory.appendingPathComponent("MusicDrops", isDirectory: true)
    }

    private static func userDirectory(_ directory: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}
