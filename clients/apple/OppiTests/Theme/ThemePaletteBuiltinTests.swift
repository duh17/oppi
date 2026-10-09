import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

/// Tests for ThemePalettes built-in definitions — verifies all built-in palettes
/// have complete token sets.
@Suite("ThemePalettes built-ins")
struct ThemePaletteBuiltinTests {

    // MARK: - All palettes have all tokens

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

        // User / assistant message (4)
        _ = p.userMessageBg
        _ = p.userMessageText
        _ = p.assistantMessageBg
        _ = p.userMessageAccent

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

    // MARK: - Speaker contrast (WCAG 2.2, sRGB, linearize 0.04045)

    @Test func builtInUserTextOnUserFillMeetsAA() {
        for themeID in ThemeID.builtins {
            let palette = themeID.palette
            let ratio = wcagContrast(palette.userMessageText, palette.userMessageBg)
            #expect(
                ratio + 1e-6 >= 4.5,
                "\(themeID.rawValue) user text on fill \(ratio)"
            )
        }
    }

    @Test func builtInUserAccentVersusBackgroundMeetsNonText() {
        for themeID in ThemeID.builtins {
            let palette = themeID.palette
            let ratio = wcagContrast(palette.userMessageAccent, palette.bg)
            #expect(
                ratio + 1e-6 >= 3.0,
                "\(themeID.rawValue) accent vs bg \(ratio)"
            )
        }
    }

    @Test func builtInAssistantTextOnAssistantFillMeetsAA() {
        for themeID in ThemeID.builtins {
            let palette = themeID.palette
            let fill = opaqueFill(palette.assistantMessageBg) ?? palette.bg
            let ratio = wcagContrast(palette.fg, fill)
            #expect(
                ratio + 1e-6 >= 4.5,
                "\(themeID.rawValue) assistant text on fill \(ratio)"
            )
        }
    }

    @Test func increasedContrastUserTextOnStrongerFillMeetsAA() {
        for themeID in ThemeID.builtins {
            let palette = themeID.palette
            guard let fill = TimelineSpeakerChrome.increasedContrastFill(for: themeID) else {
                Issue.record("missing Increase Contrast fill for \(themeID.rawValue)")
                continue
            }
            let ratio = wcagContrast(palette.userMessageText, Color(fill))
            #expect(
                ratio + 1e-6 >= 4.5,
                "\(themeID.rawValue) IC user text on fill \(ratio)"
            )
        }
    }

    @Test func builtInUserGlyphOnUserFillMeetsNonText() {
        for themeID in ThemeID.builtins {
            let palette = themeID.palette
            let ratio = wcagContrast(palette.userMessageText, palette.userMessageBg)
            #expect(
                ratio + 1e-6 >= 3.0,
                "\(themeID.rawValue) glyph on fill \(ratio)"
            )
        }
    }

    @Test func increasedContrastUserGlyphOnStrongerFillMeetsNonText() {
        for themeID in ThemeID.builtins {
            let palette = themeID.palette
            guard let fill = TimelineSpeakerChrome.increasedContrastFill(for: themeID) else {
                Issue.record("missing Increase Contrast fill for \(themeID.rawValue)")
                continue
            }
            let ratio = wcagContrast(palette.userMessageText, Color(fill))
            #expect(
                ratio + 1e-6 >= 3.0,
                "\(themeID.rawValue) IC glyph on fill \(ratio)"
            )
        }
    }

    @Test func builtInYouCaptionOnUserFillMeetsAA() {
        for themeID in ThemeID.builtins {
            let palette = themeID.palette
            let ratio = wcagContrast(palette.userMessageText, palette.userMessageBg)
            #expect(
                ratio + 1e-6 >= 4.5,
                "\(themeID.rawValue) caption on fill \(ratio)"
            )
        }
    }

    @Test func increasedContrastYouCaptionOnStrongerFillMeetsAA() {
        for themeID in ThemeID.builtins {
            let palette = themeID.palette
            guard let fill = TimelineSpeakerChrome.increasedContrastFill(for: themeID) else {
                Issue.record("missing Increase Contrast fill for \(themeID.rawValue)")
                continue
            }
            let ratio = wcagContrast(palette.userMessageText, Color(fill))
            #expect(
                ratio + 1e-6 >= 4.5,
                "\(themeID.rawValue) IC caption on fill \(ratio)"
            )
        }
    }
}

private func opaqueFill(_ color: Color) -> Color? {
    TimelineSpeakerChrome.resolvedAlpha(of: UIColor(color)) < 0.02 ? nil : color
}

private func wcagContrast(_ foreground: Color, _ background: Color) -> CGFloat {
    let a = relativeLuminance(foreground)
    let b = relativeLuminance(background)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

private func relativeLuminance(_ color: Color) -> CGFloat {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: nil)
    return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
}

private func linearize(_ channel: CGFloat) -> CGFloat {
    channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
}
