import AppKit
import SwiftUI

/// A theme token's type on the Mac: SwiftUI's `Color`.
///
/// iOS makes the same name `UIColor` (`Oppi/Core/Theme/ThemeColor.swift`), so
/// the shared theme files carry tokens through this alias and never name a
/// framework color type. The Mac reads `\.theme` (see `Theme+SwiftUI.swift`),
/// so the palette, the theme, and the contrast rules hand SwiftUI the colors it
/// draws with, unchanged from before the split.
typealias ThemeColor = Color

extension Color {
    /// An sRGB token from components. The one constructor the shared theme
    /// files use, so `ThemePalettes`, `RemoteTheme`, and `ThemeContrast` build
    /// a token the same way on both platforms.
    static func themeSRGB(_ red: Double, _ green: Double, _ blue: Double, alpha: Double = 1) -> Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// The token with its own alpha multiplied by `value`.
    ///
    /// `opacity` already multiplies, which is what the iOS adapter's
    /// `multiplyingAlpha` does on top of `withAlphaComponent`.
    func multiplyingAlpha(_ value: Double) -> Color {
        opacity(value)
    }

    /// The token's CGColor. Non-optional on both platforms: `Color.cgColor` can
    /// be nil for a color outside any color space, and a theme token is always
    /// an sRGB value.
    var themeCGColor: CGColor { cgColor ?? CGColor(gray: 0.5, alpha: 1) }

    /// The token's straight sRGB components, for the contrast solvers. Nil when
    /// the color cannot be read in sRGB.
    func themeRGBComponents() -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return (
            Double(srgb.redComponent),
            Double(srgb.greenComponent),
            Double(srgb.blueComponent),
            Double(srgb.alphaComponent)
        )
    }
}
