import Foundation

/// Spinner animation style for the working indicator.
enum SpinnerStyle: String, CaseIterable, Sendable {
    case brailleDots
    case gameOfLife

    var displayName: String {
        switch self {
        case .brailleDots: return "Pi"
        case .gameOfLife: return "GoL"
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
