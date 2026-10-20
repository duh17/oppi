import UIKit

extension UIFont {
    /// A text style's system font at `weight`, scaled from the style's default
    /// size so it follows Dynamic Type (labels that adjust for content size keep
    /// it current). `monospacedDigits` gives digits one width: counts, costs,
    /// times, versions. Cached per text size, since list rows ask for the same
    /// few fonts while they scroll.
    @MainActor
    static func scaled(_ style: TextStyle, _ weight: Weight = .regular, monospacedDigits: Bool = false) -> UIFont {
        scaled(style, weight, design: monospacedDigits ? .monospacedDigits : .proportional)
    }

    /// `scaled(style, weight)` in the monospaced system font: code, paths,
    /// shell output.
    @MainActor
    static func scaledMonospaced(_ style: TextStyle, _ weight: Weight = .regular) -> UIFont {
        scaled(style, weight, design: .monospaced)
    }

    private enum ScaledDesign: String {
        case proportional, monospacedDigits, monospaced
    }

    @MainActor
    private static func scaled(_ style: TextStyle, _ weight: Weight, design: ScaledDesign) -> UIFont {
        let category = UIApplication.shared.preferredContentSizeCategory
        if category != ScaledFontCache.category {
            ScaledFontCache.category = category
            ScaledFontCache.fonts.removeAll()
        }
        let key = "\(style.rawValue)|\(weight.rawValue)|\(design.rawValue)"
        if let font = ScaledFontCache.fonts[key] { return font }
        let size = UIFont.preferredFont(
            forTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
        let base = switch design {
        case .proportional: UIFont.systemFont(ofSize: size, weight: weight)
        case .monospacedDigits: UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        case .monospaced: UIFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
        let font = UIFontMetrics(forTextStyle: style).scaledFont(for: base)
        ScaledFontCache.fonts[key] = font
        return font
    }
}

extension UIImage {
    /// An SF Symbol sized and weighted like `UIFont.scaled(style, weight)`:
    /// drawn in `color` when given, else a template for the view's tint.
    @MainActor
    static func scaledSymbol(
        _ name: String,
        style: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        color: UIColor? = nil
    ) -> UIImage? {
        let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(font: .scaled(style, weight)))
        guard let color else { return image }
        return image?.withTintColor(color, renderingMode: .alwaysOriginal)
    }
}

@MainActor
private enum ScaledFontCache {
    static var category: UIContentSizeCategory?
    static var fonts: [String: UIFont] = [:]
}
