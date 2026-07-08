import Foundation

/// One-time cleanup for users upgrading from earlier builds, run fail-soft at launch:
///
///  • builds that downloaded the htdemucs checkpoint at first run left the raw `.th`
///    (≈84 MB), its verification manifest, and any interrupted-download staging file in
///    Application Support — the checkpoint now ships in the app bundle, so the
///    downloaded copy is dead weight;
///  • builds before the custom-engine Phase 5 cut-over left the vendored port's
///    converted caches (`mlx-htdemucs-v1/`, `mlx-htdemucs-v2/`) that no code can read
///    anymore.
///
/// The custom engine's live conversion cache (`mlx-htdemucs-v3/`) is deliberately
/// **kept**: it is still the runtime artifact and is byte-for-byte what a fresh convert
/// would produce, so keeping it means an upgrading user does not re-convert. Fail-soft —
/// a cleanup that can't run is harmless (the files are merely orphaned), so nothing here
/// throws.
public enum LegacyWeightsCleanup {
    /// Converted-cache directories no shipped code reads anymore. The LIVE cache
    /// (`HTDemucsConversion.customEngineCacheSubdirectoryName`, currently v3) must
    /// never be listed here; on a future schema bump, append the newly-orphaned
    /// version. (Hardcoded names because `BackbeatCore` cannot depend on the MLX
    /// target that owns the schema constant.)
    private static let staleConvertedCaches = ["mlx-htdemucs-v1", "mlx-htdemucs-v2"]

    public static func purgeLegacyArtifacts(
        modelsDirectory: URL = BackbeatFileLocations.modelsDirectory,
        filename: String = WeightsIdentity.htdemucs.filename
    ) {
        let fileManager = FileManager.default
        let orphans = [
            modelsDirectory.appendingPathComponent(filename),
            modelsDirectory.appendingPathComponent("manifest.json"),
            modelsDirectory.appendingPathComponent(".\(filename).partial"),
        ] + staleConvertedCaches.map {
            modelsDirectory.appendingPathComponent($0, isDirectory: true)
        }
        for url in orphans where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }
}
