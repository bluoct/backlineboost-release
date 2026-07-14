import Foundation
import Observation

/// Seam the coordinator writes through — `LibrarySnapshotWriter` already
/// implements both methods; the protocol exists so tests can substitute a
/// recording fake without touching disk.
public protocol LibrarySnapshotWriting: Sendable {
    func nextGeneration() -> Int
    func write(_ snapshot: LibrarySnapshot, generation: Int) throws
}

extension LibrarySnapshotWriter: LibrarySnapshotWriting {}

/// One debounce for every library-save trigger — root-view observation,
/// render completions, loudness commits, duration backfill — replacing the
/// two duplicated debounce paths (root view + app delegate) that used to
/// schedule two full JSON writes for a single render completion with the
/// window open, each under a different failure policy (CLR-003). The
/// generation guard inside `LibrarySnapshotWriter` stays load-bearing: two
/// debounce firings can still overlap in their detached-write phase.
@MainActor
@Observable
public final class LibraryPersistenceCoordinator {
    private let writer: any LibrarySnapshotWriting
    private let makeSnapshot: @MainActor () -> LibrarySnapshot
    private let debounceInterval: Duration
    private let maxSaveLatency: Duration
    private let failureAlertThreshold: Int
    private let clock = ContinuousClock()
    @ObservationIgnored
    private var pendingSave: Task<Void, Never>?
    @ObservationIgnored
    private var burstStartedAt: ContinuousClock.Instant?

    public private(set) var saveFailureCount = 0
    public var saveFailureMessage: String?

    public init(
        writer: any LibrarySnapshotWriting,
        makeSnapshot: @escaping @MainActor () -> LibrarySnapshot,
        debounceInterval: Duration = .milliseconds(500),
        maxSaveLatency: Duration = .seconds(2),
        failureAlertThreshold: Int = 3
    ) {
        self.writer = writer
        self.makeSnapshot = makeSnapshot
        self.debounceInterval = debounceInterval
        self.maxSaveLatency = maxSaveLatency
        self.failureAlertThreshold = failureAlertThreshold
    }

    // Debounced so a burst of changes (a slider drag, a render completion
    // alongside its per-file loudness commit) coalesces into one save,
    // written off the main actor so the UI never blocks. The debounce is
    // capped by maxSaveLatency: a single pending save that every change
    // cancels would otherwise be starved indefinitely by a continuous
    // interaction (drag events land < debounceInterval apart), and a
    // force-kill mid-drag would lose everything since the burst began —
    // including a render completion that used to be guaranteed on disk
    // ~500ms after it happened.
    public func noteLibraryChanged() {
        let now = clock.now
        let burstStart = burstStartedAt ?? now
        burstStartedAt = burstStart
        let remainingUntilCap = maxSaveLatency - burstStart.duration(to: now)
        let delay = min(debounceInterval, max(.zero, remainingUntilCap))
        pendingSave?.cancel()
        pendingSave = Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            // Fire-time capture: generation order must equal
            // snapshot-freshness order, so grab both together right before
            // the write instead of back at the triggering call — that's what
            // makes a burst of changes collapse into one save of the final
            // state rather than a stale mid-burst one.
            burstStartedAt = nil
            let snapshot = makeSnapshot()
            let generation = writer.nextGeneration()
            let writer = writer
            do {
                try await Task.detached(priority: .utility) {
                    try writer.write(snapshot, generation: generation)
                }.value
                saveFailureCount = 0
            } catch {
                // A persistent failure (disk full / permissions) silently lost
                // every change before this; log it and, after a few consecutive
                // failures, tell the user rather than only print()ing (F12).
                DebugLog.persistence.error("library.save.debounced.failed generation=\(generation) error=\(error.localizedDescription, privacy: .public)")
                saveFailureCount += 1
                if saveFailureCount >= failureAlertThreshold, saveFailureMessage == nil {
                    saveFailureMessage = "Backline Boost hasn't been able to save your library for the last \(saveFailureCount) changes (\(error.localizedDescription)). Check that the disk isn't full and that you can write to the app's Application Support folder."
                }
            }
        }
    }

    // Library saves are debounced; flush the latest state so quitting inside
    // the debounce window cannot drop the final change. Always writes — no
    // dirty flag — matching today's terminate-flush behavior.
    public func flushForTermination() {
        pendingSave?.cancel()
        burstStartedAt = nil
        let snapshot = makeSnapshot()
        let generation = writer.nextGeneration()
        do {
            try writer.write(snapshot, generation: generation)
        } catch {
            // A swallowed terminate-flush failure silently lost the session's
            // final changes; leave a trace (F12). The process is dying, so
            // there's no user-facing recovery path left.
            DebugLog.persistence.error("library.save.terminate.failed error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
