import SwiftUI

enum GitStatusColor {
    /// Map a git status code to a pill tone so lists retint with the theme.
    static func tone(for status: String) -> StatusPillTone {
        switch status.trimmingCharacters(in: .whitespaces) {
        case "M": return .warning
        case "A": return .success
        case "D", "UU", "AA", "DD": return .danger
        case "R", "C": return .info
        default: return .neutral
        }
    }
}
