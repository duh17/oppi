import Foundation
import SwiftUI
import UIKit
import os

/// Color palette for the entire app — 49 tokens.
///
/// 13 base colors (used by `Color.theme*` static accessors) plus 36 semantic
/// tokens for UI surfaces, syntax highlighting, markdown, diffs, and thinking.
struct ThemePalette: Sendable, ProviderIconTintPalette {
    // ── Base (13) ──
    let bg: Color
    let bgDark: Color
    let bgHighlight: Color
    let fg: Color
    let fgDim: Color
    let comment: Color
    let blue: Color
    let cyan: Color
    let green: Color
    let orange: Color
    let purple: Color
    let red: Color
    let yellow: Color

    // ── Thinking text (1) ──
    let thinkingText: Color

    // ── User message (2) ──
    let userMessageBg: Color
    let userMessageText: Color

    // ── Tool state (5) ──
    let toolPendingBg: Color
    let toolSuccessBg: Color
    let toolErrorBg: Color
    let toolTitle: Color
    let toolOutput: Color

    // ── Markdown (10) ──
    let mdHeading: Color
    let mdLink: Color
    let mdLinkUrl: Color
    let mdCode: Color
    let mdCodeBlock: Color
    let mdCodeBlockBorder: Color
    let mdQuote: Color
    let mdQuoteBorder: Color
    let mdHr: Color
    let mdListBullet: Color

    // ── Diffs (3) ──
    let toolDiffAdded: Color
    let toolDiffRemoved: Color
    let toolDiffContext: Color

    // ── Syntax (9) ──
    let syntaxComment: Color
    let syntaxKeyword: Color
    let syntaxFunction: Color
    let syntaxVariable: Color
    let syntaxString: Color
    let syntaxNumber: Color
    let syntaxType: Color
    let syntaxOperator: Color
    let syntaxPunctuation: Color

    // ── Thinking levels (6) ──
    let thinkingOff: Color
    let thinkingMinimal: Color
    let thinkingLow: Color
    let thinkingMedium: Color
    let thinkingHigh: Color
    let thinkingXhigh: Color
}

// MARK: - Convenience Initializer (base 13 → derive rest)

// periphery:ignore - used by ThemeImportView for custom theme creation
extension ThemePalette {
    /// Create a palette from 13 base colors, deriving all semantic tokens.
    /// Used when importing themes that only specify core colors.
    init(
        bg: Color, bgDark: Color, bgHighlight: Color,
        fg: Color, fgDim: Color, comment: Color,
        blue: Color, cyan: Color, green: Color,
        orange: Color, purple: Color, red: Color, yellow: Color
    ) {
        self.bg = bg; self.bgDark = bgDark; self.bgHighlight = bgHighlight
        self.fg = fg; self.fgDim = fgDim; self.comment = comment
        self.blue = blue; self.cyan = cyan; self.green = green
        self.orange = orange; self.purple = purple; self.red = red; self.yellow = yellow

        self.thinkingText = fgDim

        self.userMessageBg = bgHighlight
        self.userMessageText = fg

        self.toolPendingBg = blue.opacity(0.12)
        self.toolSuccessBg = green.opacity(0.08)
        self.toolErrorBg = red.opacity(0.10)
        self.toolTitle = fg
        self.toolOutput = fgDim

        self.mdHeading = blue
        self.mdLink = cyan
        self.mdLinkUrl = comment
        self.mdCode = cyan
        self.mdCodeBlock = green
        self.mdCodeBlockBorder = fgDim
        self.mdQuote = fgDim
        self.mdQuoteBorder = fgDim
        self.mdHr = fgDim
        self.mdListBullet = orange

        self.toolDiffAdded = green
        self.toolDiffRemoved = red
        self.toolDiffContext = fgDim

        self.syntaxComment = comment
        self.syntaxKeyword = purple
        self.syntaxFunction = blue
        self.syntaxVariable = fg
        self.syntaxString = green
        self.syntaxNumber = orange
        self.syntaxType = cyan
        self.syntaxOperator = fg
        self.syntaxPunctuation = fgDim

        self.thinkingOff = comment
        self.thinkingMinimal = fgDim
        self.thinkingLow = blue
        self.thinkingMedium = cyan
        self.thinkingHigh = purple
        self.thinkingXhigh = red
    }
}

