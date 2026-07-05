import AppKit
import SwiftUI

/// Loads the bundled app-icon PNG once so the UI can show the real brand mark
/// (sidebar logo, artwork-less track tiles, empty states) instead of generic
/// placeholders. Resolution mirrors `BackbeatHelpWindow.indexURL`: the built
/// `.app` copies the asset into `Contents/Resources`, while `swift run`
/// resolves it through the SwiftPM resource bundle.
enum BackbeatBrandIcon {
    private static let resourceName = "BackbeatIcon"
    private static let resourceExtension = "png"

    static let image: NSImage? = loadImage()

    private static func loadImage() -> NSImage? {
        if let bundledURL = Bundle.main.resourceURL?
            .appendingPathComponent("\(resourceName).\(resourceExtension)", isDirectory: false),
            FileManager.default.fileExists(atPath: bundledURL.path),
            let image = NSImage(contentsOf: bundledURL)
        {
            return image
        }

        guard let moduleURL = Bundle.module.url(
            forResource: resourceName,
            withExtension: resourceExtension,
            subdirectory: "Resources"
        ) else {
            return nil
        }
        return NSImage(contentsOf: moduleURL)
    }
}

/// A rounded tile showing the app icon inset on a dark background — the shared
/// branded placeholder for the sidebar logo and the empty-state graphics. If
/// the icon asset is unavailable it degrades to `fallbackSystemImage`.
struct AppIconBadge: View {
    var size: CGFloat
    var cornerRadius: CGFloat
    var insetRatio: CGFloat = 0.16
    var background: Color = BackbeatStyle.panelRaised
    var fallbackSystemImage: String? = nil
    var fallbackTint: Color = BackbeatStyle.primary

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(background)
            .overlay { markContent }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var markContent: some View {
        if let icon = BackbeatBrandIcon.image {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(size * insetRatio)
        } else if let fallbackSystemImage {
            Image(systemName: fallbackSystemImage)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(fallbackTint)
        }
    }
}
