import UIKit

/// Paints the chrome the reader floats over a body that draws its own paper: the
/// bar's items, the floating pills, and the fill behind a pill.
///
/// The bar's items and the pills are built from the app palette, so a book on a
/// light paper would carry light glyphs on cream. Here they are set again in the
/// page's ink, and a pill takes the page's paper as its fill.
///
/// A body that keeps the app's reader background passes no surface, and the app
/// theme's chrome is written back, so nothing changes for it.
@MainActor
enum ReaderChromeSurfacePainter {
    static func paint(
        _ surface: ReaderContentSurface?,
        palette: ThemePalette,
        buttons: [UIButton?],
        bar: UINavigationBar?,
        items: [UIBarButtonItem]
    ) {
        for button in buttons.compactMap({ $0 }) {
            var config = button.configuration ?? .plain()
            if let surface {
                config.background.backgroundColor = surface.paper.withAlphaComponent(0.94)
                config.background.strokeColor = surface.ink.withAlphaComponent(0.16)
                config.background.strokeWidth = 0.5
                config.baseForegroundColor = surface.ink
                // A glass pill draws its symbol from the glass, not from the
                // configuration's foreground, so the page's ink is painted into
                // the image itself.
                config.image = config.image?.withTintColor(surface.ink, renderingMode: .alwaysOriginal)
            } else {
                FullScreenFloatingControlChrome.applyGlassBackground(to: &config, palette: palette)
                config.background.strokeColor = nil
                config.background.strokeWidth = 0
                config.image = config.image?.withRenderingMode(.alwaysTemplate)
            }
            button.configuration = config
            // A glass pill draws its glyph in the style it was built in, so the
            // pill follows the page's own light: a cream page gets the light
            // style's dark glyph, a black page the dark style's light one.
            button.overrideUserInterfaceStyle = surface.map { Self.isLight($0.paper) ? .light : .dark }
                ?? .unspecified
        }
        // A bar item's glyph on a Liquid Glass bar is drawn from tint, which the
        // glass does not always honour for a template image; an original-colour
        // image carries the ink whatever the bar decides.
        for item in items {
            item.tintColor = surface?.ink
            guard let image = item.image else { continue }
            item.image = surface.map {
                image.withTintColor($0.ink, renderingMode: .alwaysOriginal)
            } ?? image.withRenderingMode(.alwaysTemplate)
        }
        bar?.tintColor = surface?.ink
        bar?.overrideUserInterfaceStyle = surface.map { Self.isLight($0.paper) ? .light : .dark }
            ?? .unspecified
    }

    /// Whether a paper reads as light, by its perceived luminance.
    private static func isLight(_ color: UIColor) -> Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.5
    }
}
