import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

/// Extended tests for ThemeRuntimeState — theme switching and palette caching
/// across all built-in themes.
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

// MARK: - UIKit accessors

/// `UIColor.theme*` is the UIKit spelling of `Color.theme*`: both read the
/// cached palette. A migration that swapped `UIColor(Color.themeX)` for
/// `UIColor.themeX` would silently change pixels if these ever drifted, so
/// every token is compared against the palette the SwiftUI accessors read.
@Suite("Theme UIColor accessors")
struct ThemeUIColorAccessorTests {
    @Test func readsTheSamePaletteAsTheSwiftUIAccessors() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        for themeID in ThemeID.builtins {
            ThemeRuntimeState.setThemeID(themeID)
            let palette = ThemeRuntimeState.currentPalette()
            let mismatches = [
                ("bg", UIColor.themeBg, UIColor(palette.bg)),
                ("bgDark", UIColor.themeBgDark, UIColor(palette.bgDark)),
                ("bgHighlight", UIColor.themeBgHighlight, UIColor(palette.bgHighlight)),
                ("fg", UIColor.themeFg, UIColor(palette.fg)),
                ("fgDim", UIColor.themeFgDim, UIColor(palette.fgDim)),
                ("comment", UIColor.themeComment, UIColor(palette.comment)),
                ("blue", UIColor.themeBlue, UIColor(palette.blue)),
                ("cyan", UIColor.themeCyan, UIColor(palette.cyan)),
                ("green", UIColor.themeGreen, UIColor(palette.green)),
                ("orange", UIColor.themeOrange, UIColor(palette.orange)),
                ("purple", UIColor.themePurple, UIColor(palette.purple)),
                ("red", UIColor.themeRed, UIColor(palette.red)),
                ("yellow", UIColor.themeYellow, UIColor(palette.yellow)),
                ("toolSuccessBg", UIColor.themeToolSuccessBg, UIColor(palette.toolSuccessBg)),
                ("toolTitle", UIColor.themeToolTitle, UIColor(palette.toolTitle)),
                ("toolOutput", UIColor.themeToolOutput, UIColor(palette.toolOutput)),
                ("scrim", UIColor.themeScrim, UIColor(palette.bgDark.opacity(0.82))),
                ("dimScrim", UIColor.themeDimScrim, UIColor(palette.bg.opacity(0.5))),
                ("recessedInset", UIColor.themeRecessedInset, UIColor(palette.bg.opacity(0.30))),
                ("onBlue", UIColor.themeOnBlue, UIColor(ThemeColorContrast.foreground(for: palette.blue))),
                ("onGreen", UIColor.themeOnGreen, UIColor(ThemeColorContrast.foreground(for: palette.green))),
                ("syntaxComment", UIColor.themeSyntaxComment, UIColor(palette.syntaxComment)),
                ("syntaxKeyword", UIColor.themeSyntaxKeyword, UIColor(palette.syntaxKeyword)),
                ("syntaxFunction", UIColor.themeSyntaxFunction, UIColor(palette.syntaxFunction)),
                ("syntaxString", UIColor.themeSyntaxString, UIColor(palette.syntaxString)),
                ("syntaxNumber", UIColor.themeSyntaxNumber, UIColor(palette.syntaxNumber)),
                ("syntaxType", UIColor.themeSyntaxType, UIColor(palette.syntaxType)),
                ("syntaxPunctuation", UIColor.themeSyntaxPunctuation, UIColor(palette.syntaxPunctuation)),
                ("diffAdded", UIColor.themeDiffAdded, UIColor(palette.toolDiffAdded)),
                ("diffRemoved", UIColor.themeDiffRemoved, UIColor(palette.toolDiffRemoved)),
                ("diffContext", UIColor.themeDiffContext, UIColor(palette.toolDiffContext))
            ].filter { !Self.sameColor($0.1, $0.2) }.map(\.0)
            #expect(mismatches.isEmpty, "\(themeID.rawValue) diverged: \(mismatches)")
        }
    }

    @Test func surfaceRolesMatchRoleResolvedFills() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        for themeID in ThemeID.builtins {
            ThemeRuntimeState.setThemeID(themeID)
            for role in ThemeSurfaceRole.allCases {
                let style = ThemeSurfaceStyle.resolve(role)
                #expect(
                    Self.sameColor(UIColor.themeSurfaceFill(role), UIColor(style.fill)),
                    "\(themeID.rawValue) \(role) fill diverged"
                )
                let stroke = UIColor.themeSurfaceStroke(role)
                #expect((stroke == nil) == (style.stroke == nil), "\(themeID.rawValue) \(role) stroke presence diverged")
                if let stroke, let expected = style.stroke {
                    #expect(Self.sameColor(stroke, UIColor(expected)), "\(themeID.rawValue) \(role) stroke diverged")
                }
            }
        }
    }

    @Test func refreshesWhenTheThemeChanges() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        ThemeRuntimeState.setThemeID(.dark)
        let darkBackground = UIColor.themeBg
        let darkForeground = UIColor.themeFg
        ThemeRuntimeState.setThemeID(.light)

        #expect(!Self.sameColor(darkBackground, UIColor.themeBg))
        #expect(!Self.sameColor(darkForeground, UIColor.themeFg))
        #expect(Self.sameColor(UIColor.themeBg, UIColor(ThemeID.light.palette.bg)))
    }

    private static func sameColor(_ lhs: UIColor, _ rhs: UIColor) -> Bool {
        var lhsRed: CGFloat = 0
        var lhsGreen: CGFloat = 0
        var lhsBlue: CGFloat = 0
        var lhsAlpha: CGFloat = 0
        var rhsRed: CGFloat = 0
        var rhsGreen: CGFloat = 0
        var rhsBlue: CGFloat = 0
        var rhsAlpha: CGFloat = 0
        guard lhs.getRed(&lhsRed, green: &lhsGreen, blue: &lhsBlue, alpha: &lhsAlpha),
              rhs.getRed(&rhsRed, green: &rhsGreen, blue: &rhsBlue, alpha: &rhsAlpha)
        else { return false }
        let tolerance: CGFloat = 0.0005
        return abs(lhsRed - rhsRed) < tolerance
            && abs(lhsGreen - rhsGreen) < tolerance
            && abs(lhsBlue - rhsBlue) < tolerance
            && abs(lhsAlpha - rhsAlpha) < tolerance
    }
}
