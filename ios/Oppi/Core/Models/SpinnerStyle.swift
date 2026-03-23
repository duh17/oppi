import Foundation

/// Spinner animation style for the working indicator.
enum SpinnerStyle: String, CaseIterable, Sendable {
    case brailleDots
    case gameOfLife

    var displayName: String {
        switch self {
        case .brailleDots: return "Braille Dots"
        case .gameOfLife: return "Game of Life"
        }
    }

    /// Current spinner style from preferences.
    static var current: Self {
        AppPreferences.Appearance.spinnerStyle
    }

    /// Persist a new spinner style preference.
    static func setCurrent(_ style: SpinnerStyle) {
        AppPreferences.Appearance.setSpinnerStyle(style)
    }
}
