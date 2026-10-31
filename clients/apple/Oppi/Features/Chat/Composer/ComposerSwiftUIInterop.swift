import UIKit

// What the UIKit composer takes from the SwiftUI theme types: the palette's
// colors.

extension ComposerThemeColors {
    init(palette: ThemePalette) {
        let elevated = ThemeSurfaceStyle.resolve(.elevatedPanel, palette: palette)
        let floating = ThemeSurfaceStyle.resolve(.floatingControl, palette: palette)
        self.init(
            bg: UIColor(palette.bg),
            bgDark: UIColor(palette.bgDark),
            bgHighlight: UIColor(palette.bgHighlight),
            fg: UIColor(palette.fg),
            fgDim: UIColor(palette.fgDim),
            comment: UIColor(palette.comment),
            blue: UIColor(palette.blue),
            cyan: UIColor(palette.cyan),
            green: UIColor(palette.green),
            orange: UIColor(palette.orange),
            purple: UIColor(palette.purple),
            red: UIColor(palette.red),
            yellow: UIColor(palette.yellow),
            scrim: UIColor(palette.bgDark.opacity(0.82)),
            elevatedStroke: UIColor(elevated.stroke ?? palette.fg.opacity(0.12)),
            floatingFill: UIColor(floating.fill)
        )
    }
}
