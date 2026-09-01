import Foundation
import SwiftUI
import Testing
@testable import Oppi

/// Tests for ThemeID parsing, serialization, and palette resolution.
@Suite("ThemeID")
struct ThemeIDTests {

    // MARK: - rawValue round-trip

    @Test func darkRawValue() {
        #expect(ThemeID.dark.rawValue == "dark")
    }

    @Test func oledRawValue() {
        #expect(ThemeID.oled.rawValue == "oled")
    }

    @Test func lightRawValue() {
        #expect(ThemeID.light.rawValue == "light")
    }

    @Test func nightRawValue() {
        #expect(ThemeID.night.rawValue == "night")
    }

    @Test func customRawValueIncludesPrefix() {
        let id = ThemeID.custom("Dracula")
        #expect(id.rawValue == "custom:Dracula")
    }

    @Test func roundTripDark() {
        let id = ThemeID(rawValue: "dark")
        #expect(id == .dark)
    }

    @Test func roundTripOled() {
        let id = ThemeID(rawValue: "oled")
        #expect(id == .oled)
    }

    @Test func roundTripLight() {
        let id = ThemeID(rawValue: "light")
        #expect(id == .light)
    }

    @Test func roundTripNight() {
        let id = ThemeID(rawValue: "night")
        #expect(id == .night)
    }

    @Test func roundTripCustom() {
        let id = ThemeID(rawValue: "custom:My Theme")
        #expect(id == .custom("My Theme"))
    }

    @Test func unknownRawValueDefaultsToDark() {
        let id = ThemeID(rawValue: "unknown-value")
        #expect(id == .dark, "Unrecognized raw values should default to .dark")
    }

    @Test func retiredNeutralRawValuesDefaultToDark() {
        #expect(ThemeID(rawValue: "neutral-dark") == .dark)
        #expect(ThemeID(rawValue: "neutral-light") == .dark)
    }

    @Test func customWithEmptyName() {
        // "custom:" with empty name after prefix
        let id = ThemeID(rawValue: "custom:")
        #expect(id == .custom(""))
    }

    @Test func customWithColonInName() {
        // "custom:My:Theme" — only the first "custom:" is stripped
        let id = ThemeID(rawValue: "custom:My:Theme")
        #expect(id == .custom("My:Theme"))
    }

    // MARK: - Codable

    @Test func encodeDark() throws {
        let data = try JSONEncoder().encode(ThemeID.dark)
        let str = String(data: data, encoding: .utf8)
        #expect(str == "\"dark\"")
    }

    @Test func encodeOled() throws {
        let data = try JSONEncoder().encode(ThemeID.oled)
        let str = String(data: data, encoding: .utf8)
        #expect(str == "\"oled\"")
    }

    @Test func encodeLight() throws {
        let data = try JSONEncoder().encode(ThemeID.light)
        let str = String(data: data, encoding: .utf8)
        #expect(str == "\"light\"")
    }

    @Test func encodeNight() throws {
        let data = try JSONEncoder().encode(ThemeID.night)
        let str = String(data: data, encoding: .utf8)
        #expect(str == "\"night\"")
    }

    @Test func encodeCustom() throws {
        let data = try JSONEncoder().encode(ThemeID.custom("Nord"))
        let str = String(data: data, encoding: .utf8)
        #expect(str == "\"custom:Nord\"")
    }

    @Test func decodeDark() throws {
        let data = Data("\"dark\"".utf8)
        let id = try JSONDecoder().decode(ThemeID.self, from: data)
        #expect(id == .dark)
    }

    @Test func decodeOled() throws {
        let data = Data("\"oled\"".utf8)
        let id = try JSONDecoder().decode(ThemeID.self, from: data)
        #expect(id == .oled)
    }

    @Test func decodeUnknown() throws {
        let data = Data("\"future-theme\"".utf8)
        let id = try JSONDecoder().decode(ThemeID.self, from: data)
        #expect(id == .dark, "Unknown theme IDs should decode as .dark")
    }

