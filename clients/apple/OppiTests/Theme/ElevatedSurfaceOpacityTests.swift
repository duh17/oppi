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
        let opacity = try roleOpacity(.elevatedPanel, palette: palette)

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
            let opacity = try roleOpacity(.elevatedPanel, palette: palette)
            let panelBackground = composite(
                try rgb(of: palette.bgDark),
                over: try rgb(of: palette.bg),
                opacity: opacity
            )
            let contentContrast = contrastRatio(try rgb(of: palette.fg), panelBackground)

            #expect(contentContrast >= 4.5)
        }
    }

    @MainActor
    @Test func darkPalettesKeepEstablishedTranslucency() throws {
        for palette in [ThemePalettes.dark, ThemePalettes.oled, ThemePalettes.night] {
            let opacity = try roleOpacity(.elevatedPanel, palette: palette)
            #expect(abs(opacity - 0.78) < 0.005)
        }
    }

    /// Every role must stay readable on every builtin palette: on the theme's
    /// own background and composited over worst-case light/dark backdrops (a
    /// white document or black media scrolling behind a floating panel).
    @MainActor
    @Test func everyRoleKeepsReadableContrastOverWorstCaseBackdrops() throws {
        let white = RGB(red: 1, green: 1, blue: 1)
        let black = RGB(red: 0, green: 0, blue: 0)

        for palette in [ThemePalettes.dark, ThemePalettes.oled, ThemePalettes.night, ThemePalettes.light] {
            let foreground = try rgb(of: palette.fg)
            let themeBackground = try rgb(of: palette.bg)

            for role in ThemeSurfaceRole.allCases {
                let style = ThemeSurfaceStyle.resolve(role, palette: palette)
                let fill = try rgba(of: style.fill)
                let fillColor = RGB(red: fill.red, green: fill.green, blue: fill.blue)
                let opacity = Double(fill.alpha)

                let onOwnBackground = composite(fillColor, over: themeBackground, opacity: opacity)
                #expect(contrastRatio(foreground, onOwnBackground) >= 4.5)

                // Blur roles put a glass blur behind the fill, which softens
                // extreme backdrops, so their bare-compositing floor is lower;
                // blur-free roles must clear the full threshold on fill alone.
                let worstCaseFloor: CGFloat = style.wantsGlassBlur ? 3.0 : 4.5
                for backdrop in [white, black] {
                    let panel = composite(fillColor, over: backdrop, opacity: opacity)
                    #expect(contrastRatio(foreground, panel) >= worstCaseFloor)
                }
            }
        }
    }

    /// The design rule the resolver encodes: a translucent dark fill is only
    /// safe when paired with a glass blur, and blur-free roles must resolve
    /// near-opaque regardless of palette luminance.
    @MainActor
    @Test func translucentFillsPairWithBlurAndBlurFreeRolesResolveNearOpaque() throws {
        for palette in [ThemePalettes.dark, ThemePalettes.oled, ThemePalettes.night, ThemePalettes.light] {
            for role in ThemeSurfaceRole.allCases {
                let style = ThemeSurfaceStyle.resolve(role, palette: palette)
                let opacity = try roleOpacity(role, palette: palette)
                if !style.wantsGlassBlur {
                    #expect(opacity >= 0.90)
                }
                if opacity < 0.90 {
                    #expect(style.wantsGlassBlur)
                }
            }
        }
    }

    @MainActor
    @Test func contrastingForegroundPicksPaperBackgroundOnBlackSendDisc() throws {
        let fill = try rgb(of: Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255))
        let ink = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
        let paper = Color(red: 251 / 255, green: 250 / 255, blue: 247 / 255)
        let chosen = ThemeColorContrast.contrastingForeground(on: Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255), candidates: [ink, paper])
        let chosenRGB = try rgb(of: chosen)
        let paperRGB = try rgb(of: paper)
        #expect(abs(chosenRGB.red - paperRGB.red) < 0.02)
        #expect(contrastRatio(chosenRGB, fill) > contrastRatio(try rgb(of: ink), fill))
    }

    @Test func adaptiveSurfaceOpacityPreservesDarkBaselineAndBoostsLight() {
        let darkControlOpacity = ThemeColorContrast.adaptiveSurfaceOpacity(
            for: ThemePalettes.dark.bgDark,
            darkOpacity: 0.64
        )
        let lightControlOpacity = ThemeColorContrast.adaptiveSurfaceOpacity(
            for: ThemePalettes.light.bgDark,
            darkOpacity: 0.64
        )

        #expect(abs(darkControlOpacity - 0.64) < 0.005)
        #expect(lightControlOpacity > 0.88)
        #expect(lightControlOpacity > darkControlOpacity)
    }

    @MainActor
    @Test func resolvedSurfaceTracksRuntimeThemeSwitches() throws {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        ThemeRuntimeState.setThemeID(.dark)
        let dark = try rgba(of: ThemeSurfaceStyle.resolve(.elevatedPanel).fill)

        ThemeRuntimeState.setThemeID(.light)
        let light = try rgba(of: ThemeSurfaceStyle.resolve(.elevatedPanel).fill)

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
    private func roleOpacity(_ role: ThemeSurfaceRole, palette: ThemePalette) throws -> Double {
        Double(try rgba(of: ThemeSurfaceStyle.resolve(role, palette: palette).fill).alpha)
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
