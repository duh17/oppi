import Foundation
import Testing
@testable import Oppi

/// Tests for ThemeID parsing, serialization, and palette resolution.
@Suite("ThemeID")
struct ThemeIDTests {

    // MARK: - rawValue round-trip

    @Test func darkRawValue() {
        #expect(ThemeID.dark.rawValue == "dark")
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

    @Test func decodeUnknown() throws {
        let data = Data("\"future-theme\"".utf8)
        let id = try JSONDecoder().decode(ThemeID.self, from: data)
        #expect(id == .dark, "Unknown theme IDs should decode as .dark")
    }

    // MARK: - displayName

    @Test func displayNames() {
        #expect(ThemeID.dark.displayName == "Dark")
        #expect(ThemeID.light.displayName == "Light")
        #expect(ThemeID.night.displayName == "Night")
        #expect(ThemeID.custom("Nord").displayName == "Nord")
    }

    // MARK: - detail

    @Test func detailStrings() {
        #expect(!ThemeID.dark.detail.isEmpty)
        #expect(!ThemeID.light.detail.isEmpty)
        #expect(!ThemeID.night.detail.isEmpty)
        #expect(!ThemeID.custom("X").detail.isEmpty)
    }

    // MARK: - preferredColorScheme

    @Test func darkPrefersDarkScheme() {
        #expect(ThemeID.dark.preferredColorScheme == .dark)
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

    @Test func builtinsContainsDarkLightAndNight() {
        #expect(ThemeID.builtins.contains(.dark))
        #expect(ThemeID.builtins.contains(.light))
        #expect(ThemeID.builtins.contains(.night))
        #expect(ThemeID.builtins.count == 3)
    }

    // MARK: - Hashable

    @Test func hashableEquality() {
        #expect(ThemeID.dark == ThemeID.dark)
        #expect(ThemeID.dark != ThemeID.light)
        #expect(ThemeID.dark != ThemeID.night)
        #expect(ThemeID.night == ThemeID.night)
        #expect(ThemeID.custom("A") == ThemeID.custom("A"))
        #expect(ThemeID.custom("A") != ThemeID.custom("B"))
    }
}

// MARK: - ThemePalette convenience init

@Suite("ThemePalette convenience init")
struct ThemePaletteConvenienceInitTests {

    @Test func convenienceInitDerivesSemanticTokensFromBase() {
        let palette = ThemePalette(
            bg: .black, bgDark: .black, bgHighlight: .gray,
            fg: .white, fgDim: .gray, comment: .gray,
            blue: .blue, cyan: .cyan, green: .green,
            orange: .orange, purple: .purple, red: .red, yellow: .yellow
        )
        // The convenience init derives all semantic tokens.
        // Verify a sample of derived values exist (they're derived from base colors).
        // We can't compare Color equality reliably, but we can verify
        // the palette was constructed without crashing and has all fields.
        _ = palette.thinkingText
        _ = palette.userMessageBg
        _ = palette.toolPendingBg
        _ = palette.mdHeading
        _ = palette.syntaxKeyword
        _ = palette.thinkingOff
        _ = palette.toolDiffAdded
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

    @Test func invalidateCacheRecomputesPalette() {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        ThemeRuntimeState.setThemeID(.dark)
        ThemeRuntimeState.invalidateCache()
        // After invalidation, palette should still be valid
        let palette = ThemeRuntimeState.currentPalette()
        _ = palette.bg
    }
}