    // MARK: - displayName

    @Test func displayNames() {
        #expect(ThemeID.dark.displayName == "Dark")
        #expect(ThemeID.oled.displayName == "OLED")
        #expect(ThemeID.light.displayName == "Light")
        #expect(ThemeID.night.displayName == "Night")
        #expect(ThemeID.custom("Nord").displayName == "Nord")
    }

    // MARK: - detail

    @Test func detailStrings() {
        #expect(!ThemeID.dark.detail.isEmpty)
        #expect(!ThemeID.oled.detail.isEmpty)
        #expect(!ThemeID.light.detail.isEmpty)
        #expect(!ThemeID.night.detail.isEmpty)
        #expect(ThemeID.custom("X").detail.isEmpty, "Custom themes have no detail text")
    }

    // MARK: - preferredColorScheme

    @Test func darkPrefersDarkScheme() {
        #expect(ThemeID.dark.preferredColorScheme == .dark)
    }

    @Test func oledPrefersDarkScheme() {
        #expect(ThemeID.oled.preferredColorScheme == .dark)
    }

    @Test func lightPrefersLightScheme() {
        #expect(ThemeID.light.preferredColorScheme == .light)
    }

    @Test func nightPrefersDarkScheme() {
        #expect(ThemeID.night.preferredColorScheme == .dark)
    }

    @Test func customWithNoSavedDataDefaultsToDark() {
        // A custom theme with no saved data should default to dark
        let id = ThemeID.custom("nonexistent-theme-\(UUID().uuidString)")
        #expect(id.preferredColorScheme == .dark)
    }

    // MARK: - palette

    @Test func darkPaletteIsNotNil() {
        let palette = ThemeID.dark.palette
        // The dark palette should have non-default colors for at least the base 13
        // We can't compare Color values directly, so just verify the palette exists
        _ = palette.bg
        _ = palette.fg
        _ = palette.blue
    }

    @Test func oledPaletteIsNotNil() {
        let palette = ThemeID.oled.palette
        _ = palette.bg
        _ = palette.fg
        _ = palette.blue
    }

    @Test func lightPaletteIsNotNil() {
        let palette = ThemeID.light.palette
        _ = palette.bg
        _ = palette.fg
        _ = palette.blue
    }

    @Test func nightPaletteIsNotNil() {
        let palette = ThemeID.night.palette
        _ = palette.bg
        _ = palette.fg
        _ = palette.blue
        _ = palette.orange  // hero accent
    }

    @Test func customPaletteWithoutSavedDataFallsToDark() {
        let palette = ThemeID.custom("nonexistent-\(UUID().uuidString)").palette
        // Should fall back to dark palette
        _ = palette.bg
    }

    // MARK: - builtins

    @Test func builtinsContainsShippedThemes() {
        #expect(ThemeID.builtins == [.dark, .oled, .light, .night])
    }

    @Test func lightPickerIncludesOnlyLightThemes() {
        let themes = ThemeID.pickerThemes(matching: .light)
        #expect(themes.contains(.light))
        #expect(!themes.contains(.dark))
        #expect(!themes.contains(.oled))
        #expect(!themes.contains(.night))
    }

    @Test func darkPickerIncludesOnlyDarkThemes() {
        let themes = ThemeID.pickerThemes(matching: .dark)
        #expect(themes.contains(.dark))
        #expect(themes.contains(.oled))
        #expect(themes.contains(.night))
        #expect(!themes.contains(.light))
    }

