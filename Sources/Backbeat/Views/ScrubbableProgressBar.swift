import BackbeatCore
import SwiftUI

struct ScrubbableProgressBar: View {
    let progress: Double
    var fill: Color = BackbeatStyle.primary
    var track: Color = BackbeatStyle.panelRaised
    var accessibilityLabel = "Playback position"
    var onScrub: (Double) -> Void

    private var clampedProgress: Double {
        min(1, max(0, progress))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(track)
                Capsule()
                    .fill(fill)
                    .frame(width: proxy.size.width * clampedProgress)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onScrub(
                            PlaybackScrubPosition.progress(
                                locationX: value.location.x,
                                width: proxy.size.width
                            )
                        )
                    }
            )
        }
        .frame(height: 10)
        .accessibilityLabel(accessibilityLabel)
    }
}
