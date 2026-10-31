import UIKit

// The theme store's UIKit face. iOS only: OppiMac compiles `ThemeStore.swift`
// but not this file. It names no SwiftUI type, so it needs no `import SwiftUI`.
extension ThemeStore {
    /// The theme's color scheme for UIKit. System mode leaves it unspecified.
    var userInterfaceStyle: UIUserInterfaceStyle {
        guard let scheme = preferredColorScheme else { return .unspecified }
        return scheme == .dark ? .dark : .light
    }

    /// The theme's page background, for UIKit containers around hosted screens.
    var backgroundColor: UIColor {
        activeThemeID.palette.ui.bg
    }

    /// System mode follows the window's appearance; other modes ignore it.
    func followSystemAppearance(_ style: UIUserInterfaceStyle) {
        guard mode == .system, style != .unspecified else { return }
        updateSystemColorScheme(style == .dark ? .dark : .light)
    }
}
