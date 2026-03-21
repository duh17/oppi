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

    static var current: Self {
        guard let raw = UserDefaults.standard.string(forKey: "spinnerStyle"),
              let style = Self(rawValue: raw) else {
            return .brailleDots
        }
        return style
    }
}
