import UIKit

/// A theme token's color value: `UIColor`.
///
/// The palette, the theme, and the contrast rules carry these, so no theme file
/// imports SwiftUI, and a UIKit call site converts nothing: a palette token is
/// already a `UIColor`. `palette.ui` (`ThemeUIKitPalette`) is the palette's
/// cached UIKit face, which adds the derived translucent tokens and the surface
/// roles.
typealias ThemeColor = UIColor

extension UIColor {
    /// An sRGB token from components. The one constructor the shared theme
    /// files use, so `ThemePalettes`, `RemoteTheme`, and `ThemeContrast` build
    /// a token the same way.
    static func themeSRGB(_ red: Double, _ green: Double, _ blue: Double, alpha: Double = 1) -> UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// The token with its own alpha multiplied by `value`: the rule for a token
    /// derived from another one (`ThemeSurfaceStyle`'s fills, `AppTheme`'s diff
    /// washes, `RemoteTheme`'s fallbacks). A UIKit call site painting its own
    /// translucent colour uses `withAlphaComponent`.
    func multiplyingAlpha(_ value: Double) -> UIColor {
        withAlphaComponent(cgColor.alpha * CGFloat(value))
    }

    /// The token's straight sRGB components, for the contrast solvers. Nil when
    /// the color cannot be read in sRGB.
    func themeRGBComponents() -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return (Double(red), Double(green), Double(blue), Double(alpha))
    }

    /// The token's CGColor; a theme token is always an sRGB value.
    var themeCGColor: CGColor { cgColor }
}
