import Foundation

// `#RRGGBB` parsing for theme tokens, built through `ThemeColor.themeSRGB`
// (`Oppi/Core/Theme/ThemeColor.swift`).

/// A theme token from a `#RRGGBB` string; nil for an empty string or a shape
/// other than six hex digits.
func themeColor(hex: String) -> ThemeColor? {
    guard let components = themeHexComponents(hex) else { return nil }
    return ThemeColor.themeSRGB(components.red, components.green, components.blue)
}

func themeHexComponents(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
    var str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !str.isEmpty else { return nil }
    if str.hasPrefix("#") { str.removeFirst() }
    guard str.count == 6, let rgb = UInt32(str, radix: 16) else { return nil }
    return (
        red: Double((rgb >> 16) & 0xFF) / 255.0,
        green: Double((rgb >> 8) & 0xFF) / 255.0,
        blue: Double(rgb & 0xFF) / 255.0
    )
}
