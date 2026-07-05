import BackbeatCore
import SwiftUI

struct DrumMixControlsView: View {
    let settings: DrumMixSettings
    let onChange: (Double) -> Void

    // Quantized in the binding (not via Slider step:) so macOS draws no tick marks.
    private var boostBinding: Binding<Double> {
        Binding(
            get: { settings.boostDB },
            set: { onChange(($0 * 10).rounded() / 10) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "drum.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(BackbeatStyle.primary)
                    .accessibilityHidden(true)
                ControlSectionLabel(title: "Drums")
            }

            HStack(spacing: 12) {
                Slider(value: boostBinding, in: 0...8)
                    .accessibilityLabel("Drum boost")

                Text(BackbeatFormat.boost(settings.boostDB))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
                    .foregroundStyle(BackbeatStyle.text)
            }
        }
    }
}
