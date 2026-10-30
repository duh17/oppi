import UIKit

/// Session-status palette for iOS session rows, pills, and thread graphs:
/// working = blue, blocked (every kind) = orange, error and done = red and
/// green while unseen, idle = neutral grey, stopped = tertiary grey.
extension SessionStatusKind {
    func tint(_ theme: AppTheme) -> UIColor {
        switch self {
        case .working: UIColor(theme.accent.blue)
        case .needsApproval, .question, .signIn: UIColor(theme.accent.orange)
        case .error: UIColor(theme.accent.red)
        case .done: UIColor(theme.accent.green)
        case .idle: UIColor(theme.text.secondary)
        case .stopped: UIColor(theme.text.tertiary)
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

    /// Toolbar and terminal glyph. No border: the bar already contains it.
    /// Session rows keep `badgeSymbol`.
    var terminalSymbol: String {
        switch self {
        case .working: "progress.indicator"
        case .needsApproval: "hand.raised.fill"
        case .question: "questionmark.bubble.fill"
        case .signIn: "lock.fill"
        case .error: "exclamationmark.triangle.fill"
        case .done: "checkmark"
        case .idle: "circle.fill"
        case .stopped: "stop.fill"
        }
    }
}
