import Foundation

/// Waits for promised drag files to finish landing on disk. Legacy
/// Carbon-style promise sources (like the Music app) write the files
/// asynchronously after the drop returns, so the receiver must watch the
/// destination directory until each file exists and its size stops changing.
public struct PromisedFileAwaiter: Sendable {
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval

    public init(timeout: TimeInterval = 10, pollInterval: TimeInterval = 0.25) {
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    /// Returns the URLs of the named files that stabilized inside
    /// `directory` before the timeout. A file counts once it exists with a
    /// non-zero size that is unchanged across two consecutive polls. On
    /// timeout the stabilized subset is returned — a mixed drag of local and
    /// DRM-protected tracks imports the local ones while the unwritable
    /// promises silently drop out.
    public func stabilizedFiles(named names: [String], in directory: URL) async -> [URL] {
        guard !names.isEmpty else { return [] }

        let deadline = Date().addingTimeInterval(timeout)
        var lastSizes: [String: Int64] = [:]
        var stable = Set<String>()

        while stable.count < names.count {
            for name in names where !stable.contains(name) {
                let url = directory.appendingPathComponent(name)
                guard let size = fileSize(url), size > 0 else { continue }
                if lastSizes[name] == size {
                    stable.insert(name)
                } else {
                    lastSizes[name] = size
                }
            }
            if stable.count == names.count || Date() >= deadline {
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        return names
            .filter { stable.contains($0) }
            .map { directory.appendingPathComponent($0) }
    }

    private func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.int64Value
    }
}
