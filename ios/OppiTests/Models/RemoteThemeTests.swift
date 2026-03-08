import Foundation
import Testing
@testable import Oppi

/// Tests for RemoteTheme JSON parsing and palette conversion.
@Suite("RemoteTheme")
struct RemoteThemeTests {

    // MARK: - Full JSON decoding

    @Test func decodesValidFullThemeJSON() throws {
        let json = makeFullThemeJSON(name: "Dracula", colorScheme: "dark")
        let theme = try JSONDecoder().decode(RemoteTheme.self, from: json)
        #expect(theme.name == "Dracula")
        #expect(theme.colorScheme == "dark")
        #expect(theme.colors.bg == "#282a36")
        #expect(theme.colors.fg == "#f8f8f2")
        #expect(theme.colors.blue == "#8be9fd")
    }

    @Test func decodesThemeWithNilColorScheme() throws {
        let json = makeFullThemeJSON(name: "Minimal", colorScheme: nil)
        let theme = try JSONDecoder().decode(RemoteTheme.self, from: json)
        #expect(theme.name == "Minimal")
        #expect(theme.colorScheme == nil)
    }

    @Test func decodingFailsWithMissingRequiredField() {
        // Remove "bg" from colors — should fail decoding
        var jsonString = String(data: makeFullThemeJSON(name: "Bad", colorScheme: "dark"), encoding: .utf8)!
        jsonString = jsonString.replacingOccurrences(of: "\"bg\": \"#282a36\",", with: "")
        let data = Data(jsonString.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RemoteTheme.self, from: data)
        }
    }

    // MARK: - toPalette conversion

    @Test func toPaletteSucceedsWithValidHexColors() throws {
        let json = makeFullThemeJSON(name: "Test", colorScheme: "dark")
        let theme = try JSONDecoder().decode(RemoteTheme.self, from: json)
        let palette = theme.toPalette()
        #expect(palette != nil)
    }

    @Test func toPaletteFailsWithInvalidBaseHex() throws {
        // If a base color has an invalid hex, toPalette returns nil
        var jsonString = String(data: makeFullThemeJSON(name: "Bad", colorScheme: "dark"), encoding: .utf8)!
        // Corrupt the "bg" value to be invalid hex
        jsonString = jsonString.replacingOccurrences(of: "\"bg\": \"#282a36\"", with: "\"bg\": \"not-hex\"")
        let data = Data(jsonString.utf8)
        let theme = try JSONDecoder().decode(RemoteTheme.self, from: data)
        let palette = theme.toPalette()
        #expect(palette == nil, "toPalette should return nil when a base color is invalid hex")
    }

    @Test func toPaletteFallsBackForInvalidSemanticHex() throws {
        // Semantic colors (e.g. thinkingText) fall back to derived values when invalid
        var jsonString = String(data: makeFullThemeJSON(name: "Fallback", colorScheme: "dark"), encoding: .utf8)!
        jsonString = jsonString.replacingOccurrences(
            of: "\"thinkingText\": \"#6272a4\"",
            with: "\"thinkingText\": \"invalid\""
        )
        let data = Data(jsonString.utf8)
        let theme = try JSONDecoder().decode(RemoteTheme.self, from: data)
        let palette = theme.toPalette()
        // Should still succeed — semantic tokens fall back to derived values
        #expect(palette != nil)
    }

    // MARK: - RemoteThemeSummary

    @Test func themeSummaryIdIsFilename() throws {
        let json = Data("""
        {"name": "Nord", "filename": "nord.json", "colorScheme": "dark"}
        """.utf8)
        let summary = try JSONDecoder().decode(RemoteThemeSummary.self, from: json)
        #expect(summary.id == "nord.json")
        #expect(summary.name == "Nord")
        #expect(summary.colorScheme == "dark")
    }

    // MARK: - Hex edge cases in Color init

    @Test func toPaletteHandlesColorsWithoutHash() throws {
        // The hex parser strips the # prefix — test that colors with bare hex work
        var jsonString = String(data: makeFullThemeJSON(name: "NoHash", colorScheme: "dark"), encoding: .utf8)!
        // Change bg from "#282a36" to "282a36" (no hash)
        jsonString = jsonString.replacingOccurrences(of: "\"bg\": \"#282a36\"", with: "\"bg\": \"282a36\"")
        let data = Data(jsonString.utf8)
        let theme = try JSONDecoder().decode(RemoteTheme.self, from: data)
        let palette = theme.toPalette()
        #expect(palette != nil, "Hex colors without # prefix should parse successfully")
    }

    @Test func toPaletteRejectsShortHex() throws {
        // 3-digit hex like "#abc" should fail — the parser only handles 6-digit
        var jsonString = String(data: makeFullThemeJSON(name: "Short", colorScheme: "dark"), encoding: .utf8)!
        jsonString = jsonString.replacingOccurrences(of: "\"bg\": \"#282a36\"", with: "\"bg\": \"#abc\"")
        let data = Data(jsonString.utf8)
        let theme = try JSONDecoder().decode(RemoteTheme.self, from: data)
        let palette = theme.toPalette()
        // bg is a base color — if it fails, the whole palette is nil
        #expect(palette == nil, "3-digit hex should not parse as a valid color")
    }

    @Test func toPaletteRejectsEmptyHex() throws {
        var jsonString = String(data: makeFullThemeJSON(name: "Empty", colorScheme: "dark"), encoding: .utf8)!
        jsonString = jsonString.replacingOccurrences(of: "\"bg\": \"#282a36\"", with: "\"bg\": \"\"")
        let data = Data(jsonString.utf8)
        let theme = try JSONDecoder().decode(RemoteTheme.self, from: data)
        let palette = theme.toPalette()
        #expect(palette == nil)
    }

    @Test func toPaletteRejectsWhitespaceOnlyHex() throws {
        var jsonString = String(data: makeFullThemeJSON(name: "WS", colorScheme: "dark"), encoding: .utf8)!
        jsonString = jsonString.replacingOccurrences(of: "\"bg\": \"#282a36\"", with: "\"bg\": \"   \"")
        let data = Data(jsonString.utf8)
        let theme = try JSONDecoder().decode(RemoteTheme.self, from: data)
        let palette = theme.toPalette()
        #expect(palette == nil)
    }

    // MARK: - Helpers

    private func makeFullThemeJSON(name: String, colorScheme: String?) -> Data {
        let csField: String
        if let colorScheme {
            csField = "\"colorScheme\": \"\(colorScheme)\","
        } else {
            csField = "\"colorScheme\": null,"
        }

        return Data("""
        {
            "name": "\(name)",
            \(csField)
            "colors": {
                "bg": "#282a36",
                "bgDark": "#1e1f29",
                "bgHighlight": "#44475a",
                "fg": "#f8f8f2",
                "fgDim": "#6272a4",
                "comment": "#6272a4",
                "blue": "#8be9fd",
                "cyan": "#8be9fd",
                "green": "#50fa7b",
                "orange": "#ffb86c",
                "purple": "#bd93f9",
                "red": "#ff5555",
                "yellow": "#f1fa8c",
                "thinkingText": "#6272a4",
                "userMessageBg": "#44475a",
                "userMessageText": "#f8f8f2",
                "toolPendingBg": "#3a3d4e",
                "toolSuccessBg": "#2a3a2e",
                "toolErrorBg": "#3a2a2a",
                "toolTitle": "#f8f8f2",
                "toolOutput": "#6272a4",
                "mdHeading": "#8be9fd",
                "mdLink": "#8be9fd",
                "mdLinkUrl": "#6272a4",
                "mdCode": "#8be9fd",
                "mdCodeBlock": "#50fa7b",
                "mdCodeBlockBorder": "#44475a",
                "mdQuote": "#6272a4",
                "mdQuoteBorder": "#44475a",
                "mdHr": "#44475a",
                "mdListBullet": "#ffb86c",
                "toolDiffAdded": "#50fa7b",
                "toolDiffRemoved": "#ff5555",
                "toolDiffContext": "#6272a4",
                "syntaxComment": "#6272a4",
                "syntaxKeyword": "#bd93f9",
                "syntaxFunction": "#8be9fd",
                "syntaxVariable": "#f8f8f2",
                "syntaxString": "#50fa7b",
                "syntaxNumber": "#ffb86c",
                "syntaxType": "#8be9fd",
                "syntaxOperator": "#f8f8f2",
                "syntaxPunctuation": "#6272a4",
                "thinkingOff": "#44475a",
                "thinkingMinimal": "#6272a4",
                "thinkingLow": "#8be9fd",
                "thinkingMedium": "#8be9fd",
                "thinkingHigh": "#bd93f9",
                "thinkingXhigh": "#ff5555"
            }
        }
        """.utf8)
    }
}
