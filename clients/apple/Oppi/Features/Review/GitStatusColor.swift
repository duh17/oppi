import SwiftUI

enum GitStatusColor {
    /// Map a git status code to a theme color.
    static func color(for status: String) -> Color {
        switch status.trimmingCharacters(in: .whitespaces) {
        case "M": return .themeOrange
        case "A": return .themeDiffAdded
        case "D": return .themeDiffRemoved
        case "R", "C": return .themeCyan
        case "??": return .themeComment
        case "UU", "AA", "DD": return .themeDiffRemoved
        default: return .themeComment
        }
    }
}