// MARK: - Theme IDs

enum ThemeID: Hashable, Codable, Sendable {
    case dark
    case oled
    case neutralDark
    case light
    case neutralLight
    case night
    case custom(String)

    /// Built-in themes (shipped in the app). Custom/imported themes added separately.
    static let builtins: [Self] = [.dark, .oled, .neutralDark, .light, .neutralLight, .night]

    static let storageKey = "\(AppIdentifiers.subsystem).theme.id"

    /// Stable string ID for persistence.
    var rawValue: String {
        switch self {
        case .dark: return "dark"
        case .oled: return "oled"
        case .neutralDark: return "neutral-dark"
        case .light: return "light"
        case .neutralLight: return "neutral-light"
        case .night: return "night"
        case .custom(let name): return "custom:\(name)"
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "dark": self = .dark
        case "oled": self = .oled
        case "neutral-dark": self = .neutralDark
        case "light": self = .light
        case "neutral-light": self = .neutralLight
        case "night": self = .night
        default:
            if rawValue.hasPrefix("custom:") {
                self = .custom(String(rawValue.dropFirst("custom:".count)))
            } else {
                self = .dark
            }
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(rawValue: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func loadPersisted() -> Self {
        guard let raw = UserDefaults.standard.string(forKey: storageKey)
        else { return .dark }
        return Self(rawValue: raw)
    }

    var displayName: String {
        switch self {
        case .dark: return "Dark"
        case .oled: return "OLED"
        case .neutralDark: return "Neutral Dark"
        case .light: return "Light"
        case .neutralLight: return "Neutral Light"
        case .night: return "Night"
        case .custom(let name): return name
        }
    }

    var detail: String {
        switch self {
        case .dark:
            return "Deep ink dark with calm editor-style contrast."
        case .oled:
            return "True black OLED dark with modern accents for dark rooms."
        case .neutralDark:
            return "Neutral dark chat styling with content-colored headings and readable syntax colors."
        case .light:
            return "Latte-inspired light with soft, lower-chroma accents."
        case .neutralLight:
            return "Neutral light chat styling with content-colored headings and readable syntax colors."
        case .night:
            return "Warm low-stimulation dark for late-night reading."
        case .custom:
            return ""
        }
    }

    var preferredColorScheme: ColorScheme {
        switch self {
        case .dark, .oled, .neutralDark, .night:
            return .dark
        case .light, .neutralLight:
            return .light
        case .custom(let name):
            // Infer from saved theme metadata, default dark
            if let remote = CustomThemeStore.load(name: name) {
                return remote.colorScheme == "light" ? .light : .dark
            }
            return .dark
        }
    }

    var palette: ThemePalette {
        switch self {
        case .dark:
            return ThemePalettes.dark
        case .oled:
            return ThemePalettes.oled
        case .neutralDark:
            return ThemePalettes.neutralDark
        case .light:
            return ThemePalettes.light
        case .neutralLight:
            return ThemePalettes.neutralLight
        case .night:
            return ThemePalettes.night
        case .custom(let name):
            if let remote = CustomThemeStore.load(name: name),
               let palette = remote.toPalette() {
                return palette
            }
            return ThemePalettes.dark // fallback
        }
    }
}

// MARK: - Built-in Palettes

// swiftlint:disable function_body_length
enum ThemePalettes {
    // Helper to build Color from hex literal
    private static func c(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }

    /// Dark — deep ink editor theme inspired by Tokyo Night, pushed a touch darker.
    ///
    /// Uses layered navy-charcoal surfaces instead of pure black so chat, code,
    /// tool output, and dividers keep their shape without feeling washed out.
    static let dark = ThemePalette(
        // Base 13
        bg: c(0x1A1D29),
        bgDark: c(0x151823),
        bgHighlight: c(0x252B3D),
        fg: c(0xC8D1EB),
        fgDim: c(0xA2ACC9),
        comment: c(0x98A4C4),
        blue: c(0x7AA2F7),
        cyan: c(0x78C8F2),
        green: c(0x8FBE78),
        orange: c(0xD8A86C),
        purple: c(0xA08FD4),
        red: c(0xE07A8C),
        yellow: c(0xD4B06A),
        thinkingText: c(0x8E98B7),
        // User message
        userMessageBg: c(0x252B3D),
        userMessageText: c(0xC8D1EB),
        // Tool state
        toolPendingBg: c(0x7AA2F7).opacity(0.13),
        toolSuccessBg: c(0x8FBE78).opacity(0.10),
        toolErrorBg: c(0xE07A8C).opacity(0.10),
        toolTitle: c(0xC8D1EB),
        toolOutput: c(0xA2ACC9),
        // Markdown
        mdHeading: c(0x7AA2F7),
        mdLink: c(0x78C8F2),
        mdLinkUrl: c(0x98A4C4),
        mdCode: c(0x78C8F2),
        mdCodeBlock: c(0x8FBE78),
        mdCodeBlockBorder: c(0x31384D),
        mdQuote: c(0xA2ACC9),
        mdQuoteBorder: c(0x31384D),
        mdHr: c(0x31384D),
        mdListBullet: c(0xD8A86C),
        // Diffs
        toolDiffAdded: c(0x73B07C),
        toolDiffRemoved: c(0xCC7488),
        toolDiffContext: c(0x98A4C4),
        // Syntax (Tokyo Night-ish, but slightly calmer)
        syntaxComment: c(0x98A4C4),
        syntaxKeyword: c(0xA08FD4),
        syntaxFunction: c(0x7AA2F7),
        syntaxVariable: c(0xC8D1EB),
        syntaxString: c(0x8FBE78),
        syntaxNumber: c(0xD8A86C),
        syntaxType: c(0x78C8F2),
        syntaxOperator: c(0xC8D1EB),
        syntaxPunctuation: c(0xA2ACC9),
        // Thinking (slate → blue → cyan → soft violet)
        thinkingOff: c(0x31384D),
        thinkingMinimal: c(0x505A78),
        thinkingLow: c(0x5E82C6),
        thinkingMedium: c(0x67B4DD),
        thinkingHigh: c(0xA08FD4),
        thinkingXhigh: c(0xB596DE)
    )

    /// OLED — true black variant of Dark for dark rooms and battery maximalism.
    ///
    /// Keeps the same cool, modern family as Dark, but tightens the surfaces all
    /// the way down to black. Secondary text is intentionally brighter than the
    /// first pass so bash/tool output stays readable.
    static let oled = ThemePalette(
        // Base 13 — pure dark, softer accents
        bg: c(0x000000),
        bgDark: c(0x080C15),
        bgHighlight: c(0x121822),
        fg: c(0xC5CEEA),
        fgDim: c(0xA5AEC8),
        comment: c(0x8C96B5),
        blue: c(0x7A9DD5),
        cyan: c(0x70B5C8),
        green: c(0x85BF8A),
        orange: c(0xD0A268),
        purple: c(0x8880B8),
        red: c(0xD87888),
        yellow: c(0xCCAE68),
        thinkingText: c(0x95A0C0),
        // User message
        userMessageBg: c(0x121822),
        userMessageText: c(0xC5CEEA),
        // Tool state
        toolPendingBg: c(0x7A9DD5).opacity(0.12),
        toolSuccessBg: c(0x85BF8A).opacity(0.08),
        toolErrorBg: c(0xD87888).opacity(0.08),
        toolTitle: c(0xC5CEEA),
        toolOutput: c(0xA5AEC8),
        // Markdown
        mdHeading: c(0x7A9DD5),
        mdLink: c(0x70B5C8),
        mdLinkUrl: c(0x8C96B5),
        mdCode: c(0x70B5C8),
        mdCodeBlock: c(0x85BF8A),
        mdCodeBlockBorder: c(0x1E2535),
        mdQuote: c(0xA5AEC8),
        mdQuoteBorder: c(0x1E2535),
        mdHr: c(0x1E2535),
        mdListBullet: c(0xD0A268),
        // Diffs
        toolDiffAdded: c(0x6DAF78),
        toolDiffRemoved: c(0xC87388),
        toolDiffContext: c(0x8C96B5),
        // Syntax — blue keywords, softer palette
        syntaxComment: c(0x8C96B5),
        syntaxKeyword: c(0x7A9DD5),
        syntaxFunction: c(0x7A9DD5),
        syntaxVariable: c(0xC5CEEA),
        syntaxString: c(0x85BF8A),
        syntaxNumber: c(0xD0A268),
        syntaxType: c(0x70B5C8),
        syntaxOperator: c(0xC5CEEA),
        syntaxPunctuation: c(0xA5AEC8),
        // Thinking
        thinkingOff: c(0x1C2230),
        thinkingMinimal: c(0x3E4860),
        thinkingLow: c(0x5878B0),
        thinkingMedium: c(0x5CA8C0),
        thinkingHigh: c(0x8880B8),
        thinkingXhigh: c(0xA890C5)
    )

    /// Night — warm dark-room theme with low-saturation accents.
    ///
    /// Designed for reading in the dark. Key choices:
    /// - Near-black background (#0E0D0B) avoids OLED smearing vs pure #000000
    /// - Warm parchment text (#C8BFB0) reduces blue light and glare
    /// - ~10:1 contrast ratio (vs 21:1 max) — easier on dark-adapted eyes
    /// - All accents warm-shifted: amber hero, blues → steel, cyans → sage teal
    /// - Low saturation across the board — nothing screams at dilated pupils
    static let night = ThemePalette(
        // Base 13
        bg: c(0x0E0D0B),  // warm near-black (OLED friendly, avoids smear)
        bgDark: c(0x080807),  // deepest shadow (code blocks)
        bgHighlight: c(0x1C1A18),  // warm dark elevation
        fg: c(0xC8BFB0),  // warm parchment (~10.5:1 contrast on bg)
        fgDim: c(0x9C9488),  // warm stone (brightened for readability) (~5:1)
        comment: c(0x9C9488),  // warm ash (brightened for readability)
        blue: c(0x7E90A4),  // dusty steel (warm blue, desaturated)
        cyan: c(0x6E9C94),  // sage teal (shifted green, minimal blue)
        green: c(0x7C9C6E),  // forest moss
        orange: c(0xC49468),  // warm amber (hero accent)
        purple: c(0x9684AA),  // dusty plum
        red: c(0xB86C6E),  // muted rose
        yellow: c(0xB4A270),  // wheat gold
        thinkingText: c(0x9C9488),
        // User message
        userMessageBg: c(0x1C1A18),
        userMessageText: c(0xC8BFB0),
        // Tool state
        toolPendingBg: c(0xC49468).opacity(0.10),
        toolSuccessBg: c(0x7C9C6E).opacity(0.08),
        toolErrorBg: c(0xB86C6E).opacity(0.08),
        toolTitle: c(0xC8BFB0),
        toolOutput: c(0x9C9488),
        // Markdown
        mdHeading: c(0x7E90A4),  // dusty steel
        mdLink: c(0x6E9C94),  // sage teal
        mdLinkUrl: c(0x9C9488),
        mdCode: c(0x6E9C94),  // sage teal
        mdCodeBlock: c(0x7C9C6E),  // moss
        mdCodeBlockBorder: c(0x2A2826),
        mdQuote: c(0x9C9488),
        mdQuoteBorder: c(0x2A2826),
        mdHr: c(0x2A2826),
        mdListBullet: c(0xC49468),  // amber
        // Diffs
        toolDiffAdded: c(0x6A9060),  // earthy green
        toolDiffRemoved: c(0xA85858),  // deep warm red
        toolDiffContext: c(0x9C9488),
        // Syntax (warm-shifted, muted)
        syntaxComment: c(0x9C9488),
        syntaxKeyword: c(0x9684AA),  // dusty plum
        syntaxFunction: c(0x7E90A4),  // dusty steel
        syntaxVariable: c(0xC8BFB0),
        syntaxString: c(0xBD7072),  // muted rose (brightened for AA)
        syntaxNumber: c(0xC49468),  // amber
        syntaxType: c(0x6E9C94),  // sage teal
        syntaxOperator: c(0xC8BFB0),
        syntaxPunctuation: c(0x9C9488),
        // Thinking (warm monochromatic)
        thinkingOff: c(0x3A3632),
        thinkingMinimal: c(0x5C5650),
        thinkingLow: c(0x6E7880),
        thinkingMedium: c(0x7A8A98),
        thinkingHigh: c(0x8A80A0),
        thinkingXhigh: c(0xA87890)
    )

    /// Light — Latte Things-inspired light theme with softer accent chroma.
    ///
    /// Uses the warm paper/granite surfaces from the bundled Latte Things theme,
    /// but tones the mauve family down so the overall UI leans more blue/teal
    /// than purple.
    static let light = ThemePalette(
        // Warm paper base — grey-warm, not yellow
        bg: c(0xF5F3EF),
        bgDark: c(0xEBE9E4),
        bgHighlight: c(0xDEDBD5),
        fg: c(0x3A3330),
        fgDim: c(0x5F5650),
        comment: c(0x665D53),
        blue: c(0x2966A8),
        cyan: c(0x186C75),
        green: c(0x527020),
        orange: c(0xA84C15),
        purple: c(0x6A5C90),
        red: c(0xC43520),
        yellow: c(0x7D5F14),
        thinkingText: c(0x5F5650),
        // User message
        userMessageBg: c(0xE5E3DD),
        userMessageText: c(0x3A3330),
        // Tool state
        toolPendingBg: c(0xE2E0DA),
        toolSuccessBg: c(0xE2EADB),
        toolErrorBg: c(0xF0DDD8),
        toolTitle: c(0x3A3330),
        toolOutput: c(0x5F5650),
        // Markdown
        mdHeading: c(0x2966A8),
        mdLink: c(0x186C75),
        mdLinkUrl: c(0x665D53),
        mdCode: c(0x186C75),
        mdCodeBlock: c(0x527020),
        mdCodeBlockBorder: c(0x665D53),
        mdQuote: c(0x665D53),
        mdQuoteBorder: c(0xC8C2B5),
        mdHr: c(0x7D5F14),
        mdListBullet: c(0xA84C15),
        // Diffs
        toolDiffAdded: c(0x2A8D6F),
        toolDiffRemoved: c(0xC4503A),
        toolDiffContext: c(0x665D53),
        // Syntax — warm: blue keywords, orange strings, teal types
        syntaxComment: c(0x665D53),
        syntaxKeyword: c(0x2966A8),
        syntaxFunction: c(0x2966A8),
        syntaxVariable: c(0x3A3330),
        syntaxString: c(0xA84C15),
        syntaxNumber: c(0x7D5F14),
        syntaxType: c(0x186C75),
        syntaxOperator: c(0x2966A8),
        syntaxPunctuation: c(0x5F5650),
        // Thinking
        thinkingOff: c(0xB5AFA5),
        thinkingMinimal: c(0x665D53),
        thinkingLow: c(0x186C75),
        thinkingMedium: c(0x2966A8),
        thinkingHigh: c(0x6A5C90),
        thinkingXhigh: c(0xB06090)
    )

    /// Neutral Dark — content-first chat theme with restrained chrome.
    ///
    /// Headings use the main foreground color so markdown reads like prose, not
    /// navigation. Links and code keep distinct accents, and syntax colors stay
    /// above AA contrast on the dark code surface.
    static let neutralDark = ThemePalette(
        // Base 13
        bg: c(0x171717),
        bgDark: c(0x111111),
        bgHighlight: c(0x242424),
        fg: c(0xECECEC),
        fgDim: c(0xB7B7B0),
        comment: c(0x8A8A84),
        blue: c(0x4F8EF7),
        cyan: c(0x2BA6A0),
        green: c(0x75A979),
        orange: c(0xC8894A),
        purple: c(0xB58AE6),
        red: c(0xE06C75),
        yellow: c(0xC9A646),
        thinkingText: c(0xB7B7B0),
        // User message
        userMessageBg: c(0x2A2A2A),
        userMessageText: c(0xF2F2ED),
        // Tool state
        toolPendingBg: c(0x1E2735),
        toolSuccessBg: c(0x1D2A20),
        toolErrorBg: c(0x2D1D20),
        toolTitle: c(0xECECEC),
        toolOutput: c(0xB7B7B0),
        // Markdown
        mdHeading: c(0xECECEC),
        mdLink: c(0x7DB3FF),
        mdLinkUrl: c(0x8A8A84),
        mdCode: c(0xE6B07E),
        mdCodeBlock: c(0xECECEC),
        mdCodeBlockBorder: c(0x3A3A36),
        mdQuote: c(0xB7B7B0),
        mdQuoteBorder: c(0x3A3A36),
        mdHr: c(0x3A3A36),
        mdListBullet: c(0x8A8A84),
        // Diffs
        toolDiffAdded: c(0x75A979),
        toolDiffRemoved: c(0xE06C75),
        toolDiffContext: c(0x8A8A84),
        // Syntax — colorful, but quieter than the chrome
        syntaxComment: c(0x8A8A84),
        syntaxKeyword: c(0xB58AE6),
        syntaxFunction: c(0x82AAFF),
        syntaxVariable: c(0xECECEC),
        syntaxString: c(0x8FBC8F),
        syntaxNumber: c(0xD19A66),
        syntaxType: c(0x56B6C2),
        syntaxOperator: c(0xD4D4D4),
        syntaxPunctuation: c(0xA8A8A0),
        // Thinking
        thinkingOff: c(0x3A3A36),
        thinkingMinimal: c(0x5F5F59),
        thinkingLow: c(0x4F8EF7),
        thinkingMedium: c(0x2BA6A0),
        thinkingHigh: c(0xB58AE6),
        thinkingXhigh: c(0xE06C75)
    )

    /// Neutral Light — warm off-white chat theme with restrained accents.
    ///
    /// Headings stay foreground-colored, while links, inline code, and syntax
    /// tokens carry the color. The code palette uses darker hues so highlighted
    /// code remains readable on the light code surface.
    static let neutralLight = ThemePalette(
        // Base 13
        bg: c(0xF7F7F4),
        bgDark: c(0xEFEFEB),
        bgHighlight: c(0xE6E6E0),
        fg: c(0x2F2F2C),
        fgDim: c(0x5A5954),
        comment: c(0x5F6368),
        blue: c(0x1D4ED8),
        cyan: c(0x0F766E),
        green: c(0x166534),
        orange: c(0x9A3412),
        purple: c(0x6D28D9),
        red: c(0xB91C1C),
        yellow: c(0x735C0F),
        thinkingText: c(0x5A5954),
        // User message
        userMessageBg: c(0xECECE7),
        userMessageText: c(0x2F2F2C),
        // Tool state
        toolPendingBg: c(0xE5EAF5),
        toolSuccessBg: c(0xE3EBDD),
        toolErrorBg: c(0xF0E1DF),
        toolTitle: c(0x2F2F2C),
        toolOutput: c(0x5A5954),
        // Markdown
        mdHeading: c(0x2F2F2C),
        mdLink: c(0x1D4ED8),
        mdLinkUrl: c(0x5F6368),
        mdCode: c(0x9A3412),
        mdCodeBlock: c(0x2F2F2C),
        mdCodeBlockBorder: c(0xD4D4CC),
        mdQuote: c(0x5A5954),
        mdQuoteBorder: c(0xD4D4CC),
        mdHr: c(0xD4D4CC),
        mdListBullet: c(0x5F6368),
        // Diffs
        toolDiffAdded: c(0x166534),
        toolDiffRemoved: c(0xB91C1C),
        toolDiffContext: c(0x5F6368),
        // Syntax — darker accents for contrast on the light code surface
        syntaxComment: c(0x5F6368),
        syntaxKeyword: c(0x6D28D9),
        syntaxFunction: c(0x1D4ED8),
        syntaxVariable: c(0x2F2F2C),
        syntaxString: c(0x166534),
        syntaxNumber: c(0x9A3412),
        syntaxType: c(0x0F766E),
        syntaxOperator: c(0x374151),
        syntaxPunctuation: c(0x5F6368),
        // Thinking
        thinkingOff: c(0xCFCFC8),
        thinkingMinimal: c(0x77746C),
        thinkingLow: c(0x1D4ED8),
        thinkingMedium: c(0x0F766E),
        thinkingHigh: c(0x6D28D9),
        thinkingXhigh: c(0xB91C1C)
    )
}
// swiftlint:enable function_body_length

// MARK: - Runtime State

enum ThemeRuntimeState {
    private struct State {
        var themeID: ThemeID
        var palette: ThemePalette

        init(themeID: ThemeID) {
            self.themeID = themeID
            self.palette = themeID.palette
        }
    }

    private static let state = OSAllocatedUnfairLock(
        initialState: State(themeID: ThemeID.loadPersisted())
    )

    static func currentThemeID() -> ThemeID {
        state.withLock { $0.themeID }
    }

    static func setThemeID(_ themeID: ThemeID) {
        state.withLock {
            $0.themeID = themeID
            $0.palette = themeID.palette
        }
    }

    /// Cached palette — resolved once on theme change, not on every access.
    static func currentPalette() -> ThemePalette {
        state.withLock { $0.palette }
    }

    static func currentRenderTheme() -> RenderTheme {
        currentPalette().renderTheme
    }

    // periphery:ignore - API surface for future custom theme editing
    /// Force palette recomputation (e.g. after editing a custom theme's colors).
    static func invalidateCache() {
        state.withLock { $0.palette = $0.themeID.palette }
    }
}

extension ThemePalette {
    var renderTheme: RenderTheme {
        RenderTheme(
            foreground: UIColor(fg).cgColor,
            foregroundDim: UIColor(fgDim).cgColor,
            background: UIColor(bg).cgColor,
            backgroundDark: UIColor(bgDark).cgColor,
            comment: UIColor(comment).cgColor,
            keyword: UIColor(syntaxKeyword).cgColor,
            string: UIColor(syntaxString).cgColor,
            number: UIColor(syntaxNumber).cgColor,
            function: UIColor(syntaxFunction).cgColor,
            type: UIColor(syntaxType).cgColor,
            link: UIColor(mdLink).cgColor,
            heading: UIColor(mdHeading).cgColor,
            accentBlue: UIColor(blue).cgColor,
            accentCyan: UIColor(cyan).cgColor,
            accentGreen: UIColor(green).cgColor,
            accentOrange: UIColor(orange).cgColor,
            accentPurple: UIColor(purple).cgColor,
            accentRed: UIColor(red).cgColor,
            accentYellow: UIColor(yellow).cgColor
        )
    }
}
