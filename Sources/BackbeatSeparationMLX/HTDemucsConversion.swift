import BackbeatCore
import Foundation
import MLX

/// htdemucs `.th`→MLX conversion + cache management. The bundled checkpoint is
/// converted to the custom engine's layout in-process (no Python, no third-party
/// pre-converted weights: gates G5 + runtime purity) and cached under Application
/// Support, so the ≈84 MB conversion runs once per schema version rather than every
/// launch. `CustomHTDemucsSeparator.ensurePipeline()` calls this lazily on a cache
/// miss (the sole caller since the first-run download pipeline was removed).
///
/// The cache directory is versioned by `customEngineSchemaVersion` below, so a schema
/// bump invalidates an older on-disk conversion and re-produces it from the (unchanged)
/// bundled `.th` (architecture D2). v3 has been the only schema since the Phase 5
/// cut-over deleted the vendored port (and its v2 layout with it); the stale v1/v2
/// cache directories are purged once at launch by `LegacyWeightsCleanup`.
public enum HTDemucsConversion {
    /// The custom engine's converted-cache layout version (charter Phase 2 retarget:
    /// `HTDemucsWeightAdapter.convertForCustomEngine` — torch names verbatim, MLX
    /// channels-last conv layout). Single source of truth for the cache layout — bump
    /// when the adapter's output layout changes so a stale on-disk conversion is
    /// invalidated. (v1/v2 were the deleted vendored port's layouts; a bump must also
    /// add the newly-orphaned version to `LegacyWeightsCleanup`.)
    static let customEngineSchemaVersion = 3

    public static var customEngineCacheSubdirectoryName: String {
        "mlx-htdemucs-v\(customEngineSchemaVersion)"
    }

    public static func customEngineCacheDirectory(inModelsDirectory modelsDirectory: URL) -> URL {
        modelsDirectory.appendingPathComponent(customEngineCacheSubdirectoryName, isDirectory: true)
    }

    /// Ensure `<cacheDirectory>/htdemucs.safetensors` exists, converting Meta's `.th`
    /// in-process (no Python, no third-party pre-converted weights: gates G5 + runtime
    /// purity) on a cache miss. No config JSON — the custom engine's hyperparameters
    /// are compiled in; the cache is just the weights file. Idempotent — a present
    /// cache is a no-op.
    ///
    /// **Serialized** through `gate` so there is only ever one writer of a given cache
    /// directory at a time. The render queue is a serial FIFO and the separator is a
    /// single actor, so concurrent conversions are not expected today — but the gate
    /// keeps the fixed temp-file/rename safe against any future second caller (they would
    /// otherwise race on the same temp file, corrupting the cache or spuriously failing).
    /// The second caller through waits for the first, then sees the finished cache and
    /// no-ops.
    public static func ensureCustomEngineConverted(weightsURL: URL, cacheDirectory: URL) async throws {
        try await gate.ensureConverted(weightsURL: weightsURL, cacheDirectory: cacheDirectory)
    }

    private static let gate = ConversionGate()

    /// Serializes the actual conversion so there is only ever one writer of a given
    /// cache directory at a time (the idempotent cache check then makes any waiting
    /// caller a no-op).
    private actor ConversionGate {
        func ensureConverted(weightsURL: URL, cacheDirectory: URL) throws {
            let fm = FileManager.default
            let weights = cacheDirectory.appendingPathComponent("htdemucs.safetensors")
            if fm.fileExists(atPath: weights.path) {
                return
            }
            guard fm.fileExists(atPath: weightsURL.path) else {
                throw HTDemucsConversionError.weightsNotReady(weightsURL)
            }
            try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

            // Cooperative checkpoints between the conversion phases (review R8:
            // the first-run conversion was uncancellable, pinning the queue for
            // tens of seconds against the ≤-one-segment cancel contract). The
            // temp-file/rename write below stays atomic, so a cancelled
            // conversion leaves no partial cache.
            try Task.checkCancellation()
            let checkpoint = try TorchCheckpointReader().read(contentsOf: weightsURL)
            try Task.checkCancellation()
            let state = checkpoint.tensors(under: "state")
            guard state.count == HTDemucsWeightAdapter.expectedSourceTensorCount else {
                throw HTDemucsConversionError.unexpectedCheckpoint(
                    expected: HTDemucsWeightAdapter.expectedSourceTensorCount, got: state.count
                )
            }
            let mlxWeights = try HTDemucsWeightAdapter.convertForCustomEngine(state: state)
            try Task.checkCancellation()

            // Atomic write (temp → rename) so a crash mid-convert can't leave a
            // half-written cache that later reads as "ready". Only one writer reaches
            // here at a time (the actor serializes), so the fixed temp name is safe.
            // The temp keeps the `.safetensors` extension because `MLX.save` dispatches
            // on it.
            let tmpWeights = cacheDirectory.appendingPathComponent("htdemucs.partial.safetensors")
            try? fm.removeItem(at: tmpWeights)
            try MLX.save(arrays: mlxWeights, url: tmpWeights)
            try? fm.removeItem(at: weights)
            try fm.moveItem(at: tmpWeights, to: weights)
        }
    }
}

/// The weights/conversion error surface. (Previously `MLXStemSeparatorError`; the
/// vendored actor died with the port at the Phase 5 cut-over, but these errors belong
/// to the conversion path, which survives it. The port-era `missingStem` case went
/// with the port — the custom engine's overlap-add always materializes all four
/// stems, and the renderer's A3 empty-stem validation covers the buffer contract.)
public enum HTDemucsConversionError: LocalizedError, CustomStringConvertible {
    /// Maps the demucs-era `missingCommand` (amendment A2 → weights-not-ready).
    case weightsNotReady(URL)
    case unexpectedCheckpoint(expected: Int, got: Int)

    public var description: String {
        switch self {
        case .weightsNotReady:
            return "The separation model couldn't be loaded from the app bundle. Please reinstall Backline Boost and try again."
        case let .unexpectedCheckpoint(expected, got):
            return "htdemucs checkpoint has \(got) state tensors, expected \(expected)."
        }
    }

    // Conform to LocalizedError so the render queue's `error.localizedDescription`
    // (surfaced as the .renderFailed banner copy) shows this actionable message
    // rather than a generic "operation couldn't be completed" NSError string.
    public var errorDescription: String? { description }
}
