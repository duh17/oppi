import Foundation
import SwiftUI
import Testing
@testable import Oppi

/// Tests for AppTheme construction from ThemePalette and the built-in static variants.
@Suite("AppTheme factory")
struct AppThemeFactoryTests {

    // MARK: - from(palette:) populates all groups

    @Test func fromPalettePopulatesBgColors() {
        let palette = ThemePalettes.dark
        let theme = AppTheme.from(palette: palette)
        // Verify all three background tokens exist (can't compare Color equality,
        // but accessing them exercises the mapping and catches missing fields).
        _ = theme.bg.primary
        _ = theme.bg.secondary
        _ = theme.bg.highlight
    }

    @Test func fromPalettePopulatesTextColors() {
        let palette = ThemePalettes.dark
        let theme = AppTheme.from(palette: palette)
        _ = theme.text.primary
        _ = theme.text.secondary
        _ = theme.text.tertiary
        _ = theme.text.thinking
    }

    @Test func fromPalettePopulatesAccentColors() {
        let palette = ThemePalettes.dark
        let theme = AppTheme.from(palette: palette)
        _ = theme.accent.primary
        _ = theme.accent.blue
        _ = theme.accent.cyan
        _ = theme.accent.green
        _ = theme.accent.orange
        _ = theme.accent.purple
        _ = theme.accent.red
        _ = theme.accent.yellow
    }

    @Test func fromPalettePopulatesDiffColors() {
        let palette = ThemePalettes.dark
        let theme = AppTheme.from(palette: palette)
        _ = theme.diff.addedBg
        _ = theme.diff.removedBg
        _ = theme.diff.addedAccent
        _ = theme.diff.removedAccent
        _ = theme.diff.contextFg
        _ = theme.diff.hunkFg
    }

    @Test func fromPalettePopulatesSyntaxColors() {
        let palette = ThemePalettes.dark
        let theme = AppTheme.from(palette: palette)
        _ = theme.syntax.keyword
        _ = theme.syntax.string
        _ = theme.syntax.comment
        _ = theme.syntax.number
        _ = theme.syntax.type
        _ = theme.syntax.function
        _ = theme.syntax.variable
        _ = theme.syntax.operator
        _ = theme.syntax.punctuation
        _ = theme.syntax.plain
        _ = theme.syntax.decorator
        _ = theme.syntax.preprocessor
        _ = theme.syntax.jsonKey
        _ = theme.syntax.jsonDim
    }

    @Test func fromPalettePopulatesMarkdownColors() {
        let palette = ThemePalettes.dark
        let theme = AppTheme.from(palette: palette)
        _ = theme.markdown.heading
        _ = theme.markdown.link
        _ = theme.markdown.linkUrl
        _ = theme.markdown.code
        _ = theme.markdown.codeBlock
        _ = theme.markdown.codeBlockBorder
        _ = theme.markdown.quote
        _ = theme.markdown.quoteBorder
        _ = theme.markdown.hr
        _ = theme.markdown.listBullet
    }

    @Test func fromPalettePopulatesThinkingColors() {
        let palette = ThemePalettes.dark
        let theme = AppTheme.from(palette: palette)
        _ = theme.thinking.off
        _ = theme.thinking.minimal
        _ = theme.thinking.low
        _ = theme.thinking.medium
        _ = theme.thinking.high
        _ = theme.thinking.xhigh
    }

    @Test func fromPaletteSetsCodeMetrics() {
        let palette = ThemePalettes.dark
        let theme = AppTheme.from(palette: palette)
        #expect(theme.code.fontSize == 11)
        #expect(theme.code.gutterWidthPerDigit == 7.5)
    }

    // MARK: - Custom diff background overrides

    @Test func fromPaletteUsesDefaultDiffBgWhenNil() {
        let palette = ThemePalettes.dark
        let theme = AppTheme.from(palette: palette)
        // Default diff backgrounds are derived from palette toolDiff colors.
        // Just verifying they exist (non-nil path exercised).
        _ = theme.diff.addedBg
        _ = theme.diff.removedBg
    }

    @Test func fromPaletteAcceptsCustomDiffBg() {
        let palette = ThemePalettes.dark
        let theme = AppTheme.from(
            palette: palette,
            diffAddedBg: .green.opacity(0.2),
            diffRemovedBg: .red.opacity(0.2)
        )
        // The factory should accept explicit diff backgrounds without crashing.
        _ = theme.diff.addedBg
        _ = theme.diff.removedBg
    }

