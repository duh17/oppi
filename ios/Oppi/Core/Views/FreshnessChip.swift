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

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.55), in: Capsule())
        .accessibilityLabel("\(state.accessibilityText). \(label)")
    }
}
