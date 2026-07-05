import CryptoKit
import Foundation

/// Detects whether a candidate import is byte-identical to an original the
/// library already stores. Stored files are prefiltered by size so only
/// same-size candidates pay for hashing; comparisons never load whole files
/// into memory. Any read failure is treated as "not a duplicate" so a
/// broken stored file can never block a fresh import.
public struct DuplicateTrackDetector: Sendable {
    public init() {}

    /// Returns the first stored URL whose content matches the candidate, or
    /// nil when the candidate is new.
    public func existingDuplicate(of candidateURL: URL, among storedURLs: [URL]) -> URL? {
        guard let candidateSize = fileSize(candidateURL), candidateSize > 0 else { return nil }

        let sameSize = storedURLs.filter { fileSize($0) == candidateSize }
        guard !sameSize.isEmpty else { return nil }

        guard let candidateDigest = try? sha256(of: candidateURL) else { return nil }
        return sameSize.first { url in
            (try? sha256(of: url)) == candidateDigest
        }
    }

    private func sha256(of url: URL) throws -> SHA256Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }

    private func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.int64Value
    }
}
