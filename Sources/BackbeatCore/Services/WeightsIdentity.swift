import Foundation

/// Identifies the bundled htdemucs checkpoint: the resource filename, the SHA-256 the
/// bytes must hash to, their exact byte size, and the upstream URL the artifact was
/// originally published at.
///
/// The app ships this checkpoint inside its own bundle (`Contents/Resources`) and reads
/// it locally — it performs **no** network I/O. `provenanceURL` is a record of origin
/// (see `WEIGHTS.md`), not a runtime fetch: it is where the bytes came from, kept so the
/// build script and the docs point at a single source of truth. The build script
/// verifies the bundled bytes against `sha256` before code-signing seals them, so the
/// shipped checkpoint is byte-identical to Meta's published artifact.
public struct WeightsIdentity: Sendable, Equatable {
    public let filename: String
    public let sha256: String
    public let byteCount: Int64
    public let provenanceURL: URL

    public init(filename: String, sha256: String, byteCount: Int64, provenanceURL: URL) {
        self.filename = filename
        self.sha256 = sha256
        self.byteCount = byteCount
        self.provenanceURL = provenanceURL
    }

    /// Meta's official htdemucs hybrid-transformer checkpoint (`955717e8`), MIT-licensed
    /// (© Meta Platforms, Inc.) and published for research purposes. Digest + size
    /// captured 2026-07-06; the digest begins with the published prefix `8726e21a`.
    public static let htdemucs = WeightsIdentity(
        filename: "955717e8-8726e21a.th",
        sha256: "8726e21a993978c7ba086d3872e7608d7d5bfca646ca4aca459ffda844faa8b4",
        byteCount: 84_141_911,
        provenanceURL: URL(string: "https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/955717e8-8726e21a.th")!)

    /// The checkpoint's location inside `bundle` (the app bundle by default). Uses the
    /// standard resource lookup, falling back to the deterministic `Contents/Resources`
    /// path so the return type stays non-optional — a genuinely absent resource (a broken
    /// build) surfaces later as `weightsNotReady` at conversion time rather than as a nil
    /// here.
    public func bundledURL(in bundle: Bundle = .main) -> URL {
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        return bundle.url(forResource: name, withExtension: ext)
            ?? bundle.bundleURL.appendingPathComponent("Contents/Resources/\(filename)")
    }
}
