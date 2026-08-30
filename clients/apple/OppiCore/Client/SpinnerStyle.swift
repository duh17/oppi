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

    /// Current spinner style from the shared preference store.
    static var current: Self {
        AppPreferenceStore.Appearance.spinnerStyle
    }
}
