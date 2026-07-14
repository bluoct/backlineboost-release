import AppKit
import BackbeatCore
import BackbeatSeparationMLX
import SwiftUI

final class BackbeatAppDelegate: NSObject, NSApplicationDelegate {
    var persistLibraryOnTerminate: (@MainActor () -> Void)?
    var stopDebugLogOnTerminate: (@MainActor () -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Library saves are debounced; flush the latest state so quitting inside
    // the debounce window cannot drop the final change.
    func applicationWillTerminate(_ notification: Notification) {
        persistLibraryOnTerminate?()
        stopDebugLogOnTerminate?()
    }
}

@main
struct BackbeatApp: App {
    @NSApplicationDelegateAdaptor(BackbeatAppDelegate.self) private var appDelegate
    private let persistence: LibraryPersistence
    private let libraryWriter: LibrarySnapshotWriter
    private let renderQueue: RenderQueueCoordinator
    private let loudnessQueue: LoudnessAnalysisQueue
    @State private var store: LibraryStore
    @State private var persistenceCoordinator: LibraryPersistenceCoordinator
    @State private var debugLog = DebugLogController()

    @MainActor
    init() {
        let persistence = LibraryPersistence()
        self.persistence = persistence
        self.libraryWriter = LibrarySnapshotWriter(persistence: persistence)
        let store = persistence.loadStoreOrDefault()
        _store = State(initialValue: store)

        let coordinator = LibraryPersistenceCoordinator(writer: self.libraryWriter, makeSnapshot: { LibrarySnapshot(store: store) })
        _persistenceCoordinator = State(initialValue: coordinator)

        // One shared native engine for the whole session: the actor keeps its
        // converted-model graph across jobs (the serial FIFO queue means jobs never
        // overlap), and BoostedDrumsRenderer is rebuilt per job only to re-read the
        // current RenderSettings. Injecting it here is the single point where the app
        // (which depends on the MLX target) hands the engine to BackbeatCore.
        let separator = CustomHTDemucsSeparator()
        self.renderQueue = RenderQueueCoordinator(store: store) { track, onProgress in
            try await BoostedDrumsRenderer(separator: separator)
                .render(track: track, progress: onProgress)
        }
        // A render can finish while the window is closed; route its
        // completion through the coordinator so the change is persisted even
        // with no view observing (F8). Wired here rather than in .onAppear so
        // it's tied to the process lifetime, not the window's.
        self.renderQueue.onLibraryChanged = { coordinator.noteLibraryChanged() }

        self.loudnessQueue = LoudnessAnalysisQueue(
            analyze: { item in
                try await TrackLoudnessAnalyzer(settings: item.settings).analyze(sourceURL: item.sourceURL)
            },
            commit: { trackID, profile in
                store.setLoudnessProfile(profile, for: trackID)
                coordinator.noteLibraryChanged()
            }
        )
    }

    var body: some Scene {
        // A single Window scene, never a window group: one library session must
        // have exactly one playback/import owner (D-103).
        Window("Backline Boost", id: "main") {
            BackbeatRootView(
                store: store,
                persistence: persistence,
                libraryWriter: libraryWriter,
                renderQueue: renderQueue,
                persistenceCoordinator: persistenceCoordinator,
                loudnessAnalysisQueue: loudnessQueue
            )
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(.dark)
                .onAppear {
                    let store = store
                    let renderQueue = renderQueue
                    let persistenceCoordinator = persistenceCoordinator
                    let debugLog = debugLog
                    debugLog.startIfEnabled()
                    // In-session recovery must start the replacement render now, not on the
                    // next launch — the controller has no queue reference (COR-004).
                    store.onRenderRecoveryNeeded = { [weak renderQueue] trackID in
                        renderQueue?.enqueue(trackID)
                    }
                    appDelegate.persistLibraryOnTerminate = {
                        // Cancel first: the in-flight in-process render Task is
                        // cancelled cooperatively on quit, and the reverted status
                        // is what gets flushed.
                        renderQueue.cancelActiveForShutdown()
                        persistenceCoordinator.flushForTermination()
                    }
                    appDelegate.stopDebugLogOnTerminate = {
                        debugLog.shutdown()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            BackbeatHelpCommands()
        }

        Window(BackbeatHelpWindow.title, id: BackbeatHelpWindow.id) {
            BackbeatHelpView()
        }
        .defaultSize(width: 940, height: 720)

        Settings {
            BackbeatSettingsView(store: store, debugLog: debugLog)
                .preferredColorScheme(.dark)
        }
    }
}
