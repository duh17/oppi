import Testing
import UIKit
@testable import Oppi

@Suite("RenderTheme mapping")
struct RenderThemeMappingTests {
    @Test func paletteRenderThemeMapsCoreTokens() {
        let palette = ThemePalettes.light
        let renderTheme = palette.renderTheme

        assertEqual(renderTheme.foreground, palette.fg)
        assertEqual(renderTheme.foregroundDim, palette.fgDim)
        assertEqual(renderTheme.background, palette.bg)
        assertEqual(renderTheme.backgroundDark, palette.bgDark)
        assertEqual(renderTheme.comment, palette.comment)
    }

    @Test func paletteRenderThemeMapsSyntaxAndAccentTokens() {
        let palette = ThemePalettes.light
        let renderTheme = palette.renderTheme

        assertEqual(renderTheme.keyword, palette.syntaxKeyword)
        assertEqual(renderTheme.string, palette.syntaxString)
        assertEqual(renderTheme.number, palette.syntaxNumber)
        assertEqual(renderTheme.function, palette.syntaxFunction)
        assertEqual(renderTheme.type, palette.syntaxType)
        assertEqual(renderTheme.link, palette.mdLink)
        assertEqual(renderTheme.heading, palette.mdHeading)
        assertEqual(renderTheme.accentBlue, palette.blue)
        assertEqual(renderTheme.accentGreen, palette.green)
        assertEqual(renderTheme.accentOrange, palette.orange)
        assertEqual(renderTheme.accentPurple, palette.purple)
        assertEqual(renderTheme.accentRed, palette.red)
        assertEqual(renderTheme.accentYellow, palette.yellow)
    }

    @Test func currentRenderThemeTracksRuntimeTheme() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        ThemeRuntimeState.setThemeID(.light)
        assertEqual(ThemeRuntimeState.currentRenderTheme().foreground, ThemePalettes.light.fg)
        assertEqual(ThemeRuntimeState.currentRenderTheme().accentRed, ThemePalettes.light.red)

        ThemeRuntimeState.setThemeID(.night)
        assertEqual(ThemeRuntimeState.currentRenderTheme().foreground, ThemePalettes.night.fg)
        assertEqual(ThemeRuntimeState.currentRenderTheme().accentBlue, ThemePalettes.night.blue)
    }

    private func assertEqual(_ lhs: CGColor, _ rhs: UIColor) {
        let left = UIColor(cgColor: lhs)
        var lr: CGFloat = 0
        var lg: CGFloat = 0
        var lb: CGFloat = 0
        var la: CGFloat = 0
        var rr: CGFloat = 0
        var rg: CGFloat = 0
        var rb: CGFloat = 0
        var ra: CGFloat = 0
        #expect(left.getRed(&lr, green: &lg, blue: &lb, alpha: &la))
        #expect(rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra))
        #expect(abs(lr - rr) < 0.001)
        #expect(abs(lg - rg) < 0.001)
        #expect(abs(lb - rb) < 0.001)
        #expect(abs(la - ra) < 0.001)
    }
}
