import Foundation

/// Centralized theme definition for the entire app.
///
/// Organizes all visual tokens — colors, code metrics, diff styling —
/// into a single `Sendable` value type. Tokens are `ThemeColor` (UIKit colors
/// on iOS, SwiftUI `Color` on the Mac), so this file imports no SwiftUI; the
/// Mac's `\.theme` environment lives in `OppiMac/Theme/Theme+SwiftUI.swift`.
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
        let primary: ThemeColor
        /// Darkest background (code blocks, inset areas).
        let secondary: ThemeColor
        /// Elevated/highlighted background (headers, selections).
        let highlight: ThemeColor
    }

    struct TextColors: Sendable {
        /// Primary text.
        let primary: ThemeColor
        /// Secondary/dimmed text.
        let secondary: ThemeColor
        /// Tertiary/muted text (comments, timestamps, placeholders).
        let tertiary: ThemeColor
        /// Thinking block text.
        let thinking: ThemeColor
    }

    struct AccentColors: Sendable {
        /// Primary accent (pi's `accent` token).
        let primary: ThemeColor
        let blue: ThemeColor
        let cyan: ThemeColor
        let green: ThemeColor
        let orange: ThemeColor
        let purple: ThemeColor
        let red: ThemeColor
        let yellow: ThemeColor
    }

    struct DiffColors: Sendable {
        /// Background for added lines.
        let addedBg: ThemeColor
        /// Background for removed lines.
        let removedBg: ThemeColor
        /// Left accent bar and prefix for added lines.
        let addedAccent: ThemeColor
        /// Left accent bar and prefix for removed lines.
        let removedAccent: ThemeColor
        /// Context line text color.
        let contextFg: ThemeColor
        /// Hunk header color (@@ ... @@).
        let hunkFg: ThemeColor
    }

    struct SyntaxColors: Sendable {
        let keyword: ThemeColor
        let string: ThemeColor
        let comment: ThemeColor
        let number: ThemeColor
        let type: ThemeColor
        let function: ThemeColor
        let variable: ThemeColor
        let `operator`: ThemeColor
        let punctuation: ThemeColor
        let plain: ThemeColor
        // iOS-specific extras (no pi TUI equivalent)
        let decorator: ThemeColor
        let preprocessor: ThemeColor
        let jsonKey: ThemeColor
        let jsonDim: ThemeColor
    }

    struct ThinkingColors: Sendable {
        let off: ThemeColor
        let minimal: ThemeColor
        let low: ThemeColor
        let medium: ThemeColor
        let high: ThemeColor
        let xhigh: ThemeColor

        func color(for level: ThinkingLevel) -> ThemeColor {
            switch level {
            case .off: return off
            case .minimal: return minimal
            case .low: return low
            case .medium: return medium
            case .high: return high
            case .xhigh: return xhigh
            case .max: return xhigh
            }
        }
    }

    struct MarkdownColors: Sendable {
        let heading: ThemeColor
        let link: ThemeColor
        let linkUrl: ThemeColor
        let code: ThemeColor
        let codeBlock: ThemeColor
        let codeBlockBorder: ThemeColor
        let quote: ThemeColor
        let quoteBorder: ThemeColor
        let hr: ThemeColor
        let listBullet: ThemeColor
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
        diffAddedBg: ThemeColor? = nil,
        diffRemovedBg: ThemeColor? = nil
    ) -> AppTheme {
        let resolvedAddedBg = diffAddedBg ?? p.toolDiffAdded.multiplyingAlpha(0.15)
        let resolvedRemovedBg = diffRemovedBg ?? p.toolDiffRemoved.multiplyingAlpha(0.15)
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
    private static func c(_ hex: UInt32) -> ThemeColor {
        ThemeColor.themeSRGB(
            Double((hex >> 16) & 0xFF) / 255.0,
            Double((hex >> 8) & 0xFF) / 255.0,
            Double(hex & 0xFF) / 255.0
        )
    }

    /// Dark — deep ink surfaces with soft editor-style contrast.
    static let dark = AppTheme.from(
        palette: ThemePalettes.dark,
        diffAddedBg: c(0x73B07C).multiplyingAlpha(0.10),
        diffRemovedBg: c(0xCC7488).multiplyingAlpha(0.08)
    )

    /// OLED — true black variant of Dark with brighter secondary text.
    static let oled = AppTheme.from(
        palette: ThemePalettes.oled,
        diffAddedBg: c(0x6FAF78).multiplyingAlpha(0.10),
        diffRemovedBg: c(0xCC7388).multiplyingAlpha(0.08)
    )

    /// Light — Latte-inspired surfaces with softened accent contrast.
    static let light = AppTheme.from(
        palette: ThemePalettes.light,
        diffAddedBg: c(0x2A9D8F).multiplyingAlpha(0.10),
        diffRemovedBg: c(0xC0505A).multiplyingAlpha(0.08)
    )

    /// Night — warm dark-room reading mode with minimal eye strain.
    static let night = AppTheme.from(
        palette: ThemePalettes.night,
        diffAddedBg: c(0x6A9060).multiplyingAlpha(0.10),
        diffRemovedBg: c(0xA85858).multiplyingAlpha(0.08)
    )

}

extension ThemeID {
    var appTheme: AppTheme {
        switch self {
        case .dark:
            return .dark
        case .oled:
            return .oled
        case .light:
            return .light
        case .night:
            return .night
        case .custom(let name):
            // Build from imported palette if available
            if let palette = CustomThemeStore.palette(name: name) {
                return AppTheme.from(palette: palette)
            }
            return .dark
        }
    }
}
