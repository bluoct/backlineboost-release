import BackbeatCore
import Foundation
import SwiftUI

// The bottom practice card: Drums / Loop / Speed columns, plus the section
// loop editor when that mode is active. The drums column is injected by
// PlayerView so this card owns only practice state.
struct PracticeControlsView<DrumsContent: View>: View {
    let store: LibraryStore
    let playback: AudioPlaybackController
    let track: BackbeatTrack
    let progress: Double
    var envelope: WaveformEnvelope?
    var onScrub: (Double) -> Void
    var onMoveLoopStart: (TimeInterval) -> Void
    var onMoveLoopEnd: (TimeInterval) -> Void
    @ViewBuilder var drumsContent: DrumsContent

    // Quantized in the binding (not via Slider step:) so macOS draws no tick marks.
    private var speedBinding: Binding<Double> {
        Binding(
            get: { store.practiceSpeed },
            set: { playback.setPracticeSpeed(($0 * 100).rounded() / 100, track: track, store: store) }
        )
    }

    private var loopModeBinding: Binding<PracticeLoopMode> {
        Binding(
            get: { store.practiceLoopMode },
            set: { playback.setPracticeLoopMode($0, track: track, store: store) }
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                drumsContent
                    .frame(maxWidth: .infinity, alignment: .leading)

                columnDivider

                loopColumn
                    .frame(maxWidth: .infinity, alignment: .leading)

                columnDivider

                speedColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if store.practiceLoopMode == .section {
                sectionLoopEditor
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(BackbeatStyle.panel.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(BackbeatStyle.border.opacity(0.8), lineWidth: 1)
        }
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(BackbeatStyle.border.opacity(0.6))
            .frame(width: 1, height: 46)
    }

    private var loopColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            ControlSectionLabel(title: "Loop")

            HStack(spacing: 8) {
                Picker("Loop", selection: loopModeBinding) {
                    ForEach(PracticeLoopMode.allCases, id: \.self) { mode in
                        Text(mode.controlLabel).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if store.practiceLoopMode != .off {
                    Button {
                        playback.clearPracticeLoop(track: track, store: store)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(BackbeatStyle.secondaryText)
                    .accessibilityLabel("Clear loop markers")
                    .help("Clear loop markers")
                }
            }
        }
    }

    private var speedColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            ControlSectionLabel(title: "Speed")

            HStack(spacing: 7) {
                Button {
                    changePracticeSpeed(by: -0.05)
                } label: {
                    Image(systemName: "tortoise.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Slower")
                .help("Slower")

                Slider(value: speedBinding, in: 0.5...1.5)
                    .simultaneousGesture(
                        TapGesture(count: 2)
                            .onEnded {
                                playback.setPracticeSpeed(1, track: track, store: store)
                            }
                    )

                Button {
                    changePracticeSpeed(by: 0.05)
                } label: {
                    Image(systemName: "hare.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Faster")
                .help("Faster")

                Text(String(format: "%.2f×", store.practiceSpeed))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(BackbeatStyle.text)
                    .frame(width: 44, alignment: .trailing)

                Button("Reset") {
                    playback.setPracticeSpeed(1, track: track, store: store)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BackbeatStyle.secondaryText)
                .accessibilityLabel("Reset speed")
                .help("Reset speed to 1.00×")
            }
            .foregroundStyle(BackbeatStyle.secondaryText)
        }
    }

    private var sectionLoopEditor: some View {
        VStack(spacing: 8) {
            LoopTimelineView(
                progress: progress,
                duration: track.duration,
                loopRange: store.practiceLoopRange,
                envelope: envelope,
                showsWaveform: true,
                height: 46,
                onScrub: onScrub,
                onMoveLoopStart: onMoveLoopStart,
                onMoveLoopEnd: onMoveLoopEnd
            )

            HStack(spacing: 10) {
                markerButton("A") {
                    playback.setPracticeLoopStart(store.playbackElapsed, track: track, store: store)
                }
                Text(store.practiceLoopRange.map { BackbeatFormat.duration($0.start) } ?? "0:00")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(BackbeatStyle.secondaryText)
                markerButton("B") {
                    playback.setPracticeLoopEnd(store.playbackElapsed, track: track, store: store)
                }
                Text(store.practiceLoopRange.map { BackbeatFormat.duration($0.end) } ?? "0:00")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(BackbeatStyle.secondaryText)
                Spacer()
            }
        }
    }

    private func markerButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .frame(width: 26, height: 24)
        }
        .buttonStyle(BackbeatButtonStyle(variant: .ghost))
    }

    private func changePracticeSpeed(by delta: Double) {
        playback.stepPracticeSpeed(by: delta, track: track, store: store)
    }
}

private extension PracticeLoopMode {
    var controlLabel: String {
        switch self {
        case .off:
            "Off"
        case .song:
            "Song"
        case .section:
            "Section"
        }
    }
}
