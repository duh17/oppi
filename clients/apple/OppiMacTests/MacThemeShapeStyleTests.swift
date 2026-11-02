import AppKit
import SwiftUI
import Testing
@testable import Oppi

/// The theme's SwiftUI face ships in `OppiMac` only: `\.theme` and
/// `ThemeShapeStyle` are how Mac views read a palette token without capturing a
/// color. The iOS theme model is UIKit-side, so this covers the Mac's copy.
@Suite("Mac theme shape styles")
struct MacThemeShapeStyleTests {
    @Test func shapeStylesResolveFromTheirEnvironment() {
        let originalThemeID = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(originalThemeID) }
        ThemeRuntimeState.setThemeID(.dark)

        var lightEnvironment = EnvironmentValues()
        lightEnvironment.theme = .light
        var oledEnvironment = EnvironmentValues()
        oledEnvironment.theme = .oled

        let foreground = ThemeShapeStyle(role: .foreground)
        let background = ThemeShapeStyle(role: .background)

        #expect(NSColor(foreground.color(in: lightEnvironment)) == NSColor(ThemePalettes.light.fg))
        #expect(NSColor(foreground.color(in: oledEnvironment)) == NSColor(ThemePalettes.oled.fg))
        #expect(NSColor(background.color(in: lightEnvironment)) == NSColor(ThemePalettes.light.bg))
        #expect(NSColor(background.color(in: oledEnvironment)) == NSColor(ThemePalettes.oled.bg))
    }
}
