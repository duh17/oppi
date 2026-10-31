import SwiftUI
import Testing
import UIKit
@testable import Oppi

/// Tests for `palette.ui`, the palette as UIKit colors: the runtime palette
/// reports the colors the window paints, another theme keeps its own, and a
/// palette's cache is per palette value.
///
/// `serialized` because the runtime-palette cases change the process-wide theme
/// and put it back; nothing else here should run between the change and the
/// restore.
@Suite("ThemeUIKitPalette", .serialized)
struct ThemeUIKitPaletteTests {

    @Test func runtimePaletteSharesTheWindowColors() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        ThemeRuntimeState.setThemeID(.dark)
        let palette = ThemeRuntimeState.currentPalette()
        #expect(palette.ui.fg == UIColor.themeFg)
        #expect(palette.ui.bg == UIColor.themeBg)
        #expect(palette.ui.comment == UIColor.themeComment)
        // The theme change built these colors, so a UIKit view that re-reads them
        // repaints with the SwiftUI surfaces instead of converting again.
        #expect(palette.ui === ThemeRuntimeState.currentUIKitPalette())
    }

    @Test func aThemeThatIsNotTheCurrentOneKeepsItsOwnColors() {
        let light = ThemePalettes.light
        let dark = ThemePalettes.dark
        #expect(light.ui.bg == UIColor(light.bg))
        #expect(light.ui.bg != dark.ui.bg)
        #expect(light.ui.mdLink == UIColor(light.mdLink))
        // Reading the palette again, after another one was read, keeps its colors.
        #expect(light.ui.bg == UIColor(light.bg))
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

    @Test func aCopySharesItsColorsAndANewBuildHasItsOwn() {
        // A copy of a palette is that palette: one cache, one set of colors.
        let palette = ThemePalettes.oled
        let copy = palette
        #expect(copy.ui === palette.ui)
        // A palette the resolver built from a seed is a palette of its own, so it
        // cannot answer with the seed's colors.
        let resolved = ThemeContrast.resolve(isDark: true, seed: ThemePalettes.dark)
        #expect(resolved.palette.ui !== ThemePalettes.dark.ui)
        #expect(resolved.palette.ui.bg == UIColor(resolved.palette.bg))
    }
}
