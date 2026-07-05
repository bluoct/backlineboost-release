import BackbeatCore
import SwiftUI

struct LoopTimelineView: View {
    let progress: Double
    let duration: TimeInterval
    var loopRange: PracticeLoopRange?
    var envelope: WaveformEnvelope?
    var showsWaveform = false
    var height: CGFloat = 14
    var onScrub: (Double) -> Void
    var onMoveLoopStart: (TimeInterval) -> Void = { _ in }
    var onMoveLoopEnd: (TimeInterval) -> Void = { _ in }

    private var clampedProgress: Double {
        min(1, max(0, progress))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(BackbeatStyle.panelRaised)

                if showsWaveform, let envelope {
                    WaveformEnvelopeShape(envelope: envelope)
                        .fill(BackbeatStyle.secondaryText.opacity(0.38))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 7)
                }

                if let loopRange {
                    Rectangle()
                        .fill(BackbeatStyle.primary.opacity(0.22))
                        .frame(width: rangeWidth(loopRange, width: width))
                        .offset(x: xPosition(for: loopRange.start, width: width))
                }

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(BackbeatStyle.primary.opacity(showsWaveform ? 0.35 : 1))
                    .frame(width: width * clampedProgress)

                if let loopRange {
                    marker(label: "A", elapsed: loopRange.start, width: width, height: proxy.size.height) {
                        onMoveLoopStart($0)
                    }
                    marker(label: "B", elapsed: loopRange.end, width: width, height: proxy.size.height) {
                        onMoveLoopEnd($0)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(BackbeatStyle.border.opacity(0.75), lineWidth: 1)
            }
            .coordinateSpace(name: "LoopTimeline")
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("LoopTimeline"))
                    .onChanged { value in
                        onScrub(progress(at: value.location.x, width: width))
                    }
            )
        }
        .frame(height: height)
        .accessibilityLabel("Practice loop timeline")
    }

    private func marker(
        label: String,
        elapsed: TimeInterval,
        width: CGFloat,
        height: CGFloat,
        onMove: @escaping (TimeInterval) -> Void
    ) -> some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(BackbeatStyle.appBackground)
                .frame(width: 18, height: 18)
                .background(BackbeatStyle.primary, in: Circle())
            Rectangle()
                .fill(BackbeatStyle.primary)
                .frame(width: 2, height: max(0, height - 18))
        }
        .position(x: xPosition(for: elapsed, width: width), y: height / 2)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("LoopTimeline"))
                .onChanged { value in
                    onMove(elapsedTime(at: value.location.x, width: width))
                }
        )
        .accessibilityLabel("Loop marker \(label)")
    }

    private func rangeWidth(_ range: PracticeLoopRange, width: CGFloat) -> CGFloat {
        max(0, xPosition(for: range.end, width: width) - xPosition(for: range.start, width: width))
    }

    private func xPosition(for elapsed: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return width * min(1, max(0, elapsed / duration))
    }

    private func progress(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(1, max(0, Double(x / width)))
    }

    private func elapsedTime(at x: CGFloat, width: CGFloat) -> TimeInterval {
        progress(at: x, width: width) * max(0, duration)
    }
}

struct WaveformEnvelopeShape: Shape {
    let envelope: WaveformEnvelope

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !envelope.bins.isEmpty else { return path }
        let binWidth = rect.width / CGFloat(envelope.bins.count)
        let visibleWidth = max(1, binWidth * 0.72)
        let midpoint = rect.midY

        for index in envelope.bins.indices {
            let amplitude = max(1, CGFloat(envelope.bins[index].amplitude) * rect.height)
            let x = rect.minX + CGFloat(index) * binWidth + (binWidth - visibleWidth) / 2
            let y = midpoint - amplitude / 2
            path.addRoundedRect(
                in: CGRect(x: x, y: y, width: visibleWidth, height: amplitude),
                cornerSize: CGSize(width: 1.5, height: 1.5)
            )
        }

        return path
    }
}
