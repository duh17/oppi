import UIKit

// What the UIKit composer takes from the SwiftUI theme types: the palette's
// colors.

extension ComposerThemeColors {
    init(palette: ThemePalette) {
        let elevated = ThemeSurfaceStyle.resolve(.elevatedPanel, palette: palette)
        let floating = ThemeSurfaceStyle.resolve(.floatingControl, palette: palette)
        self.init(
            bg: palette.ui.bg,
            bgDark: palette.ui.bgDark,
            bgHighlight: palette.ui.bgHighlight,
            fg: palette.ui.fg,
            fgDim: palette.ui.fgDim,
            comment: palette.ui.comment,
            blue: palette.ui.blue,
            cyan: palette.ui.cyan,
            green: palette.ui.green,
            orange: palette.ui.orange,
            purple: palette.ui.purple,
            red: palette.ui.red,
            yellow: palette.ui.yellow,
            scrim: palette.ui.bgDark.withAlphaComponent(0.82),
            elevatedStroke: elevated.stroke ?? palette.ui.fg.withAlphaComponent(0.12),
            floatingFill: floating.fill
        )
    }
}
