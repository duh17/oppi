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
    let thinking: ThinkingColors
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

    struct ThinkingColors: Sendable {
        let off: Color
        let minimal: Color
        let low: Color
        let medium: Color
        let high: Color
        let xhigh: Color

        func color(for level: ThinkingLevel) -> Color {
            switch level {
            case .off: return off
            case .minimal: return minimal
            case .low: return low
            case .medium: return medium
            case .high: return high
            case .xhigh: return xhigh
            }
        }
    }

    struct CodeMetrics: Sendable {
        let fontSize: CGFloat
        let gutterWidthPerDigit: CGFloat
    }
}

// MARK: - Theme Variants

extension AppTheme {
    // Thinking-level colors sourced from pi TUI dark.json (gray → blue → purple ramp).
    private static let piTUIDarkThinking = ThinkingColors(
        off:     Color(red: 0x50 / 255.0, green: 0x50 / 255.0, blue: 0x50 / 255.0), // #505050
        minimal: Color(red: 0x6E / 255.0, green: 0x6E / 255.0, blue: 0x6E / 255.0), // #6E6E6E
        low:     Color(red: 0x5F / 255.0, green: 0x87 / 255.0, blue: 0xAF / 255.0), // #5F87AF
        medium:  Color(red: 0x81 / 255.0, green: 0xA2 / 255.0, blue: 0xBE / 255.0), // #81A2BE
        high:    Color(red: 0xB2 / 255.0, green: 0x94 / 255.0, blue: 0xBB / 255.0), // #B294BB
        xhigh:   Color(red: 0xD1 / 255.0, green: 0x83 / 255.0, blue: 0xE8 / 255.0)  // #D183E8
    )

    // Light variant — darker / more saturated so colors read on white backgrounds.
    private static let piTUILightThinking = ThinkingColors(
        off:     Color(red: 0x90 / 255.0, green: 0x90 / 255.0, blue: 0x90 / 255.0), // #909090
        minimal: Color(red: 0x70 / 255.0, green: 0x70 / 255.0, blue: 0x70 / 255.0), // #707070
        low:     Color(red: 0x3D / 255.0, green: 0x6B / 255.0, blue: 0x8F / 255.0), // #3D6B8F
        medium:  Color(red: 0x4A / 255.0, green: 0x78 / 255.0, blue: 0x9A / 255.0), // #4A789A
        high:    Color(red: 0x7E / 255.0, green: 0x57 / 255.0, blue: 0x9A / 255.0), // #7E579A
        xhigh:   Color(red: 0x9B / 255.0, green: 0x40 / 255.0, blue: 0xC8 / 255.0)  // #9B40C8
    )

    /// Tokyo Night (Night variant) — default app palette.
    static let tokyoNight = makeTheme(
        palette: ThemePalettes.tokyoNight,
        diffAddedBg: Color(red: 30.0 / 255.0, green: 50.0 / 255.0, blue: 40.0 / 255.0),
        diffRemovedBg: Color(red: 58.0 / 255.0, green: 30.0 / 255.0, blue: 40.0 / 255.0),
        diffContextFg: ThemePalettes.tokyoNight.fgDim,
        diffHunkFg: ThemePalettes.tokyoNight.purple,
        thinking: piTUIDarkThinking
    )

    /// Tokyo Night Day (light variant).
    static let tokyoNightDay = makeTheme(
        palette: ThemePalettes.tokyoNightDay,
        diffAddedBg: Color(red: 213.0 / 255.0, green: 232.0 / 255.0, blue: 213.0 / 255.0),
        diffRemovedBg: Color(red: 232.0 / 255.0, green: 213.0 / 255.0, blue: 213.0 / 255.0),
        diffContextFg: ThemePalettes.tokyoNightDay.fgDim,
        diffHunkFg: ThemePalettes.tokyoNightDay.purple,
        thinking: piTUILightThinking
    )

    // Apple Liquid Glass — monochromatic gray → subtle tint progression.
    private static let appleLiquidGlassThinking = ThinkingColors(
        off:     Color(uiColor: .systemGray3),                                           // #48484A
        minimal: Color(uiColor: .systemGray2),                                           // #636366
        low:     Color(red: 110.0 / 255, green: 135.0 / 255, blue: 160.0 / 255),        // #6E87A0
        medium:  Color(red: 130.0 / 255, green: 150.0 / 255, blue: 180.0 / 255),        // #8296B4
        high:    Color(red: 155.0 / 255, green: 145.0 / 255, blue: 185.0 / 255),        // #9B91B9
        xhigh:   Color(red: 175.0 / 255, green: 150.0 / 255, blue: 205.0 / 255)         // #AF96CD
    )

    /// Apple Liquid Glass dark palette — muted, frosted accents.
    static let appleDark = makeTheme(
        palette: ThemePalettes.appleDark,
        diffAddedBg: Color(red: 115.0 / 255, green: 185.0 / 255, blue: 135.0 / 255).opacity(0.12),
        diffRemovedBg: Color(red: 220.0 / 255, green: 110.0 / 255, blue: 115.0 / 255).opacity(0.10),
        diffContextFg: ThemePalettes.appleDark.fgDim,
        diffHunkFg: ThemePalettes.appleDark.purple,
        thinking: appleLiquidGlassThinking
    )

    private static func makeTheme(
        palette: ThemePalette,
        diffAddedBg: Color,
        diffRemovedBg: Color,
        diffContextFg: Color,
        diffHunkFg: Color,
        thinking: ThinkingColors
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
            thinking: thinking,
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
        case .tokyoNight, .tokyoNightStorm, .custom:
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
