import SwiftUI
import WebKit

enum BackbeatHelpWindow {
    static let id = "backbeat-help"
    static let title = "Backline Boost Help"

    private static let folderName = "Help"
    private static let indexFileName = "index.html"

    static func indexURL(bundle: Bundle = .main) -> URL? {
        if let appBundleURL = bundle.resourceURL?
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(indexFileName, isDirectory: false),
            FileManager.default.fileExists(atPath: appBundleURL.path)
        {
            return appBundleURL
        }

        return Bundle.module.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "Resources/Help"
        )
    }
}

struct BackbeatHelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Backline Boost Help") {
                openWindow(id: BackbeatHelpWindow.id)
            }
            .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }
}

struct BackbeatHelpView: View {
    private let helpURL: URL?

    init(helpURL: URL? = BackbeatHelpWindow.indexURL()) {
        self.helpURL = helpURL
    }

    var body: some View {
        Group {
            if let helpURL {
                BackbeatHelpWebView(url: helpURL)
            } else {
                missingHelpView
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private var missingHelpView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Backline Boost Help")
                .font(.largeTitle.weight(.semibold))
            Text("The bundled help file could not be found.")
                .font(.title3)
            Text("Rebuild and launch Backline Boost with `Launch Backline Boost.command` so the app bundle includes `Contents/Resources/Help/index.html`.")
                .font(.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct BackbeatHelpWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}
