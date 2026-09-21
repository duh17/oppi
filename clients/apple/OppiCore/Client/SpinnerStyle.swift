import Foundation

/// Spinner animation style for the working indicator.
enum SpinnerStyle: String, CaseIterable, Sendable {
    case working
    case searching
    case solving
    case brailleDots
    case gameOfLife

    var displayName: String {
        switch self {
        case .working: return "Working"
        case .searching: return "Searching"
        case .solving: return "Solving"
        case .brailleDots: return "Pi"
        case .gameOfLife: return "GoL"
        }
    }

    /// Current spinner style from the shared preference store.
    static var current: Self {
        AppPreferenceStore.Appearance.spinnerStyle
    }
}
