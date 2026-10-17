import CoreGraphics

/// Showing or hiding the navigation bar resizes the remote terminal, so a
/// history drag must not do it. A pull counts only when it is long enough and
/// mostly vertical. Finger down is show; finger up is hide. The reveal handle
/// commits show only.
enum SSHTerminalTopBarGesture {
    /// Shorter than a nav-bar height. The old 24pt scroll threshold resized
    /// the terminal on an ordinary history nudge.
    static let minimumTravel: CGFloat = 44
    static let dominanceRatio: CGFloat = 1.35

    enum Action: Equatable {
        case show
        case hide
    }

    static func action(translation: CGSize) -> Action? {
        let vertical = translation.height
        guard abs(vertical) >= minimumTravel else { return nil }
        guard abs(vertical) > abs(translation.width) * dominanceRatio else { return nil }
        return vertical > 0 ? .show : .hide
    }
}
