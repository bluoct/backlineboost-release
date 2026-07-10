import Foundation

/// Launch-time sweep that re-checks a pre-F1 track's persisted `duration`
/// against a precise probe of its original file, healing legacy fast-estimate
/// values so file-derived transport (A1) and the persisted label/scrubber
/// agree (Phase A / F1).
public struct TrackDurationBackfill: Sendable {
    public struct Item: Sendable {
        public let trackID: UUID
        public let sourceURL: URL
        public let currentDuration: TimeInterval

        public init(trackID: UUID, sourceURL: URL, currentDuration: TimeInterval) {
            self.trackID = trackID
            self.sourceURL = sourceURL
            self.currentDuration = currentDuration
        }
    }

    public enum Outcome: Sendable, Equatable {
        case updated(TimeInterval)
        case keptEstimate
    }

    /// Matches the render-pair validation gate elsewhere — a persisted value
    /// within this of the precise probe is treated as already accurate.
    private static let tolerance: TimeInterval = 0.05

    public init() {}

    /// Strictly sequential — one probe in flight at a time, so a large first
    /// launch sweep never contends with a simultaneous import or render for
    /// file I/O. Checks `Task.isCancelled` between items so a quit-mid-sweep
    /// leaves the remaining tracks pending for the next launch.
    public func run(
        items: [Item],
        probe: @Sendable (URL) async throws -> TimeInterval,
        onResolve: @MainActor (UUID, Outcome) async -> Void
    ) async {
        for item in items {
            guard !Task.isCancelled else { return }
            do {
                let precise = try await probe(item.sourceURL)
                if abs(precise - item.currentDuration) > Self.tolerance {
                    DebugLog.importing.notice("backfill.updated trackID=\(item.trackID.uuidString, privacy: .public) old=\(item.currentDuration) new=\(precise)")
                    await onResolve(item.trackID, .updated(precise))
                } else {
                    DebugLog.importing.notice("backfill.kept trackID=\(item.trackID.uuidString, privacy: .public) delta=\(abs(precise - item.currentDuration))")
                    await onResolve(item.trackID, .keptEstimate)
                }
            } catch {
                // A missing/unreadable original keeps its estimate — same
                // posture as the F7 missing-file fallback.
                DebugLog.importing.error("backfill.probeFailed trackID=\(item.trackID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                await onResolve(item.trackID, .keptEstimate)
            }
        }
    }
}
