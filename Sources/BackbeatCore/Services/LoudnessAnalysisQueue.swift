import Foundation

/// Serial, deduplicated loudness-analysis queue.
///
/// Replaces the former cancel-and-restart sweep
/// (`BackbeatRootView.analyzeMissingLoudnessProfiles`), which cancelled and
/// immediately re-scanned on every trigger without awaiting the prior pass.
/// `TrackLoudnessAnalyzer.analyze` only checks cancellation once, before its
/// synchronous decode + BS.1770 DSP, and a profile commits only after that
/// work finishes — so the replacement scan's "still missing a profile"
/// snapshot re-included a track whose analysis was still running, and an
/// import burst could run concurrent duplicate full-track analyses
/// (~200-300 MB each) of the same file (EFF-001; also closes C-16's
/// wasted-restart).
///
/// Invariant: at most one analysis runs at a time, globally; one track ID is
/// never analyzed twice concurrently; enqueuing more work while a drain is in
/// progress only appends to the queue — it never cancels or restarts the item
/// currently analyzing.
public actor LoudnessAnalysisQueue {
    /// One track's pending analysis: the source file to decode, plus the
    /// normalization settings snapshot in effect when it was enqueued.
    public struct Item: Sendable {
        public let trackID: BackbeatTrack.ID
        public let sourceURL: URL
        public let settings: PlaybackNormalizationSettings

        public init(trackID: BackbeatTrack.ID, sourceURL: URL, settings: PlaybackNormalizationSettings) {
            self.trackID = trackID
            self.sourceURL = sourceURL
            self.settings = settings
        }
    }

    private let analyze: @Sendable (Item) async throws -> TrackLoudnessProfile
    /// Delivers a finished profile back to the app. Required at construction:
    /// every owner (BackbeatApp) can build the real closure by then, and an
    /// optional commit would silently discard a finished full-track analysis —
    /// the exact waste this queue exists to prevent.
    private let commit: @Sendable @MainActor (BackbeatTrack.ID, TrackLoudnessProfile) -> Void

    // `pending` + `pendingIDs` track queued-but-not-started items; `inFlightID`
    // is the one item currently analyzing. Together they dedupe an enqueue
    // against both "already waiting" and "already running" without ever
    // touching the in-flight item.
    private var pending: [Item] = []
    private var pendingIDs: Set<BackbeatTrack.ID> = []
    private var inFlightID: BackbeatTrack.ID?
    private var drainTask: Task<Void, Never>?

    public init(
        analyze: @escaping @Sendable (Item) async throws -> TrackLoudnessProfile,
        commit: @escaping @Sendable @MainActor (BackbeatTrack.ID, TrackLoudnessProfile) -> Void
    ) {
        self.analyze = analyze
        self.commit = commit
    }

    /// Appends every item not already pending or in flight, then starts the
    /// drain loop if it's idle. Safe to call repeatedly, including while a
    /// drain is running — a call mid-drain only grows the queue; it never
    /// cancels or restarts the item currently analyzing.
    public func enqueue(_ items: [Item]) {
        for item in items {
            guard item.trackID != inFlightID, !pendingIDs.contains(item.trackID) else { continue }
            pendingIDs.insert(item.trackID)
            pending.append(item)
        }
        guard drainTask == nil, !pending.isEmpty else { return }
        drainTask = Task {
            await self.drain()
        }
    }

    /// Drops every queued-but-not-started item and signals the drain task to
    /// stop picking up new work. The in-flight item (if any) is not
    /// interrupted: `analyze` is not cancellation-aware mid-flight (only at
    /// its very start), so the bound on this call is one item's remaining
    /// runtime, not zero — mirroring the prior sweep, where cancellation only
    /// ever took effect between tracks, never inside one.
    public func cancelAll() {
        pending.removeAll()
        pendingIDs.removeAll()
        drainTask?.cancel()
    }

    private func drain() async {
        while !pending.isEmpty {
            let item = pending.removeFirst()
            pendingIDs.remove(item.trackID)
            inFlightID = item.trackID
            do {
                let profile = try await analyze(item)
                await commit(item.trackID, profile)
            } catch {
                // Log-and-continue: mirrors the prior sweep's bare
                // `catch { continue }` — one track's failed analysis must not
                // stop the rest of the batch.
            }
            inFlightID = nil
        }
        drainTask = nil
    }
}
