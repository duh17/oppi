import Foundation
import SwiftUI
import UIKit
import os

/// Color palette for the entire app — 49 tokens.
///
/// 13 base colors (used by `Color.theme*` static accessors) plus 36 semantic
/// tokens for UI surfaces, syntax highlighting, markdown, diffs, and thinking.
struct ThemePalette: Sendable {
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
    case light
    case night
    case custom(String)

    /// Built-in themes (shipped in the app). Custom/imported themes added separately.
    static let builtins: [Self] = [.dark, .oled, .light, .night]

    static let storageKey = "\(AppIdentifiers.subsystem).theme.id"

    /// Stable string ID for persistence.
    var rawValue: String {
        switch self {
        case .dark: return "dark"
        case .oled: return "oled"
        case .light: return "light"
        case .night: return "night"
        case .custom(let name): return "custom:\(name)"
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "dark": self = .dark
        case "oled": self = .oled
        case "light": self = .light
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
        case .light: return "Light"
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
        case .light:
            return "Latte-inspired light with soft, lower-chroma accents."
        case .night:
            return "Warm low-stimulation dark for late-night reading."
        case .custom:
            return ""
        }
    }

    var preferredColorScheme: ColorScheme {
        switch self {
        case .dark, .oled, .night:
            return .dark
        case .light:
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
        case .light:
            return ThemePalettes.light
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
        comment: c(0x6B7390),
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
        mdLinkUrl: c(0x6B7390),
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
        toolDiffContext: c(0x6B7390),
        // Syntax (Tokyo Night-ish, but slightly calmer)
        syntaxComment: c(0x6B7390),
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
        // Base 13
        bg: c(0x000000),
        bgDark: c(0x04060D),
        bgHighlight: c(0x101522),
        fg: c(0xCAD3EE),
        fgDim: c(0xAEB8D6),
        comment: c(0x7A84A6),
        blue: c(0x76A0F4),
        cyan: c(0x76C6E6),
        green: c(0x89B971),
        orange: c(0xD7A96B),
        purple: c(0x9F8AD9),
        red: c(0xE07A8C),
        yellow: c(0xD4B06A),
        thinkingText: c(0x97A2C4),
        // User message
        userMessageBg: c(0x101522),
        userMessageText: c(0xCAD3EE),
        // Tool state
        toolPendingBg: c(0x76A0F4).opacity(0.14),
        toolSuccessBg: c(0x89B971).opacity(0.10),
        toolErrorBg: c(0xE07A8C).opacity(0.10),
        toolTitle: c(0xCAD3EE),
        toolOutput: c(0xAEB8D6),
        // Markdown
        mdHeading: c(0x76A0F4),
        mdLink: c(0x76C6E6),
        mdLinkUrl: c(0x7A84A6),
        mdCode: c(0x76C6E6),
        mdCodeBlock: c(0x89B971),
        mdCodeBlockBorder: c(0x22293B),
        mdQuote: c(0xAEB8D6),
        mdQuoteBorder: c(0x22293B),
        mdHr: c(0x22293B),
        mdListBullet: c(0xD7A96B),
        // Diffs
        toolDiffAdded: c(0x6FAF78),
        toolDiffRemoved: c(0xCC7388),
        toolDiffContext: c(0x7A84A6),
        // Syntax
        syntaxComment: c(0x7A84A6),
        syntaxKeyword: c(0x9F8AD9),
        syntaxFunction: c(0x76A0F4),
        syntaxVariable: c(0xCAD3EE),
        syntaxString: c(0x89B971),
        syntaxNumber: c(0xD7A96B),
        syntaxType: c(0x76C6E6),
        syntaxOperator: c(0xCAD3EE),
        syntaxPunctuation: c(0xAEB8D6),
        // Thinking
        thinkingOff: c(0x202637),
        thinkingMinimal: c(0x46506D),
        thinkingLow: c(0x5D80C5),
        thinkingMedium: c(0x64AFDB),
        thinkingHigh: c(0x9F8AD9),
        thinkingXhigh: c(0xB393E0)
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
        fgDim: c(0x8A8278),  // warm stone (~5:1)
        comment: c(0x625C56),  // warm ash (~3:1, intentionally low for de-emphasis)
        blue: c(0x7E90A4),  // dusty steel (warm blue, desaturated)
        cyan: c(0x6E9C94),  // sage teal (shifted green, minimal blue)
        green: c(0x7C9C6E),  // forest moss
        orange: c(0xC49468),  // warm amber (hero accent)
        purple: c(0x9684AA),  // dusty plum
        red: c(0xB86C6E),  // muted rose
        yellow: c(0xB4A270),  // wheat gold
        thinkingText: c(0x8A8278),
        // User message
        userMessageBg: c(0x1C1A18),
        userMessageText: c(0xC8BFB0),
        // Tool state
        toolPendingBg: c(0xC49468).opacity(0.10),
        toolSuccessBg: c(0x7C9C6E).opacity(0.08),
        toolErrorBg: c(0xB86C6E).opacity(0.08),
        toolTitle: c(0xC8BFB0),
        toolOutput: c(0x8A8278),
        // Markdown
        mdHeading: c(0x7E90A4),  // dusty steel
        mdLink: c(0x6E9C94),  // sage teal
        mdLinkUrl: c(0x625C56),
        mdCode: c(0x6E9C94),  // sage teal
        mdCodeBlock: c(0x7C9C6E),  // moss
        mdCodeBlockBorder: c(0x2A2826),
        mdQuote: c(0x8A8278),
        mdQuoteBorder: c(0x2A2826),
        mdHr: c(0x2A2826),
        mdListBullet: c(0xC49468),  // amber
        // Diffs
        toolDiffAdded: c(0x6A9060),  // earthy green
        toolDiffRemoved: c(0xA85858),  // deep warm red
        toolDiffContext: c(0x625C56),
        // Syntax (warm-shifted, muted)
        syntaxComment: c(0x625C56),
        syntaxKeyword: c(0x9684AA),  // dusty plum
        syntaxFunction: c(0x7E90A4),  // dusty steel
        syntaxVariable: c(0xC8BFB0),
        syntaxString: c(0xB86C6E),  // muted rose
        syntaxNumber: c(0xC49468),  // amber
        syntaxType: c(0x6E9C94),  // sage teal
        syntaxOperator: c(0xC8BFB0),
        syntaxPunctuation: c(0x8A8278),
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
        // Base 13
        bg: c(0xEFF1F5),
        bgDark: c(0xE6E9EF),
        bgHighlight: c(0xCCD0DA),
        fg: c(0x4C4F69),
        fgDim: c(0x5C5F77),
        comment: c(0x8C8FA1),
        blue: c(0x1E66F5),
        cyan: c(0x179299),
        green: c(0x40A02B),
        orange: c(0xFE640B),
        purple: c(0x6F72B8),  // softened indigo vs Latte's brighter mauve
        red: c(0xD20F39),
        yellow: c(0xDF8E1D),
        thinkingText: c(0x6C6F85),
        // User message
        userMessageBg: c(0xDCE0E8),
        userMessageText: c(0x4C4F69),
        // Tool state
        toolPendingBg: c(0xDEE3F2),
        toolSuccessBg: c(0xDFEADB),
        toolErrorBg: c(0xF0DDE0),
        toolTitle: c(0x4C4F69),
        toolOutput: c(0x6C6F85),
        // Markdown
        mdHeading: c(0x1E66F5),
        mdLink: c(0x209FB5),
        mdLinkUrl: c(0x8C8FA1),
        mdCode: c(0x179299),
        mdCodeBlock: c(0x40A02B),
        mdCodeBlockBorder: c(0x8C8FA1),
        mdQuote: c(0x8C8FA1),
        mdQuoteBorder: c(0xBCC0CC),
        mdHr: c(0xDF8E1D),
        mdListBullet: c(0xFE640B),
        // Diffs
        toolDiffAdded: c(0x2A9D8F),
        toolDiffRemoved: c(0xC0505A),
        toolDiffContext: c(0x8C8FA1),
        // Syntax (Latte Things inspired, with less mauve)
        syntaxComment: c(0x8C8FA1),
        syntaxKeyword: c(0x6F72B8),
        syntaxFunction: c(0x1E66F5),
        syntaxVariable: c(0x4C4F69),
        syntaxString: c(0x40A02B),
        syntaxNumber: c(0xFE640B),
        syntaxType: c(0x179299),
        syntaxOperator: c(0x04A5E5),
        syntaxPunctuation: c(0x6C6F85),
        // Thinking (keep the Latte ramp, but soften the higher mauves)
        thinkingOff: c(0xACB0BE),
        thinkingMinimal: c(0x8C8FA1),
        thinkingLow: c(0x209FB5),
        thinkingMedium: c(0x1E66F5),
        thinkingHigh: c(0x6F72B8),
        thinkingXhigh: c(0xC779B8)
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
