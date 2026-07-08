import Foundation
import Observation

/// Serialized background render queue: imports enqueue here, one in-process
/// separation+mix job runs at a time, and the rest wait FIFO. Queue membership and progress are
/// runtime-only state — persistence re-derives the queue on launch from track
/// status via `enqueueMissingRenders()`.
@MainActor @Observable
public final class RenderQueueCoordinator {
    public typealias RenderExecution =
        @Sendable (BackbeatTrack, RenderProgressHandler?) async throws -> PracticeRenderResult

    public private(set) var pendingTrackIDs: [BackbeatTrack.ID] = []
    public private(set) var activeTrackID: BackbeatTrack.ID?
    public private(set) var activeProgress: RenderProgressState = .idle
    // internal so tests can await the in-flight job deterministically.
    private(set) var activeRenderTask: Task<Void, Never>?

    private let store: LibraryStore
    private let renderExecution: RenderExecution

    public init(
        store: LibraryStore,
        renderExecution: @escaping RenderExecution = { track, onProgress in
            // Constructed per job so every render reads the current RenderSettings
            // (folder + bitrate) at render time. The Core default names the null
            // engine explicitly — the app overrides this closure to inject the real
            // CustomHTDemucsSeparator (BackbeatCore has no MLX dependency); this
            // default is used only by previews/fallbacks and fails loudly if run.
            try await BoostedDrumsRenderer(separator: UnavailableStemSeparator())
                .render(track: track, progress: onProgress)
        }
    ) {
        self.store = store
        self.renderExecution = renderExecution
    }

    public func enqueue(_ trackID: BackbeatTrack.ID) {
        guard store.track(id: trackID) != nil else { return }
        guard activeTrackID != trackID, !pendingTrackIDs.contains(trackID) else { return }
        pendingTrackIDs.append(trackID)
        startNextIfIdle()
    }

    public func cancel(_ trackID: BackbeatTrack.ID) {
        pendingTrackIDs.removeAll { $0 == trackID }
        if activeTrackID == trackID {
            activeRenderTask?.cancel()
        }
    }

    /// applicationWillTerminate hook: cooperatively cancels the in-flight
    /// in-process render Task (amendment A4 — no subprocess to SIGTERM); the
    /// track's stale `.rendering` status re-enqueues it on the next launch.
    public func cancelActiveForShutdown() {
        activeRenderTask?.cancel()
    }

    /// Launch scan: renders everything imported without both practice files,
    /// plus tracks stuck in `.rendering` from a previous quit or crash.
    public func enqueueMissingRenders() {
        for track in store.tracks {
            switch track.status {
            case .rendering:
                enqueue(track.id)
            case .imported:
                if track.activeRender(for: .drums) == nil || track.activeRender(for: .drumless) == nil {
                    enqueue(track.id)
                }
            case .ready, .renderFailed, .sourceMissing:
                continue
            }
        }
    }

    /// 1-based position among waiting tracks; nil when not queued.
    public func queuePosition(of trackID: BackbeatTrack.ID) -> Int? {
        guard let index = pendingTrackIDs.firstIndex(of: trackID) else { return nil }
        return index + 1
    }

    /// Row/banner copy for a track's place in the render lifecycle.
    public func statusDisplay(for track: BackbeatTrack) -> ProgressStatusDisplay? {
        if activeTrackID == track.id {
            return activeProgress.display
        }
        if let position = queuePosition(of: track.id) {
            return ProgressStatusDisplay(
                kind: .active,
                title: "Waiting to render (#\(position))",
                detail: "Queued for drum separation. The track plays as Original until it finishes."
            )
        }
        if track.status == .renderFailed {
            return RenderProgressState
                .failed(store.renderFailureMessage ?? "The render did not finish.")
                .display
        }
        return nil
    }

    private func startNextIfIdle() {
        guard activeRenderTask == nil else { return }
        guard !pendingTrackIDs.isEmpty else { return }
        let trackID = pendingTrackIDs.removeFirst()
        guard let track = store.track(id: trackID) else {
            startNextIfIdle()
            return
        }

        activeTrackID = trackID
        activeProgress = .separatingStems
        store.beginRendering(for: trackID)

        let execution = renderExecution
        activeRenderTask = Task {
            do {
                let result = try await execution(track) { [weak self] state in
                    await MainActor.run {
                        guard let self, self.activeTrackID == trackID else { return }
                        self.activeProgress = state
                    }
                }
                finishActiveRender(trackID: trackID, outcome: .success(result))
            } catch is CancellationError {
                finishActiveRender(trackID: trackID, outcome: .cancelled)
            } catch {
                finishActiveRender(trackID: trackID, outcome: .failure(error.localizedDescription))
            }
        }
    }

    private enum RenderOutcome {
        case success(PracticeRenderResult)
        case cancelled
        case failure(String)
    }

    private func finishActiveRender(trackID: BackbeatTrack.ID, outcome: RenderOutcome) {
        switch outcome {
        case .success(let result):
            if store.track(id: trackID) == nil {
                // Deleted mid-render: nothing to promote, remove the orphans.
                try? FileManager.default.removeItem(at: result.drumsURL)
                try? FileManager.default.removeItem(at: result.drumlessURL)
            } else {
                store.completePracticeRender(for: trackID, result: result)
            }
        case .cancelled:
            // Deleted-track cancels are no-ops; a shutdown cancel reverts the
            // track so the next launch re-enqueues it.
            store.revertRenderingToImported(for: trackID)
        case .failure(let message):
            if store.track(id: trackID) != nil {
                store.markRenderFailed(for: trackID, message: message)
            }
        }

        activeRenderTask = nil
        activeTrackID = nil
        activeProgress = .idle
        startNextIfIdle()
    }
}
