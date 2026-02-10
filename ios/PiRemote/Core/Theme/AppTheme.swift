import SwiftUI
import UIKit

/// Centralized theme definition for the entire app.
///
/// Organizes all visual tokens — colors, code metrics, diff styling —
/// into a single `Sendable` value type. Injected via `@Environment(\.theme)`.
struct AppTheme: Sendable {
    let bg: BgColors
    let text: TextColors
    let accent: AccentColors
    let diff: DiffColors
    let syntax: SyntaxColors
    let code: CodeMetrics

    // MARK: - Color Groups

    struct BgColors: Sendable {
        /// Primary background (main surfaces).
        let primary: Color
        /// Darkest background (code blocks, inset areas).
        let secondary: Color
        /// Elevated/highlighted background (headers, selections).
        let highlight: Color
    }

    struct TextColors: Sendable {
        /// Primary text.
        let primary: Color
        /// Secondary/dimmed text.
        let secondary: Color
        /// Tertiary/muted text (comments, timestamps, placeholders).
        let tertiary: Color
    }

    struct AccentColors: Sendable {
        let blue: Color
        let cyan: Color
        let green: Color
        let orange: Color
        let purple: Color
        let red: Color
        let yellow: Color
    }

    struct DiffColors: Sendable {
        /// Background for added lines.
        let addedBg: Color
        /// Background for removed lines.
        let removedBg: Color
        /// Left accent bar and prefix for added lines.
        let addedAccent: Color
        /// Left accent bar and prefix for removed lines.
        let removedAccent: Color
        /// Context line text color.
        let contextFg: Color
        /// Hunk header color (@@ ... @@).
        let hunkFg: Color
    }

    struct SyntaxColors: Sendable {
        let keyword: Color
        let string: Color
        let comment: Color
        let number: Color
        let type: Color
        let decorator: Color
        let preprocessor: Color
        let plain: Color
        let jsonKey: Color
        let jsonDim: Color
    }

    struct CodeMetrics: Sendable {
        let fontSize: CGFloat
        let gutterWidthPerDigit: CGFloat
    }
}

// MARK: - Theme Variants

extension AppTheme {
    /// Tokyo Night (Night variant) — default app palette.
    static let tokyoNight = makeTheme(
        palette: ThemePalettes.tokyoNight,
        diffAddedBg: Color(red: 30.0 / 255.0, green: 50.0 / 255.0, blue: 40.0 / 255.0),
        diffRemovedBg: Color(red: 58.0 / 255.0, green: 30.0 / 255.0, blue: 40.0 / 255.0),
        diffContextFg: ThemePalettes.tokyoNight.fgDim,
        diffHunkFg: ThemePalettes.tokyoNight.purple
    )

    /// Tokyo Night Day (light variant).
    static let tokyoNightDay = makeTheme(
        palette: ThemePalettes.tokyoNightDay,
        diffAddedBg: Color(red: 213.0 / 255.0, green: 232.0 / 255.0, blue: 213.0 / 255.0),
        diffRemovedBg: Color(red: 232.0 / 255.0, green: 213.0 / 255.0, blue: 213.0 / 255.0),
        diffContextFg: ThemePalettes.tokyoNightDay.fgDim,
        diffHunkFg: ThemePalettes.tokyoNightDay.purple
    )

    /// Apple-native semantic dark palette.
    static let appleDark = makeTheme(
        palette: ThemePalettes.appleDark,
        diffAddedBg: Color(uiColor: UIColor.systemGreen.withAlphaComponent(0.18)),
        diffRemovedBg: Color(uiColor: UIColor.systemRed.withAlphaComponent(0.16)),
        diffContextFg: ThemePalettes.appleDark.fgDim,
        diffHunkFg: ThemePalettes.appleDark.purple
    )

    private static func makeTheme(
        palette: ThemePalette,
        diffAddedBg: Color,
        diffRemovedBg: Color,
        diffContextFg: Color,
        diffHunkFg: Color
    ) -> AppTheme {
        AppTheme(
            bg: BgColors(
                primary: palette.bg,
                secondary: palette.bgDark,
                highlight: palette.bgHighlight
            ),
            text: TextColors(
                primary: palette.fg,
                secondary: palette.fgDim,
                tertiary: palette.comment
            ),
            accent: AccentColors(
                blue: palette.blue,
                cyan: palette.cyan,
                green: palette.green,
                orange: palette.orange,
                purple: palette.purple,
                red: palette.red,
                yellow: palette.yellow
            ),
            diff: DiffColors(
                addedBg: diffAddedBg,
                removedBg: diffRemovedBg,
                addedAccent: palette.green,
                removedAccent: palette.red,
                contextFg: diffContextFg,
                hunkFg: diffHunkFg
            ),
            syntax: SyntaxColors(
                keyword: palette.purple,
                string: palette.green,
                comment: palette.comment,
                number: palette.orange,
                type: palette.cyan,
                decorator: palette.yellow,
                preprocessor: palette.purple,
                plain: palette.fg,
                jsonKey: palette.cyan,
                jsonDim: palette.fgDim
            ),
            code: CodeMetrics(
                fontSize: 11,
                gutterWidthPerDigit: 7.5
            )
        )
    }
}

extension ThemeID {
    var appTheme: AppTheme {
        switch self {
        case .tokyoNight:
            return .tokyoNight
        case .tokyoNightDay:
            return .tokyoNightDay
        case .appleDark:
            return .appleDark
        }
    }
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static var defaultValue: AppTheme {
        ThemeRuntimeState.currentThemeID().appTheme
    }
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
