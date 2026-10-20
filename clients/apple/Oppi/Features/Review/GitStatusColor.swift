import UIKit

enum GitStatusColor {
    /// The theme color of a Git status code's pill, so lists retint with the theme.
    static func color(for status: String, palette: ThemePalette) -> UIColor {
        switch status.trimmingCharacters(in: .whitespaces) {
        case "M": UIColor(palette.orange)
        case "A": UIColor(palette.green)
        case "D", "UU", "AA", "DD": UIColor(palette.red)
        case "R", "C": UIColor(palette.cyan)
        default: UIColor(palette.comment)
        }
    }
}
