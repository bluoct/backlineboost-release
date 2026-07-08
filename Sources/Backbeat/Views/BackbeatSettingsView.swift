import AppKit
import BackbeatCore
import SwiftUI

struct BackbeatSettingsView: View {
    @Bindable var store: LibraryStore
    let debugLog: DebugLogController
    @State private var rendersFolderOverride: URL? = RenderSettings.configuredRendersFolder()
    @State private var renderBitrate: RenderBitrate = RenderSettings.bitrate()

    var body: some View {
        Form {
            Section("Playback") {
                Toggle(
                    "Normalize playback volume",
                    isOn: Binding(
                        get: { store.playbackNormalizationSettings.isEnabled },
                        set: { store.setPlaybackNormalizationEnabled($0) }
                    )
                )
                Text("Boosts quieter songs and lightly reins in very loud songs during playback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Rendering") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(displayedRendersFolder.path)
                            .font(.system(size: 12, design: .monospaced))
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .help(displayedRendersFolder.path)
                        Spacer()
                        Button("Choose…") { chooseRendersFolder() }
                        if rendersFolderOverride != nil {
                            Button("Reset to Default") {
                                RenderSettings.setConfiguredRendersFolder(nil)
                                rendersFolderOverride = nil
                            }
                        }
                    }
                    Text(rendersFolderCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Render quality", selection: $renderBitrate) {
                        ForEach(RenderBitrate.allCases) { bitrate in
                            Text(bitrate.displayLabel).tag(bitrate)
                        }
                    }
                    .onChange(of: renderBitrate) { _, newValue in
                        RenderSettings.setBitrate(newValue)
                    }
                    Text("Applies to new renders only. Already-rendered tracks are unchanged until re-rendered.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Diagnostics") {
                Toggle(
                    "Write debug log",
                    isOn: Binding(
                        get: { debugLog.isEnabled },
                        set: { debugLog.setEnabled($0) }
                    )
                )
                HStack(spacing: 8) {
                    Text(debugLog.logFilePath)
                        .font(.system(size: 12, design: .monospaced))
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .help(debugLog.logFilePath)
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([debugLog.logFileURL])
                    }
                    .disabled(!debugLog.logFileExists)
                }
                Text("Captures the app's full system log to debug.log while enabled. Turn it on, reproduce the issue, then share the file. The capture restarts (and the file is overwritten) each time the app launches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 480)
    }

    private var displayedRendersFolder: URL {
        rendersFolderOverride ?? BackbeatFileLocations.renderRootDirectory
    }

    private var rendersFolderCaption: String {
        guard let override = rendersFolderOverride else {
            return "Drums and Drumless files are saved in subfolders here."
        }
        if RenderSettings.effectiveRendersRootURL() == override {
            return "Drums and Drumless files are saved in subfolders here. Existing rendered tracks keep playing from their current location; re-render a track to move it."
        }
        return "Folder is currently unavailable — new renders go to the default location until it returns."
    }

    private func chooseRendersFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = RenderSettings.effectiveRendersRootURL()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        RenderSettings.setConfiguredRendersFolder(url)
        rendersFolderOverride = url
    }
}
