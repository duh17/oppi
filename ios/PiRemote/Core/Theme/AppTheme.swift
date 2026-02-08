import SwiftUI

/// Centralized theme definition for the entire app.
///
/// Organizes all visual tokens — colors, code metrics, diff styling —
/// into a single `Sendable` value type. Injected via `@Environment(\.theme)`.
///
/// Current theme: Tokyo Night.
/// To add a new theme, create a new `AppTheme` static instance and
/// set it on the root view via `.environment(\.theme, .newTheme)`.
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

// MARK: - Tokyo Night

extension AppTheme {
    /// Tokyo Night (Night variant) — the default theme.
    static let tokyoNight = AppTheme(
        bg: BgColors(
            primary: .tokyoBg,
            secondary: .tokyoBgDark,
            highlight: .tokyoBgHighlight
        ),
        text: TextColors(
            primary: .tokyoFg,
            secondary: .tokyoFgDim,
            tertiary: .tokyoComment
        ),
        accent: AccentColors(
            blue: .tokyoBlue,
            cyan: .tokyoCyan,
            green: .tokyoGreen,
            orange: .tokyoOrange,
            purple: .tokyoPurple,
            red: .tokyoRed,
            yellow: .tokyoYellow
        ),
        diff: DiffColors(
            // Subtle green tint over the Night bg (#1a1b26)
            addedBg: Color(red: 30 / 255, green: 50 / 255, blue: 40 / 255),
            // Subtle red tint over the Night bg
            removedBg: Color(red: 58 / 255, green: 30 / 255, blue: 40 / 255),
            addedAccent: .tokyoGreen,
            removedAccent: .tokyoRed,
            contextFg: .tokyoFgDim,
            hunkFg: .tokyoPurple
        ),
        syntax: SyntaxColors(
            keyword: .tokyoPurple,
            string: .tokyoGreen,
            comment: .tokyoComment,
            number: .tokyoOrange,
            type: .tokyoCyan,
            decorator: .tokyoYellow,
            preprocessor: .tokyoPurple,
            plain: .tokyoFg,
            jsonKey: .tokyoCyan,
            jsonDim: .tokyoFgDim
        ),
        code: CodeMetrics(
            fontSize: 11,
            gutterWidthPerDigit: 7.5
        )
    )
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .tokyoNight
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
