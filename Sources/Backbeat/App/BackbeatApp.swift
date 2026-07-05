import AppKit
import BackbeatCore
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
    @State private var store: LibraryStore
    @State private var debugLog = DebugLogController()

    @MainActor
    init() {
        let persistence = LibraryPersistence()
        self.persistence = persistence
        self.libraryWriter = LibrarySnapshotWriter(persistence: persistence)
        let store = persistence.loadStoreOrDefault()
        _store = State(initialValue: store)
        self.renderQueue = RenderQueueCoordinator(store: store)
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
                    appDelegate.persistLibraryOnTerminate = {
                        // Cancel first: demucs children are not auto-killed on
                        // quit, and the reverted status is what gets flushed.
                        renderQueue.cancelActiveForShutdown()
                        let generation = libraryWriter.nextGeneration()
                        try? libraryWriter.write(LibrarySnapshot(store: store), generation: generation)
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
