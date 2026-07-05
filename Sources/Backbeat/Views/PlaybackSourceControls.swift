import BackbeatCore
import SwiftUI

struct PlaybackSourcePicker: View {
    let selection: Binding<PlaybackSource>

    var body: some View {
        Picker("Playback source", selection: selection) {
            ForEach(PlaybackSource.controlCases, id: \.self) { source in
                Text(source.displayLabel)
                    .tag(source)
            }
        }
        .pickerStyle(.segmented)
    }
}

struct PlaybackSourceTag: View {
    let preferredSource: PlaybackSource
    let effectiveSource: PlaybackSource

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: .ready)
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(BackbeatStyle.ready)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(BackbeatStyle.ready.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(BackbeatStyle.ready.opacity(0.32), lineWidth: 1)
        }
    }

    private var label: String {
        if preferredSource == effectiveSource {
            return preferredSource.displayLabel
        }
        return "\(preferredSource.displayLabel) -> \(effectiveSource.displayLabel)"
    }
}
