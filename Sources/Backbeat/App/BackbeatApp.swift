import AppKit
import BackbeatCore
import BackbeatSeparationMLX
import SwiftUI

final class BackbeatAppDelegate: NSObject, NSApplicationDelegate {
    var persistLibraryOnTerminate: (@MainActor () -> Void)?
    var stopDebugLogOnTerminate: (@MainActor () -> Void)?
    private var pendingBackgroundSave: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Debounced background library save. The root view's
    /// `.onChange(persistenceSnapshot)` only fires while its window is in the
    /// view hierarchy, so a render completing while the window is closed would
    /// otherwise never be persisted (F8). Mirrors the view's generation-stamped
    /// writer; the shared writer's generation guard makes the two save paths
    /// safe to overlap.
    @MainActor
    func scheduleBackgroundLibrarySave(store: LibraryStore, writer: LibrarySnapshotWriter) {
        pendingBackgroundSave?.cancel()
        let snapshot = LibrarySnapshot(store: store)
        let generation = writer.nextGeneration()
        pendingBackgroundSave = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            do {
                try await Task.detached(priority: .utility) {
                    try writer.write(snapshot, generation: generation)
                }.value
            } catch {
                DebugLog.persistence.error("library.save.background.failed generation=\(generation) error=\(error.localizedDescription, privacy: .public)")
            }
        }
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
    @State private var store: LibraryStore
    @State private var debugLog = DebugLogController()

    @MainActor
    init() {
        let persistence = LibraryPersistence()
        self.persistence = persistence
        self.libraryWriter = LibrarySnapshotWriter(persistence: persistence)
        let store = persistence.loadStoreOrDefault()
        _store = State(initialValue: store)

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
    }

    var body: some Scene {
        WindowGroup {
            BackbeatRootView(store: store, persistence: persistence, libraryWriter: libraryWriter, renderQueue: renderQueue)
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(.dark)
                .onAppear {
                    let store = store
                    let libraryWriter = libraryWriter
                    let renderQueue = renderQueue
                    let debugLog = debugLog
                    debugLog.startIfEnabled()
                    // A render can finish while the window is closed; route its
                    // completion through the delegate's debounced writer so the
                    // change is persisted even with no view observing (F8).
                    renderQueue.onLibraryChanged = { [weak appDelegate] in
                        appDelegate?.scheduleBackgroundLibrarySave(store: store, writer: libraryWriter)
                    }
                    appDelegate.persistLibraryOnTerminate = {
                        // Cancel first: the in-flight in-process render Task is
                        // cancelled cooperatively on quit, and the reverted status
                        // is what gets flushed.
                        renderQueue.cancelActiveForShutdown()
                        let generation = libraryWriter.nextGeneration()
                        do {
                            try libraryWriter.write(LibrarySnapshot(store: store), generation: generation)
                        } catch {
                            // A swallowed terminate-flush failure silently lost
                            // the session's final changes; leave a trace (F12).
                            DebugLog.persistence.error("library.save.terminate.failed error=\(error.localizedDescription, privacy: .public)")
                        }
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
