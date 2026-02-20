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
    let markdown: MarkdownColors
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
        /// Thinking block text.
        let thinking: Color
    }

    struct AccentColors: Sendable {
        /// Primary accent (pi's `accent` token).
        let primary: Color
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
        let function: Color
        let variable: Color
        let `operator`: Color
        let punctuation: Color
        let plain: Color
        // iOS-specific extras (no pi TUI equivalent)
        let decorator: Color
        let preprocessor: Color
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

    struct MarkdownColors: Sendable {
        let heading: Color
        let link: Color
        let linkUrl: Color
        let code: Color
        let codeBlock: Color
        let codeBlockBorder: Color
        let quote: Color
        let quoteBorder: Color
        let hr: Color
        let listBullet: Color
    }

    struct CodeMetrics: Sendable {
        let fontSize: CGFloat
        let gutterWidthPerDigit: CGFloat
    }
}

// MARK: - Factory

extension AppTheme {
    /// Build an `AppTheme` from a `ThemePalette`.
    /// `diffAddedBg`/`diffRemovedBg` are line-level diff backgrounds
    /// (distinct from `toolDiffAdded`/`toolDiffRemoved` which are the accent/text colors).
    static func from(
        palette p: ThemePalette,
        diffAddedBg: Color? = nil,
        diffRemovedBg: Color? = nil
    ) -> AppTheme {
        let resolvedAddedBg = diffAddedBg ?? p.toolDiffAdded.opacity(0.15)
        let resolvedRemovedBg = diffRemovedBg ?? p.toolDiffRemoved.opacity(0.15)
        return AppTheme(
            bg: BgColors(
                primary: p.bg,
                secondary: p.bgDark,
                highlight: p.bgHighlight
            ),
            text: TextColors(
                primary: p.fg,
                secondary: p.fgDim,
                tertiary: p.comment,
                thinking: p.thinkingText
            ),
            accent: AccentColors(
                primary: p.cyan,
                blue: p.blue,
                cyan: p.cyan,
                green: p.green,
                orange: p.orange,
                purple: p.purple,
                red: p.red,
                yellow: p.yellow
            ),
            diff: DiffColors(
                addedBg: resolvedAddedBg,
                removedBg: resolvedRemovedBg,
                addedAccent: p.toolDiffAdded,
                removedAccent: p.toolDiffRemoved,
                contextFg: p.toolDiffContext,
                hunkFg: p.purple
            ),
            syntax: SyntaxColors(
                keyword: p.syntaxKeyword,
                string: p.syntaxString,
                comment: p.syntaxComment,
                number: p.syntaxNumber,
                type: p.syntaxType,
                function: p.syntaxFunction,
                variable: p.syntaxVariable,
                operator: p.syntaxOperator,
                punctuation: p.syntaxPunctuation,
                plain: p.fg,
                decorator: p.yellow,
                preprocessor: p.purple,
                jsonKey: p.cyan,
                jsonDim: p.fgDim
            ),
            thinking: ThinkingColors(
                off: p.thinkingOff,
                minimal: p.thinkingMinimal,
                low: p.thinkingLow,
                medium: p.thinkingMedium,
                high: p.thinkingHigh,
                xhigh: p.thinkingXhigh
            ),
            markdown: MarkdownColors(
                heading: p.mdHeading,
                link: p.mdLink,
                linkUrl: p.mdLinkUrl,
                code: p.mdCode,
                codeBlock: p.mdCodeBlock,
                codeBlockBorder: p.mdCodeBlockBorder,
                quote: p.mdQuote,
                quoteBorder: p.mdQuoteBorder,
                hr: p.mdHr,
                listBullet: p.mdListBullet
            ),
            code: CodeMetrics(
                fontSize: 11,
                gutterWidthPerDigit: 7.5
            )
        )
    }
}

// MARK: - Theme Variants

extension AppTheme {
    // Helper for hex color literals
    private static func c(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }

    /// Dark — frosted glass accents on dark system backgrounds.
    static let dark = AppTheme.from(
        palette: ThemePalettes.dark,
        diffAddedBg: c(0x73B987).opacity(0.12),
        diffRemovedBg: c(0xDC6E73).opacity(0.10)
    )

    /// Light — clean, understated accents on white.
    static let light = AppTheme.from(
        palette: ThemePalettes.light,
        diffAddedBg: c(0x3A8550).opacity(0.10),
        diffRemovedBg: c(0xC44E54).opacity(0.08)
    )
}

extension ThemeID {
    var appTheme: AppTheme {
        switch self {
        case .dark:
            return .dark
        case .light:
            return .light
        case .custom(let name):
            // Build from imported palette if available
            if let remote = CustomThemeStore.load(name: name),
               let palette = remote.toPalette() {
                return AppTheme.from(palette: palette)
            }
            return .dark
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
