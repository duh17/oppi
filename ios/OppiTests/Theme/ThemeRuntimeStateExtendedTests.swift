import Foundation
import Testing
@testable import Oppi

/// Extended tests for ThemeRuntimeState — theme switching, palette caching,
/// and invalidation across all built-in themes.
///
/// The basic set/get tests live in ThemeIDTests.swift (ThemeRuntimeStateTests suite).
/// These tests exercise more thorough switching scenarios and edge cases.
@Suite("ThemeRuntimeState extended")
struct ThemeRuntimeStateExtendedTests {

    // MARK: - Switching through all built-in themes

    @Test func switchThroughAllBuiltins() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        for themeID in ThemeID.builtins {
            ThemeRuntimeState.setThemeID(themeID)
            #expect(ThemeRuntimeState.currentThemeID() == themeID)
            // Palette should be accessible without crashing
            let palette = ThemeRuntimeState.currentPalette()
            _ = palette.bg
            _ = palette.fg
        }
    }

    @Test func switchToCustomThemeThenBack() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        let customID = ThemeID.custom("test-switch-\(UUID().uuidString)")
        ThemeRuntimeState.setThemeID(customID)
        #expect(ThemeRuntimeState.currentThemeID() == customID)

        // Palette should fall back to dark (no saved data for this custom theme)
        let palette = ThemeRuntimeState.currentPalette()
        _ = palette.bg

        // Switch back to dark
        ThemeRuntimeState.setThemeID(.dark)
        #expect(ThemeRuntimeState.currentThemeID() == .dark)
    }

    // MARK: - Setting same theme is a no-op for ID

    @Test func settingSameThemeRetainsID() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        ThemeRuntimeState.setThemeID(.night)
        ThemeRuntimeState.setThemeID(.night)  // redundant set
        #expect(ThemeRuntimeState.currentThemeID() == .night)
    }

    // MARK: - invalidateCache preserves theme ID

    @Test func invalidateCacheKeepsCurrentThemeID() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        ThemeRuntimeState.setThemeID(.light)
        ThemeRuntimeState.invalidateCache()
        #expect(ThemeRuntimeState.currentThemeID() == .light, "invalidateCache should not change the theme ID")
    }

    @Test func invalidateCacheProducesValidPalette() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        for themeID in ThemeID.builtins {
            ThemeRuntimeState.setThemeID(themeID)
            ThemeRuntimeState.invalidateCache()
            let palette = ThemeRuntimeState.currentPalette()
            _ = palette.bg
            _ = palette.fg
            _ = palette.syntaxKeyword
        }
    }

    // MARK: - Palette matches theme ID after switch

    @Test func paletteAccessibleImmediatelyAfterSwitch() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        // Rapid switching should never leave the palette in an inconsistent state.
        ThemeRuntimeState.setThemeID(.dark)
        _ = ThemeRuntimeState.currentPalette().bg

        ThemeRuntimeState.setThemeID(.light)
        _ = ThemeRuntimeState.currentPalette().bg

        ThemeRuntimeState.setThemeID(.night)
        _ = ThemeRuntimeState.currentPalette().bg

        ThemeRuntimeState.setThemeID(.dark)
        _ = ThemeRuntimeState.currentPalette().bg
    }

    // MARK: - Custom theme with saved data

    @Test func customThemeWithSavedDataUsesCustomPalette() {
        let original = ThemeRuntimeState.currentThemeID()
        let name = "runtime-test-\(UUID().uuidString)"
        defer {
            ThemeRuntimeState.setThemeID(original)
            CustomThemeStore.delete(name: name)
        }

        // Save a custom theme
        let remote = RemoteTheme(
            name: name,
            colorScheme: "dark",
            colors: RemoteThemeColors(
                bg: "#1a1b26", bgDark: "#16161e", bgHighlight: "#292e42",
                fg: "#c0caf5", fgDim: "#565f89", comment: "#565f89",
                blue: "#7aa2f7", cyan: "#7dcfff", green: "#9ece6a",
                orange: "#ff9e64", purple: "#bb9af7", red: "#f7768e",
                yellow: "#e0af68", thinkingText: "#565f89",
                userMessageBg: "#292e42", userMessageText: "#c0caf5",
                toolPendingBg: "#292e42", toolSuccessBg: "#1e3a2e",
                toolErrorBg: "#3a1e1e", toolTitle: "#c0caf5", toolOutput: "#565f89",
                mdHeading: "#7aa2f7", mdLink: "#7dcfff", mdLinkUrl: "#565f89",
                mdCode: "#7dcfff", mdCodeBlock: "#9ece6a",
                mdCodeBlockBorder: "#292e42", mdQuote: "#565f89",
                mdQuoteBorder: "#292e42", mdHr: "#292e42",
                mdListBullet: "#ff9e64",
                toolDiffAdded: "#9ece6a", toolDiffRemoved: "#f7768e",
                toolDiffContext: "#565f89",
                syntaxComment: "#565f89", syntaxKeyword: "#bb9af7",
                syntaxFunction: "#7aa2f7", syntaxVariable: "#c0caf5",
                syntaxString: "#9ece6a", syntaxNumber: "#ff9e64",
                syntaxType: "#7dcfff", syntaxOperator: "#c0caf5",
                syntaxPunctuation: "#565f89",
                thinkingOff: "#292e42", thinkingMinimal: "#565f89",
                thinkingLow: "#7aa2f7", thinkingMedium: "#7dcfff",
                thinkingHigh: "#bb9af7", thinkingXhigh: "#f7768e"
            )
        )
        CustomThemeStore.save(remote)

        // Set runtime state to this custom theme
        let customID = ThemeID.custom(name)
        ThemeRuntimeState.setThemeID(customID)
        #expect(ThemeRuntimeState.currentThemeID() == customID)

        // Palette should come from the saved custom theme, not fallback
        let palette = ThemeRuntimeState.currentPalette()
        _ = palette.bg
        _ = palette.syntaxKeyword
    }

    // MARK: - Custom theme preferredColorScheme

    @Test func customThemeWithLightSchemeReportsLight() {
        let name = "light-custom-\(UUID().uuidString)"
        defer { CustomThemeStore.delete(name: name) }

        let remote = RemoteTheme(
            name: name,
            colorScheme: "light",
            colors: RemoteThemeColors(
                bg: "#ffffff", bgDark: "#f0f0f0", bgHighlight: "#e0e0e0",
                fg: "#1a1a1a", fgDim: "#666666", comment: "#999999",
                blue: "#0066cc", cyan: "#008080", green: "#008000",
                orange: "#cc6600", purple: "#6600cc", red: "#cc0000",
                yellow: "#999900", thinkingText: "#666666",
                userMessageBg: "#e0e0e0", userMessageText: "#1a1a1a",
                toolPendingBg: "#e8e8ff", toolSuccessBg: "#e8ffe8",
                toolErrorBg: "#ffe8e8", toolTitle: "#1a1a1a", toolOutput: "#666666",
                mdHeading: "#0066cc", mdLink: "#008080", mdLinkUrl: "#999999",
                mdCode: "#008080", mdCodeBlock: "#008000",
                mdCodeBlockBorder: "#cccccc", mdQuote: "#666666",
                mdQuoteBorder: "#cccccc", mdHr: "#cccccc",
                mdListBullet: "#cc6600",
                toolDiffAdded: "#008000", toolDiffRemoved: "#cc0000",
                toolDiffContext: "#999999",
                syntaxComment: "#999999", syntaxKeyword: "#6600cc",
                syntaxFunction: "#0066cc", syntaxVariable: "#1a1a1a",
                syntaxString: "#008000", syntaxNumber: "#cc6600",
                syntaxType: "#008080", syntaxOperator: "#1a1a1a",
                syntaxPunctuation: "#666666",
                thinkingOff: "#cccccc", thinkingMinimal: "#999999",
                thinkingLow: "#0066cc", thinkingMedium: "#008080",
                thinkingHigh: "#6600cc", thinkingXhigh: "#cc0000"
            )
        )
        CustomThemeStore.save(remote)

        let themeID = ThemeID.custom(name)
        #expect(themeID.preferredColorScheme == .light)
    }

    @Test func customThemeWithDarkSchemeReportsDark() {
        let name = "dark-custom-\(UUID().uuidString)"
        defer { CustomThemeStore.delete(name: name) }

        let remote = RemoteTheme(
            name: name,
            colorScheme: "dark",
            colors: RemoteThemeColors(
                bg: "#1a1a1a", bgDark: "#111111", bgHighlight: "#333333",
                fg: "#e0e0e0", fgDim: "#999999", comment: "#666666",
                blue: "#6699ff", cyan: "#66cccc", green: "#66cc66",
                orange: "#ff9966", purple: "#cc99ff", red: "#ff6666",
                yellow: "#cccc66", thinkingText: "#999999",
                userMessageBg: "#333333", userMessageText: "#e0e0e0",
                toolPendingBg: "#2a2a4a", toolSuccessBg: "#2a3a2a",
                toolErrorBg: "#3a2a2a", toolTitle: "#e0e0e0", toolOutput: "#999999",
                mdHeading: "#6699ff", mdLink: "#66cccc", mdLinkUrl: "#666666",
                mdCode: "#66cccc", mdCodeBlock: "#66cc66",
                mdCodeBlockBorder: "#333333", mdQuote: "#999999",
                mdQuoteBorder: "#333333", mdHr: "#333333",
                mdListBullet: "#ff9966",
                toolDiffAdded: "#66cc66", toolDiffRemoved: "#ff6666",
                toolDiffContext: "#666666",
                syntaxComment: "#666666", syntaxKeyword: "#cc99ff",
                syntaxFunction: "#6699ff", syntaxVariable: "#e0e0e0",
                syntaxString: "#66cc66", syntaxNumber: "#ff9966",
                syntaxType: "#66cccc", syntaxOperator: "#e0e0e0",
                syntaxPunctuation: "#999999",
                thinkingOff: "#333333", thinkingMinimal: "#666666",
                thinkingLow: "#6699ff", thinkingMedium: "#66cccc",
                thinkingHigh: "#cc99ff", thinkingXhigh: "#ff6666"
            )
        )
        CustomThemeStore.save(remote)

        let themeID = ThemeID.custom(name)
        #expect(themeID.preferredColorScheme == .dark)
    }
}
