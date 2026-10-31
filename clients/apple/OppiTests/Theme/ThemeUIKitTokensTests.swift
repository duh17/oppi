import SwiftUI
import Testing
import UIKit
@testable import Oppi

/// Tests for `palette.ui`, the UIKit view of a theme palette: the tokens match
/// the palette they came from, the runtime palette shares the colors the window
/// paints, and a palette that is not the current theme keeps its own.
@Suite("ThemeUIKitTokens")
struct ThemeUIKitTokensTests {

    // MARK: - Tokens mirror the palette

    @Test func sharedTokensMatchTheirPalette() {
        for themeID in ThemeID.builtins {
            let palette = themeID.palette
            let ui = palette.ui
            #expect(ui.bg == UIColor(palette.bg))
            #expect(ui.fg == UIColor(palette.fg))
            #expect(ui.comment == UIColor(palette.comment))
            #expect(ui.bgDark == UIColor(palette.bgDark))
            #expect(ui.blue == UIColor(palette.blue))
            #expect(ui.toolSuccessBg == UIColor(palette.toolSuccessBg))
            #expect(ui.syntaxKeyword == UIColor(palette.syntaxKeyword))
            #expect(ui.diffAdded == UIColor(palette.toolDiffAdded))
            #expect(ui.onBlue == UIColor(ThemeColorContrast.contrastingForeground(
                on: palette.blue,
                candidates: [palette.fg, palette.bg]
            )))
        }
    }

    @Test func tokensTheSharedPaletteDoesNotCarryMatchTheirPalette() {
        let palette = ThemePalettes.light
        let ui = palette.ui
        #expect(ui.mdLink == UIColor(palette.mdLink))
        #expect(ui.mdCodeBlock == UIColor(palette.mdCodeBlock))
        #expect(ui.mdListBullet == UIColor(palette.mdListBullet))
        #expect(ui.userMessageText == UIColor(palette.userMessageText))
        #expect(ui.assistantMessageBg == UIColor(palette.assistantMessageBg))
        #expect(ui.toolPendingBg == UIColor(palette.toolPendingBg))
        #expect(ui.syntaxVariable == UIColor(palette.syntaxVariable))
        #expect(ui.thinkingXhigh == UIColor(palette.thinkingXhigh))
    }

    @Test func surfaceFillMatchesTheThemeSurfaceStyle() {
        let palette = ThemePalettes.dark
        for role in ThemeSurfaceRole.allCases {
            let style = ThemeSurfaceStyle.resolve(role, palette: palette)
            #expect(palette.ui.surfaceFill(role) == UIColor(style.fill))
            #expect(palette.ui.surfaceStroke(role) == style.stroke.map { UIColor($0) })
        }
    }

    // MARK: - Runtime palette

    @Test func runtimePaletteSharesTheWindowColors() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        ThemeRuntimeState.setThemeID(.dark)
        let palette = ThemeRuntimeState.currentPalette()
        #expect(palette.ui.fg == UIColor.themeFg)
        #expect(palette.ui.bg == UIColor.themeBg)
        #expect(palette.ui.comment == UIColor.themeComment)
        // The runtime palette's colors are the ones the theme change built, not a
        // second copy.
        #expect(palette.ui === ThemeRuntimeState.currentUIKitTokens(for: palette.identity))
    }

    @Test func aThemeThatIsNotCurrentKeepsItsOwnColors() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        ThemeRuntimeState.setThemeID(.dark)
        let light = ThemePalettes.light
        #expect(light.ui.bg == UIColor(light.bg))
        #expect(light.ui.bg != UIColor.themeBg)
        #expect(light.ui.mdLink == UIColor(light.mdLink))
        #expect(ThemeRuntimeState.currentUIKitTokens(for: light.identity) == nil)

        // Switching the runtime theme does not hand the light palette dark colors.
        ThemeRuntimeState.setThemeID(.light)
        #expect(light.ui.bg == UIColor(light.bg))
        #expect(ThemeRuntimeState.currentPalette().ui.bg == UIColor.themeBg)
    }

    @Test func tokensFollowAThemeChange() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        ThemeRuntimeState.setThemeID(.light)
        let lightForeground = ThemeRuntimeState.currentPalette().ui.fg
        ThemeRuntimeState.setThemeID(.dark)
        let darkForeground = ThemeRuntimeState.currentPalette().ui.fg
        #expect(lightForeground != darkForeground)
        #expect(darkForeground == UIColor.themeFg)
    }

    // MARK: - Palette identity

    @Test func oneBuildIsOneIdentity() {
        // A copy of a palette is the same build, so its colors are cached.
        let palette = ThemePalettes.oled
        let copy = palette
        #expect(copy.identity == palette.identity)
        #expect(copy.ui === palette.ui)
        // Two builds are two identities, even when the colors are equal.
        #expect(ThemePalettes.oled.identity == palette.identity)
    }

    @Test func aPaletteTheResolverAdjustedIsItsOwnBuild() {
        // `ThemeContrast.resolve` mutates a copy of its seed and stamps what it
        // returns, so the resolved palette cannot answer with the seed's colors.
        let seed = ThemePalettes.dark
        let resolved = ThemeContrast.resolve(isDark: true, seed: seed)
        #expect(resolved.palette.identity != seed.identity)
        #expect(resolved.palette.ui.bg == UIColor(resolved.palette.bg))
        #expect(resolved.palette.ui.mdLink == UIColor(resolved.palette.mdLink))
    }

    @Test func everyBuildGetsItsOwnIdentity() {
        // A palette's colors are `let`, so a change is a new build, which is a new
        // identity: an edited custom theme cannot inherit the colors cached for
        // the theme it was before.
        let first = ThemeContrast.resolve(isDark: true, seed: ThemePalettes.dark)
        let second = ThemeContrast.resolve(isDark: true, seed: ThemePalettes.dark)
        #expect(first.palette.identity != second.palette.identity)
        #expect(first.palette.identity != ThemePalettes.dark.identity)
        #expect(ThemePalettes.dark.identity != ThemePalettes.light.identity)
        #expect(first.palette.ui.bg == UIColor(first.palette.bg))
        #expect(second.palette.ui.bg == UIColor(second.palette.bg))
    }

    /// `ThemeUIKitTokens` is the whole palette as UIKit colors: a color token
    /// added to `ThemePalette` without one here leaves a UIKit call site
    /// bridging again, and nothing else would notice.
    @Test func everyPaletteTokenHasAUIColor() {
        // 51 color tokens plus `identity`.
        #expect(Mirror(reflecting: ThemePalettes.dark).children.count == 52)
    }
}
