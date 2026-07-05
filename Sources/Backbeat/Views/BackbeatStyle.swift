import AppKit
import BackbeatCore
import SwiftUI

enum BackbeatStyle {
    static let appBackground = Color(red: 0.05, green: 0.045, blue: 0.035)
    static let sidebarBackground = Color(red: 0.065, green: 0.055, blue: 0.045)
    static let panel = Color(red: 0.075, green: 0.065, blue: 0.05)
    static let panelRaised = Color(red: 0.095, green: 0.08, blue: 0.065)
    static let border = Color(red: 0.17, green: 0.135, blue: 0.095)
    static let primary = Color(red: 0.96, green: 0.64, blue: 0.14)
    static let primaryDeep = Color(red: 0.79, green: 0.39, blue: 0.10)
    static let text = Color(red: 0.95, green: 0.92, blue: 0.86)
    static let secondaryText = Color(red: 0.56, green: 0.52, blue: 0.46)
    static let mutedText = Color(red: 0.36, green: 0.33, blue: 0.29)
    static let ready = Color(red: 0.42, green: 0.75, blue: 0.29)
    static let failure = Color(red: 0.88, green: 0.33, blue: 0.25)

    static func statusColor(_ status: TrackStatus) -> Color {
        switch status {
        case .ready:
            ready
        case .renderFailed:
            failure
        case .sourceMissing:
            Color(red: 0.76, green: 0.39, blue: 0.16)
        case .rendering:
            primary
        case .imported:
            secondaryText
        }
    }

    static func tileColor(index: Int) -> Color {
        let colors: [Color] = [
            primary,
            Color(red: 0.88, green: 0.44, blue: 0.36),
            Color(red: 0.42, green: 0.75, blue: 0.29),
            Color(red: 0.79, green: 0.54, blue: 0.35),
            Color(red: 0.84, green: 0.70, blue: 0.29),
            Color(red: 0.88, green: 0.57, blue: 0.35),
            Color(red: 0.66, green: 0.54, blue: 0.42),
            secondaryText
        ]
        return colors[index % colors.count]
    }
}
struct TrackTile: View {
    let track: BackbeatTrack
    let index: Int
    var size: CGFloat = 42
    var fontSize: CGFloat = 16

    var body: some View {
        let artworkImage = cachedArtworkImage
        ZStack {
            if let artworkImage {
                Image(nsImage: artworkImage)
                    .resizable()
                    .scaledToFill()
            } else if let brandIcon = BackbeatBrandIcon.image {
                BackbeatStyle.panelRaised
                Image(nsImage: brandIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.12)
            } else {
                BackbeatStyle.tileColor(index: index)
                Text(String(track.title.prefix(1)).uppercased())
                    .font(.system(size: fontSize, weight: .black, design: .rounded))
                    .foregroundStyle(BackbeatStyle.appBackground.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .stroke(.white.opacity(artworkImage == nil ? 0 : 0.12), lineWidth: 1)
        }
    }

    private var cachedArtworkImage: NSImage? {
        guard let artworkURL = track.artworkURL else { return nil }
        return ArtworkImageCache.image(for: artworkURL)
    }
}

struct ControlSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(BackbeatStyle.secondaryText)
    }
}

struct StatusDot: View {
    let status: TrackStatus

    var body: some View {
        Circle()
            .fill(BackbeatStyle.statusColor(status))
            .frame(width: 8, height: 8)
    }
}

struct StatusPill: View {
    let status: TrackStatus

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: status)
            Text(status.displayLabel)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(BackbeatStyle.statusColor(status))
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(BackbeatStyle.statusColor(status).opacity(0.08), in: Capsule())
        .overlay {
            Capsule()
                .stroke(BackbeatStyle.statusColor(status).opacity(0.25), lineWidth: 1)
        }
    }
}

struct VersionTag: View {
    let variant: RenderVariant

    init(variant: RenderVariant = .boostedDrums) {
        self.variant = variant
    }

    var body: some View {
        Text(variant.displayLabel)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(BackbeatStyle.ready)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(BackbeatStyle.ready.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(BackbeatStyle.ready.opacity(0.3), lineWidth: 1)
            }
    }
}

struct BackbeatButtonStyle: ButtonStyle {
    enum Variant {
        case primary
        case ghost
        case icon
    }

    let variant: Variant

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, variant == .icon ? 0 : 13)
            .frame(height: variant == .icon ? 34 : 40)
            .frame(width: variant == .icon ? 34 : nil)
            .background(background(configuration.isPressed), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(border, lineWidth: variant == .primary ? 0 : 1)
            }
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.82 : 1)
    }

    private var foreground: Color {
        switch variant {
        case .primary:
            BackbeatStyle.appBackground
        case .ghost, .icon:
            BackbeatStyle.text
        }
    }

    private func background(_ pressed: Bool) -> Color {
        switch variant {
        case .primary:
            pressed ? BackbeatStyle.primaryDeep : BackbeatStyle.primary
        case .ghost, .icon:
            pressed ? BackbeatStyle.panelRaised : BackbeatStyle.panel
        }
    }

    private var border: Color {
        switch variant {
        case .primary:
            .clear
        case .ghost, .icon:
            BackbeatStyle.border
        }
    }
}

struct PlaybackCircleButton: View {
    let systemName: String
    let size: CGFloat
    var iconSize: CGFloat? = nil
    var fill: Color = BackbeatStyle.primary
    var foreground: Color = BackbeatStyle.appBackground
    var showsProgress = false
    var isDisabled = false
    var accessibilityLabel: String = "Play"
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(fill)

                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foreground)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: iconSize ?? size * 0.38, weight: .bold))
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
        .opacity(isDisabled ? 0.65 : 1)
    }
}
