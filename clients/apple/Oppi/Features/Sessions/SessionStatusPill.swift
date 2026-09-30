import SwiftUI

typealias SessionPillVariant = SessionRowStatusKind

/// Session-status palette for iOS session rows, pills, and thread graphs:
/// working = blue, done/idle = green, needs you = orange, stopped = grey,
/// error = red.
extension SessionRowStatusKind {
    func tint(_ theme: AppTheme) -> Color {
        switch self {
        case .idle, .done: theme.accent.green
        case .working: theme.accent.blue
        case .question: theme.accent.orange
        case .stopped: theme.text.tertiary
        case .error: theme.accent.red
        }
    }

}

/// Compact text status aligned to the row's trailing edge.
struct SessionStatusPill: View {
    @Environment(\.theme) private var theme

    let variant: SessionPillVariant

    init(_ variant: SessionPillVariant) {
        self.variant = variant
    }

    var body: some View {
        Text(variant.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(variant.tint(theme))
            .multilineTextAlignment(.trailing)
    }
}
