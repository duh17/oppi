import SwiftUI

struct FreshnessChip: View {
    let state: FreshnessState
    let label: String

    private var tint: Color {
        switch state {
        case .live:
            return .themeGreen
        case .syncing:
            return .themeBlue
        case .offline:
            return .themeRed
        case .stale:
            return .themeOrange
        }
    }

    private var icon: String {
        switch state {
        case .live:
            return "checkmark.circle.fill"
        case .syncing:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .offline:
            return "wifi.slash"
        case .stale:
            return "clock.badge.exclamationmark"
        }
    }

    private var displayLabel: String {
        guard label.hasPrefix("Updated ") else { return label }
        return String(label.dropFirst("Updated ".count))
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)

            Text(displayLabel)
                .font(.caption2)
                .foregroundStyle(.themeComment)
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.45), in: Capsule())
        .accessibilityLabel("\(state.accessibilityText). \(label)")
    }
}
