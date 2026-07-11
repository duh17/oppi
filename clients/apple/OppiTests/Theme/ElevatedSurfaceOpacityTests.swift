import Foundation
import SwiftUI
import Testing
@testable import Oppi

#if canImport(UIKit)
import UIKit
#endif

/// Checks the visible compositing guarantees for panels floating over the chat
/// timeline. Light panels should suppress text ghosting; dark panels should keep
/// their established translucency and readable foreground contrast.
@Suite("Elevated surface opacity")
struct ElevatedSurfaceOpacityTests {

    #if canImport(UIKit)
    @MainActor
    @Test func lightSurfaceSuppressesTimelineTextGhosting() throws {
        let palette = ThemePalettes.light
        let surface = try rgb(of: palette.bgDark)
        let timelineBackground = try rgb(of: palette.bg)
        let timelineText = try rgb(of: palette.fg)
        let opacity = ThemeColorContrast.elevatedSurfaceOpacity(for: palette.bgDark)

        let formerContrast = contrastRatio(
            composite(surface, over: timelineText, opacity: 0.78),
            composite(surface, over: timelineBackground, opacity: 0.78)
        )
        let currentContrast = contrastRatio(
            composite(surface, over: timelineText, opacity: opacity),
            composite(surface, over: timelineBackground, opacity: opacity)
        )

        // The old fill left a clearly visible second layer of timeline text.
        // The adaptive fill makes that layer subtle without becoming fully opaque.
        #expect(formerContrast > 1.4)
        #expect(currentContrast < 1.15)
        #expect(opacity < 1)
    }

    @MainActor
    @Test func panelContentRetainsAccessibleContrastAcrossBuiltInThemes() throws {
        for palette in [ThemePalettes.dark, ThemePalettes.oled, ThemePalettes.night, ThemePalettes.light] {
            let opacity = ThemeColorContrast.elevatedSurfaceOpacity(for: palette.bgDark)
            let panelBackground = composite(
                try rgb(of: palette.bgDark),
                over: try rgb(of: palette.bg),
                opacity: opacity
            )
            let contentContrast = contrastRatio(try rgb(of: palette.fg), panelBackground)

            #expect(contentContrast >= 4.5)
        }
    }

    @Test func darkPalettesKeepEstablishedTranslucency() {
        for palette in [ThemePalettes.dark, ThemePalettes.oled, ThemePalettes.night] {
            let opacity = ThemeColorContrast.elevatedSurfaceOpacity(for: palette.bgDark)
            #expect(abs(opacity - 0.78) < 0.005)
        }
    }

    @MainActor
    @Test func resolvedSurfaceTracksRuntimeThemeSwitches() throws {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        ThemeRuntimeState.setThemeID(.dark)
        let dark = try rgba(of: Color.themeElevatedSurface)

        ThemeRuntimeState.setThemeID(.light)
        let light = try rgba(of: Color.themeElevatedSurface)

        #expect(dark.alpha < 0.79)
        #expect(light.alpha > 0.90)
        #expect(light.alpha > dark.alpha)
        #expect(light.red > dark.red)
    }

    private struct RGB {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
    }

    private struct RGBA {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    @MainActor
    private func rgb(of color: Color) throws -> RGB {
        let components = try rgba(of: color)
        return RGB(red: components.red, green: components.green, blue: components.blue)
    }

    @MainActor
    private func rgba(of color: Color) throws -> RGBA {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            throw ElevatedSurfaceTestError.unresolvedColor
        }
        return RGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    private func composite(_ foreground: RGB, over background: RGB, opacity: Double) -> RGB {
        let alpha = CGFloat(opacity)
        return RGB(
            red: foreground.red * alpha + background.red * (1 - alpha),
            green: foreground.green * alpha + background.green * (1 - alpha),
            blue: foreground.blue * alpha + background.blue * (1 - alpha)
        )
    }

    private func contrastRatio(_ lhs: RGB, _ rhs: RGB) -> CGFloat {
        let lhsLuminance = relativeLuminance(lhs)
        let rhsLuminance = relativeLuminance(rhs)
        return (max(lhsLuminance, rhsLuminance) + 0.05) / (min(lhsLuminance, rhsLuminance) + 0.05)
    }

    private func relativeLuminance(_ color: RGB) -> CGFloat {
        0.2126 * linearized(color.red)
            + 0.7152 * linearized(color.green)
            + 0.0722 * linearized(color.blue)
    }

    private func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    private enum ElevatedSurfaceTestError: Error {
        case unresolvedColor
    }
    #endif
}
