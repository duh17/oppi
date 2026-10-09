import Foundation
import SwiftUI
import Testing
import UIKit
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

    @Test func decodingFailsWithMissingRequiredField() throws {
        // Remove "bg" from colors — should fail decoding
        var jsonString = try makeFullThemeJSONString(name: "Bad", colorScheme: "dark")
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
        var jsonString = try makeFullThemeJSONString(name: "Bad", colorScheme: "dark")
        // Corrupt the "bg" value to be invalid hex
        jsonString = jsonString.replacingOccurrences(of: "\"bg\": \"#282a36\"", with: "\"bg\": \"not-hex\"")
        let data = Data(jsonString.utf8)
        let theme = try JSONDecoder().decode(RemoteTheme.self, from: data)
        let palette = theme.toPalette()
        #expect(palette == nil, "toPalette should return nil when a base color is invalid hex")
    }

    @Test func decodesThemeMissingOptionalSpeakerTokens() throws {
        let json = makeFullThemeJSON(name: "Legacy", colorScheme: "dark")
        let theme = try JSONDecoder().decode(RemoteTheme.self, from: json)
        #expect(theme.colors.assistantMessageBg == nil)
        #expect(theme.colors.userMessageAccent == nil)
        let palette = try #require(theme.toPalette())
        let resolved = UIColor(palette.assistantMessageBg).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .dark)
        )
        var assistantAlpha: CGFloat = 1
        if !resolved.getRed(nil, green: nil, blue: nil, alpha: &assistantAlpha) {
            assistantAlpha = resolved.cgColor.alpha
        }
        #expect(assistantAlpha < 0.02)
        #expect(remoteThemeColor(palette.userMessageAccent, approximatelyEquals: palette.blue))
    }

    @Test func decodesThemeProvidingOptionalSpeakerTokens() throws {
        var jsonString = try makeFullThemeJSONString(name: "Custom", colorScheme: "dark")
        jsonString = jsonString.replacingOccurrences(
            of: "\"userMessageText\": \"#f8f8f2\",",
            with: "\"userMessageText\": \"#f8f8f2\",\"assistantMessageBg\": \"#1b1c28\",\"userMessageAccent\": \"#ff79c6\","
        )
        let theme = try JSONDecoder().decode(RemoteTheme.self, from: Data(jsonString.utf8))
        #expect(theme.colors.assistantMessageBg == "#1b1c28")
        #expect(theme.colors.userMessageAccent == "#ff79c6")
        let palette = try #require(theme.toPalette())
        #expect(remoteThemeColor(palette.assistantMessageBg, approximatelyEquals: Color(red: 27 / 255, green: 28 / 255, blue: 40 / 255)))
        #expect(remoteThemeColor(palette.userMessageAccent, approximatelyEquals: Color(red: 1, green: 121 / 255, blue: 198 / 255)))
    }

    @Test func toPaletteFallsBackForInvalidSemanticHex() throws {
        // Semantic colors (e.g. thinkingText) fall back to derived values when invalid
        var jsonString = try makeFullThemeJSONString(name: "Fallback", colorScheme: "dark")
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
        var jsonString = try makeFullThemeJSONString(name: "NoHash", colorScheme: "dark")
        // Change bg from "#282a36" to "282a36" (no hash)
        jsonString = jsonString.replacingOccurrences(of: "\"bg\": \"#282a36\"", with: "\"bg\": \"282a36\"")
        let data = Data(jsonString.utf8)
        let theme = try JSONDecoder().decode(RemoteTheme.self, from: data)
        let palette = theme.toPalette()
        #expect(palette != nil, "Hex colors without # prefix should parse successfully")
    }

    @Test func toPaletteRejectsShortHex() throws {
        // 3-digit hex like "#abc" should fail — the parser only handles 6-digit
        var jsonString = try makeFullThemeJSONString(name: "Short", colorScheme: "dark")
        jsonString = jsonString.replacingOccurrences(of: "\"bg\": \"#282a36\"", with: "\"bg\": \"#abc\"")
        let data = Data(jsonString.utf8)
        let theme = try JSONDecoder().decode(RemoteTheme.self, from: data)
        let palette = theme.toPalette()
        // bg is a base color — if it fails, the whole palette is nil
        #expect(palette == nil, "3-digit hex should not parse as a valid color")
    }

    @Test func toPaletteRejectsEmptyHex() throws {
        var jsonString = try makeFullThemeJSONString(name: "Empty", colorScheme: "dark")
        jsonString = jsonString.replacingOccurrences(of: "\"bg\": \"#282a36\"", with: "\"bg\": \"\"")
        let data = Data(jsonString.utf8)
        let theme = try JSONDecoder().decode(RemoteTheme.self, from: data)
        let palette = theme.toPalette()
        #expect(palette == nil)
    }

    @Test func toPaletteRejectsWhitespaceOnlyHex() throws {
        var jsonString = try makeFullThemeJSONString(name: "WS", colorScheme: "dark")
        jsonString = jsonString.replacingOccurrences(of: "\"bg\": \"#282a36\"", with: "\"bg\": \"   \"")
        let data = Data(jsonString.utf8)
        let theme = try JSONDecoder().decode(RemoteTheme.self, from: data)
        let palette = theme.toPalette()
        #expect(palette == nil)
    }

    // MARK: - Helpers

    private func remoteThemeColor(_ lhs: Color, approximatelyEquals rhs: Color, tolerance: CGFloat = 0.02) -> Bool {
        var lR: CGFloat = 0, lG: CGFloat = 0, lB: CGFloat = 0, lA: CGFloat = 0
        var rR: CGFloat = 0, rG: CGFloat = 0, rB: CGFloat = 0, rA: CGFloat = 0
        UIColor(lhs).getRed(&lR, green: &lG, blue: &lB, alpha: &lA)
        UIColor(rhs).getRed(&rR, green: &rG, blue: &rB, alpha: &rA)
        return abs(lR - rR) <= tolerance
            && abs(lG - rG) <= tolerance
            && abs(lB - rB) <= tolerance
            && abs(lA - rA) <= tolerance
    }

    private func makeFullThemeJSONString(name: String, colorScheme: String?) throws -> String {
        try #require(
            String(bytes: makeFullThemeJSON(name: name, colorScheme: colorScheme), encoding: .utf8),
            "Expected UTF-8 test JSON"
        )
    }

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