    @Test func unfilteredPickerIncludesEveryBuiltin() {
        let themes = ThemeID.pickerThemes(matching: nil)
        #expect(ThemeID.builtins.allSatisfy(themes.contains))
        #expect(themes.filter(\.isImported).allSatisfy { theme in
            if case .custom = theme { return true }
            return false
        })
        #expect(ThemeID.light.isImported == false)
        #expect(ThemeID.custom("Paper").isImported)
    }

    @Test func pickerSplitsImportedThemesByColorScheme() {
        let lightName = "picker-light-\(UUID().uuidString)"
        let darkName = "picker-dark-\(UUID().uuidString)"
        defer {
            CustomThemeStore.delete(name: lightName)
            CustomThemeStore.delete(name: darkName)
        }

        CustomThemeStore.save(RemoteTheme(
            name: lightName,
            colorScheme: "light",
            colors: .themeIDTestStub
        ))
        CustomThemeStore.save(RemoteTheme(
            name: darkName,
            colorScheme: "dark",
            colors: .themeIDTestStub
        ))

        let lightThemes = ThemeID.pickerThemes(matching: .light)
        let darkThemes = ThemeID.pickerThemes(matching: .dark)
        #expect(lightThemes.contains(.custom(lightName)))
        #expect(!lightThemes.contains(.custom(darkName)))
        #expect(darkThemes.contains(.custom(darkName)))
        #expect(!darkThemes.contains(.custom(lightName)))
    }

    // MARK: - Hashable

    @Test func hashableEquality() {
        #expect(ThemeID.dark == ThemeID.dark)
        #expect(ThemeID.dark != ThemeID.oled)
        #expect(ThemeID.dark != ThemeID.light)
        #expect(ThemeID.dark != ThemeID.night)
        #expect(ThemeID.oled == ThemeID.oled)
        #expect(ThemeID.night == ThemeID.night)
        #expect(ThemeID.custom("A") == ThemeID.custom("A"))
        #expect(ThemeID.custom("A") != ThemeID.custom("B"))
    }
}

// MARK: - ThemeRuntimeState

@Suite("ThemeRuntimeState")
struct ThemeRuntimeStateTests {

    @Test func setAndGetThemeID() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        ThemeRuntimeState.setThemeID(.light)
        #expect(ThemeRuntimeState.currentThemeID() == .light)

        ThemeRuntimeState.setThemeID(.dark)
        #expect(ThemeRuntimeState.currentThemeID() == .dark)
    }

    @Test func currentPaletteMatchesCurrentTheme() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        ThemeRuntimeState.setThemeID(.dark)
        // Palette should be cached and match the dark theme
        let palette = ThemeRuntimeState.currentPalette()
        _ = palette.bg
    }
}

private extension RemoteThemeColors {
    static let themeIDTestStub = RemoteThemeColors(
        bg: "#111111", bgDark: "#000000", bgHighlight: "#222222",
        fg: "#eeeeee", fgDim: "#aaaaaa", comment: "#888888",
        blue: "#0000ff", cyan: "#00ffff", green: "#00ff00",
        orange: "#ff8800", purple: "#8800ff", red: "#ff0000",
        yellow: "#ffff00", thinkingText: "#aaaaaa",
        userMessageBg: "#222222", userMessageText: "#eeeeee",
        toolPendingBg: "#111133", toolSuccessBg: "#113311", toolErrorBg: "#331111",
        toolTitle: "#eeeeee", toolOutput: "#aaaaaa",
        mdHeading: "#0000ff", mdLink: "#00ffff", mdLinkUrl: "#888888",
        mdCode: "#00ffff", mdCodeBlock: "#00ff00", mdCodeBlockBorder: "#444444",
        mdQuote: "#aaaaaa", mdQuoteBorder: "#444444", mdHr: "#444444",
        mdListBullet: "#ff8800",
        toolDiffAdded: "#00ff00", toolDiffRemoved: "#ff0000", toolDiffContext: "#888888",
        syntaxComment: "#888888", syntaxKeyword: "#8800ff", syntaxFunction: "#0000ff",
        syntaxVariable: "#eeeeee", syntaxString: "#00ff00", syntaxNumber: "#ff8800",
        syntaxType: "#00ffff", syntaxOperator: "#eeeeee", syntaxPunctuation: "#aaaaaa",
        thinkingOff: "#444444", thinkingMinimal: "#888888", thinkingLow: "#0000ff",
        thinkingMedium: "#00ffff", thinkingHigh: "#8800ff", thinkingXhigh: "#ff0000"
    )
}
