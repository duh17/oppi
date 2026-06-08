import SwiftUI

struct FreshnessChip: View {
    let state: FreshnessState
    let label: String

    private var tone: StatusPillTone {
        switch state {
        case .live:
            return .success
        case .syncing:
            return .working
        case .offline:
            return .danger
        case .stale:
            return .warning
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
        StatusPill(
            text: displayLabel,
            systemImage: icon,
            tone: tone,
            emphasis: .quiet,
            size: .small,
            monospacedDigit: true,
            accessibilityLabel: "\(state.accessibilityText). \(label)"
        )
    }
}
