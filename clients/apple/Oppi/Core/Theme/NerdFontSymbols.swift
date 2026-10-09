import UIKit

/// Nerd Font icon glyphs (Powerline, devicons, Font Awesome, Octicons,
/// Codicons, Material Design) for terminal prompts and tool output.
///
/// Bundled as Symbols Nerd Font Mono and listed as a cascade fallback behind
/// every code font, so each family shows the icons without a patched copy.
/// UIKit system fonts (SF Mono) ignore a custom cascade list when drawing, so
/// a painter that must show icons with every family draws uncovered
/// private-use characters with `font(size:)`.
enum NerdFontSymbols {
    nonisolated static let postScriptName = "SymbolsNFM"

    nonisolated private static let fallbackDescriptor: UIFontDescriptor? = {
        guard UIFont(name: postScriptName, size: 12) != nil else { return nil }
        return UIFontDescriptor(fontAttributes: [.name: postScriptName])
    }()

    /// The symbols font itself, once registered.
    nonisolated static func font(size: CGFloat) -> UIFont? {
        guard fallbackDescriptor != nil else { return nil }
        return UIFont(name: postScriptName, size: size)
    }

    /// Nerd Font icons live in the Unicode private-use areas.
    nonisolated static func isPrivateUse(_ scalar: Unicode.Scalar) -> Bool {
        (0xE000...0xF8FF).contains(scalar.value) || scalar.value >= 0xF0000
    }

    /// Adds the symbols font as a cascade fallback. Bundled code fonts honor
    /// it in every text view; SF Mono does not.
    nonisolated static func withFallback(_ font: UIFont) -> UIFont {
        guard let symbols = fallbackDescriptor else { return font }
        let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: [symbols]])
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }
}