    // MARK: - Built-in static variants

    @Test func darkVariantIsConstructed() {
        let theme = AppTheme.dark
        #expect(theme.code.fontSize == 11)
        _ = theme.bg.primary
        _ = theme.syntax.keyword
    }

    @Test func lightVariantIsConstructed() {
        let theme = AppTheme.light
        #expect(theme.code.fontSize == 11)
        _ = theme.bg.primary
        _ = theme.syntax.keyword
    }

    @Test func nightVariantIsConstructed() {
        let theme = AppTheme.night
        #expect(theme.code.fontSize == 11)
        _ = theme.bg.primary
        _ = theme.syntax.keyword
    }

    // MARK: - All three built-in palettes produce valid themes

    @Test func allBuiltinPalettesProduceValidThemes() {
        let palettes: [(String, ThemePalette)] = [
            ("dark", ThemePalettes.dark),
            ("light", ThemePalettes.light),
            ("night", ThemePalettes.night),
        ]
        for (name, palette) in palettes {
            let theme = AppTheme.from(palette: palette)
            #expect(theme.code.fontSize > 0, "Palette '\(name)' should produce valid code metrics")
            _ = theme.bg.primary
            _ = theme.text.primary
            _ = theme.accent.primary
        }
    }

    // MARK: - ThemeID.appTheme

    @Test func themeIDDarkReturnsAppThemeDark() {
        let theme = ThemeID.dark.appTheme
        #expect(theme.code.fontSize == 11)
        _ = theme.bg.primary
    }

    @Test func themeIDLightReturnsAppThemeLight() {
        let theme = ThemeID.light.appTheme
        #expect(theme.code.fontSize == 11)
        _ = theme.bg.primary
    }

    @Test func themeIDNightReturnsAppThemeNight() {
        let theme = ThemeID.night.appTheme
        #expect(theme.code.fontSize == 11)
        _ = theme.bg.primary
    }

    @Test func themeIDCustomWithNoSavedDataFallsToAppThemeDark() {
        let theme = ThemeID.custom("nonexistent-\(UUID().uuidString)").appTheme
        #expect(theme.code.fontSize == 11)
        _ = theme.bg.primary
    }

    // MARK: - Convenience init → factory round-trip

    @Test func convenienceInitPaletteProducesValidAppTheme() {
        let palette = ThemePalette(
            bg: .black, bgDark: .black, bgHighlight: .gray,
            fg: .white, fgDim: .gray, comment: .gray,
            blue: .blue, cyan: .cyan, green: .green,
            orange: .orange, purple: .purple, red: .red, yellow: .yellow
        )
        let theme = AppTheme.from(palette: palette)
        #expect(theme.code.fontSize == 11)
        _ = theme.bg.primary
        _ = theme.syntax.keyword
        _ = theme.markdown.heading
        _ = theme.diff.addedAccent
    }
}

// MARK: - ThinkingColors.color(for:)

@Suite("ThinkingColors level dispatch")
struct ThinkingColorsTests {

    private var colors: AppTheme.ThinkingColors {
        AppTheme.dark.thinking
    }

    @Test func colorForOffReturnsOff() {
        // Exercise the switch dispatch for each ThinkingLevel case.
        // We can't compare Color instances, but we can verify the path doesn't crash.
        _ = colors.color(for: .off)
    }

    @Test func colorForMinimalReturnsMinimal() {
        _ = colors.color(for: .minimal)
    }

    @Test func colorForLowReturnsLow() {
        _ = colors.color(for: .low)
    }

    @Test func colorForMediumReturnsMedium() {
        _ = colors.color(for: .medium)
    }

    @Test func colorForHighReturnsHigh() {
        _ = colors.color(for: .high)
    }

    @Test func colorForXhighReturnsXhigh() {
        _ = colors.color(for: .xhigh)
    }

    @Test func allLevelsReturnColors() {
        let levels: [ThinkingLevel] = [.off, .minimal, .low, .medium, .high, .xhigh]
        for level in levels {
            _ = colors.color(for: level)
        }
    }

    @Test func eachBuiltinThemeHasThinkingColors() {
        let themes: [AppTheme] = [.dark, .light, .night]
        let levels: [ThinkingLevel] = [.off, .minimal, .low, .medium, .high, .xhigh]
        for theme in themes {
            for level in levels {
                _ = theme.thinking.color(for: level)
            }
        }
    }
}
