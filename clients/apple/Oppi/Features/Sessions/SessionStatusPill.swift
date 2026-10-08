import SwiftUI

/// Session-status palette for iOS session rows, pills, and thread graphs:
/// working = blue, blocked (every kind) = orange, error and done = red and
/// green while unseen, idle = neutral grey, stopped = tertiary grey.
extension SessionStatusKind {
    func tint(_ theme: AppTheme) -> Color {
        switch self {
        case .working: theme.accent.blue
        case .needsApproval, .question, .signIn: theme.accent.orange
        case .error: theme.accent.red
        case .done: theme.accent.green
        case .idle: theme.text.secondary
        case .stopped: theme.text.tertiary
        }
    }

    /// Row badge symbol for a blocked session; other statuses show none.
    var badgeSymbol: String {
        switch self {
        case .needsApproval: "hand.raised.circle.fill"
        case .signIn: "lock.circle.fill"
        case .question, .working, .error, .done, .idle, .stopped: "questionmark.circle.fill"
        }
    }
}

/// Compact text status aligned to the row's trailing edge.
struct SessionStatusPill: View {
    @Environment(\.theme) private var theme

    let status: SessionStatusKind

    init(_ status: SessionStatusKind) {
        self.status = status
    }

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(status.tint(theme))
            .multilineTextAlignment(.trailing)
    }
}
