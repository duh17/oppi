import Foundation
import SwiftUI
import Testing
@testable import Oppi

/// Tests for ThemePalettes built-in definitions — verifies all built-in palettes
/// have complete token sets.
@Suite("ThemePalettes built-ins")
struct ThemePaletteBuiltinTests {

    // MARK: - All palettes have all 49 tokens

    /// Access every token on a palette to verify it was initialized.
    /// This catches accidental omissions in the manual palette definitions.
    private func assertAllTokensPresent(_ p: ThemePalette, name: String) {
        // Base 13
        _ = p.bg
        _ = p.bgDark
        _ = p.bgHighlight
        _ = p.fg
        _ = p.fgDim
        _ = p.comment
        _ = p.blue
        _ = p.cyan
        _ = p.green
        _ = p.orange
        _ = p.purple
        _ = p.red
        _ = p.yellow

        // Thinking text (1)
        _ = p.thinkingText

        // User message (2)
        _ = p.userMessageBg
        _ = p.userMessageText

        // Tool state (5)
        _ = p.toolPendingBg
        _ = p.toolSuccessBg
        _ = p.toolErrorBg
        _ = p.toolTitle
        _ = p.toolOutput

        // Markdown (10)
        _ = p.mdHeading
        _ = p.mdLink
        _ = p.mdLinkUrl
        _ = p.mdCode
        _ = p.mdCodeBlock
        _ = p.mdCodeBlockBorder
        _ = p.mdQuote
        _ = p.mdQuoteBorder
        _ = p.mdHr
        _ = p.mdListBullet

        // Diffs (3)
        _ = p.toolDiffAdded
        _ = p.toolDiffRemoved
        _ = p.toolDiffContext

        // Syntax (9)
        _ = p.syntaxComment
        _ = p.syntaxKeyword
        _ = p.syntaxFunction
        _ = p.syntaxVariable
        _ = p.syntaxString
        _ = p.syntaxNumber
        _ = p.syntaxType
        _ = p.syntaxOperator
        _ = p.syntaxPunctuation

        // Thinking levels (6)
        _ = p.thinkingOff
        _ = p.thinkingMinimal
        _ = p.thinkingLow
        _ = p.thinkingMedium
        _ = p.thinkingHigh
        _ = p.thinkingXhigh
    }

    @Test func darkPaletteHasAll49Tokens() {
        assertAllTokensPresent(ThemePalettes.dark, name: "dark")
    }

    @Test func oledPaletteHasAll49Tokens() {
        assertAllTokensPresent(ThemePalettes.oled, name: "oled")
    }

    @Test func lightPaletteHasAll49Tokens() {
        assertAllTokensPresent(ThemePalettes.light, name: "light")
    }

    @Test func nightPaletteHasAll49Tokens() {
        assertAllTokensPresent(ThemePalettes.night, name: "night")
    }

    // MARK: - Each built-in ID resolves to its corresponding palette

    @Test func themeIDPaletteResolvesForAllBuiltins() {
        for builtinID in ThemeID.builtins {
            let palette = builtinID.palette
            assertAllTokensPresent(palette, name: builtinID.rawValue)
        }
    }
}
