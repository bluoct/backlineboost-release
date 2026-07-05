import BackbeatCore
import SwiftUI

struct ProgressStatusRow: View {
    let display: ProgressStatusDisplay
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            statusSymbol
                .frame(width: 18, height: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(display.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BackbeatStyle.text)
                Text(display.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(BackbeatStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if let actionTitle = display.actionTitle, let action {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(BackbeatButtonStyle(variant: .ghost))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusSymbol: some View {
        switch display.kind {
        case .active:
            ProgressView()
                .controlSize(.small)
                .tint(BackbeatStyle.primary)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BackbeatStyle.ready)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(BackbeatStyle.failure)
        }
    }
}
