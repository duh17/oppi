import SwiftUI

/// Legacy color API used throughout the app (`.tokyo*` names).
///
/// Names are preserved for compatibility while values are now resolved from
/// the currently selected runtime theme.
extension Color {
    private static var palette: ThemePalette {
        ThemeRuntimeState.currentPalette()
    }

    static var tokyoBg: Color { palette.bg }
    static var tokyoBgDark: Color { palette.bgDark }
    static var tokyoBgHighlight: Color { palette.bgHighlight }

    static var tokyoFg: Color { palette.fg }
    static var tokyoFgDim: Color { palette.fgDim }
    static var tokyoComment: Color { palette.comment }

    static var tokyoBlue: Color { palette.blue }
    static var tokyoCyan: Color { palette.cyan }
    static var tokyoGreen: Color { palette.green }
    static var tokyoOrange: Color { palette.orange }
    static var tokyoPurple: Color { palette.purple }
    static var tokyoRed: Color { palette.red }
    static var tokyoYellow: Color { palette.yellow }
}

extension ShapeStyle where Self == Color {
    static var tokyoBg: Color { Color.tokyoBg }
    static var tokyoBgDark: Color { Color.tokyoBgDark }
    static var tokyoBgHighlight: Color { Color.tokyoBgHighlight }
    static var tokyoFg: Color { Color.tokyoFg }
    static var tokyoFgDim: Color { Color.tokyoFgDim }
    static var tokyoComment: Color { Color.tokyoComment }
    static var tokyoBlue: Color { Color.tokyoBlue }
    static var tokyoCyan: Color { Color.tokyoCyan }
    static var tokyoGreen: Color { Color.tokyoGreen }
    static var tokyoOrange: Color { Color.tokyoOrange }
    static var tokyoPurple: Color { Color.tokyoPurple }
    static var tokyoRed: Color { Color.tokyoRed }
    static var tokyoYellow: Color { Color.tokyoYellow }
}
