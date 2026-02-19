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
    case light
    case custom(String)

    /// Built-in themes (shipped in the app). Custom/imported themes added separately.
    static let builtins: [ThemeID] = [.dark, .light]

    static let storageKey = "\(AppIdentifiers.subsystem).theme.id"

    /// Stable string ID for persistence.
    var rawValue: String {
        switch self {
        case .dark: return "dark"
        case .light: return "light"
        case .custom(let name): return "custom:\(name)"
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "dark": self = .dark
        case "light": self = .light
        // Legacy: old IDs from before rename
        case "apple-dark": self = .dark
        case "apple-light": self = .light
        case "tokyo-night": self = .custom("Tokyo Night")
        case "tokyo-night-storm": self = .custom("Tokyo Night Storm")
        case "tokyo-night-day": self = .custom("Tokyo Night Day")
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

    static func loadPersisted() -> ThemeID {
        guard let raw = UserDefaults.standard.string(forKey: storageKey)
        else { return .dark }
        return ThemeID(rawValue: raw)
    }

    var displayName: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .custom(let name): return name
        }
    }

    var detail: String {
        switch self {
        case .dark:
            return "Native dark with muted, frosted accents."
        case .light:
            return "Native light with clean, understated accents."
        case .custom:
            return "Imported theme from server."
        }
    }

    var preferredColorScheme: ColorScheme {
        switch self {
        case .dark:
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
        case .light:
            return ThemePalettes.light
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

    // Tokyo Night themes are now JSON files served by the server.
    // Import them via Settings → Import Theme.
    // See: server/themes/tokyo-night.json, tokyo-night-storm.json, tokyo-night-day.json

    /// Fallback palette used when no custom theme loads.
    /// Matches Tokyo Night (Night) so existing users get a familiar experience.
    static let fallback = ThemePalette(
        // Base 13
        bg:          c(0x1a1b26),
        bgDark:      c(0x16161e),
        bgHighlight: c(0x292e42),
        fg:          c(0xc0caf5),
        fgDim:       c(0xa9b1d6),
        comment:     c(0x565f89),
        blue:        c(0x7aa2f7),
        cyan:        c(0x7dcfff),
        green:       c(0x9ece6a),
        orange:      c(0xff9e64),
        purple:      c(0xbb9af7),
        red:         c(0xf7768e),
        yellow:      c(0xe0af68),
        thinkingText:  c(0xa9b1d6),  // fg_dark
        // User message
        userMessageBg:   c(0x292e42),  // bgHighlight
        userMessageText: c(0xc0caf5),  // fg
        // Tool state
        toolPendingBg: c(0x7aa2f7).opacity(0.12),  // blue 12%
        toolSuccessBg: c(0x9ece6a).opacity(0.08),   // green 8%
        toolErrorBg:   c(0xf7768e).opacity(0.10),   // red 10%
        toolTitle:     c(0xc0caf5),   // fg
        toolOutput:    c(0xa9b1d6),   // fgDim
        // Markdown (from folke's treesitter highlights)
        mdHeading:        c(0x7aa2f7),  // Title = blue
        mdLink:           c(0x1abc9c),  // @markup.link = teal
        mdLinkUrl:        c(0x565f89),  // comment
        mdCode:           c(0x7aa2f7),  // @markup.raw.markdown_inline fg
        mdCodeBlock:      c(0x9ece6a),  // String = green
        mdCodeBlockBorder: c(0x565f89), // comment
        mdQuote:          c(0x565f89),
        mdQuoteBorder:    c(0x565f89),
        mdHr:             c(0xe0af68),  // VimwikiHR = yellow
        mdListBullet:     c(0xff9e64),  // @markup.list.markdown = orange
        // Diffs (from DiffAdd/DiffDelete backgrounds as accent colors)
        toolDiffAdded:   c(0x449dab),  // git.add
        toolDiffRemoved: c(0x914c54),  // git.delete
        toolDiffContext:  c(0x545c7e),  // dark3
        // Syntax (from folke's treesitter highlight groups)
        syntaxComment:     c(0x565f89),  // Comment
        syntaxKeyword:     c(0x9d7cd8),  // @keyword = purple (not magenta)
        syntaxFunction:    c(0x7aa2f7),  // Function = blue
        syntaxVariable:    c(0xc0caf5),  // @variable = fg
        syntaxString:      c(0x9ece6a),  // String = green
        syntaxNumber:      c(0xff9e64),  // Number = orange
        syntaxType:        c(0x2ac3de),  // Type = blue1
        syntaxOperator:    c(0x89ddff),  // Operator = blue5
        syntaxPunctuation: c(0xa9b1d6),  // @punctuation.bracket = fg_dark
        // Thinking (pi TUI dark theme values)
        thinkingOff:     c(0x505050),
        thinkingMinimal: c(0x6e6e6e),
        thinkingLow:     c(0x5f87af),
        thinkingMedium:  c(0x81a2be),
        thinkingHigh:    c(0xb294bb),
        thinkingXhigh:   c(0xd183e8)
    )

    /// Dark — native dark with desaturated, frosted accents.
    ///
    /// Backgrounds use system semantic colors. Accent colors are intentionally
    /// muted — like system colors seen through frosted glass.
    static let dark = ThemePalette(
        // Base 13
        bg:          Color(uiColor: .systemBackground),
        bgDark:      Color(uiColor: .secondarySystemBackground),
        bgHighlight: Color(uiColor: .tertiarySystemBackground),
        fg:          Color(uiColor: .label),
        fgDim:       Color(uiColor: .secondaryLabel),
        comment:     Color(uiColor: .tertiaryLabel),
        blue:   c(0x649BE6),  // soft blue
        cyan:   c(0x78B9B2),  // muted teal
        green:  c(0x73B987),  // sage
        orange: c(0xCDA06E),  // warm amber
        purple: c(0xA091C8),  // dusty lavender
        red:    c(0xDC6E73),  // rosewood
        yellow: c(0xC8B678),  // warm khaki
        thinkingText:  Color(uiColor: .secondaryLabel),
        // User message
        userMessageBg:   Color(uiColor: .tertiarySystemBackground),
        userMessageText: Color(uiColor: .label),
        // Tool state
        toolPendingBg: c(0x649BE6).opacity(0.12),
        toolSuccessBg: c(0x73B987).opacity(0.08),
        toolErrorBg:   c(0xDC6E73).opacity(0.10),
        toolTitle:     Color(uiColor: .label),
        toolOutput:    Color(uiColor: .secondaryLabel),
        // Markdown
        mdHeading:        c(0x649BE6),  // blue
        mdLink:           c(0x78B9B2),  // teal
        mdLinkUrl:        Color(uiColor: .tertiaryLabel),
        mdCode:           c(0x78B9B2),  // teal
        mdCodeBlock:      c(0x73B987),  // green
        mdCodeBlockBorder: c(0x48484A),
        mdQuote:          Color(uiColor: .secondaryLabel),
        mdQuoteBorder:    c(0x48484A),
        mdHr:             c(0x48484A),
        mdListBullet:     c(0xCDA06E),  // orange
        // Diffs
        toolDiffAdded:   c(0x5AAA75),  // lighter sage for readability
        toolDiffRemoved: c(0xC45A60),  // warmer red
        toolDiffContext:  Color(uiColor: .tertiaryLabel),
        // Syntax (Xcode dark inspired, slightly muted)
        syntaxComment:     Color(uiColor: .tertiaryLabel),
        syntaxKeyword:     c(0xA091C8),  // purple
        syntaxFunction:    c(0x649BE6),  // blue
        syntaxVariable:    Color(uiColor: .label),
        syntaxString:      c(0xDC6E73),  // red/rose (Xcode dark uses red for strings)
        syntaxNumber:      c(0xCDA06E),  // orange
        syntaxType:        c(0x78B9B2),  // teal
        syntaxOperator:    Color(uiColor: .label),
        syntaxPunctuation: Color(uiColor: .secondaryLabel),
        // Thinking (monochromatic gray → subtle tint)
        thinkingOff:     c(0x48484A),
        thinkingMinimal: c(0x636366),
        thinkingLow:     c(0x6E87A0),
        thinkingMedium:  c(0x8296B4),
        thinkingHigh:    c(0x9B91B9),
        thinkingXhigh:   c(0xAF96CD)
    )

    /// Light — native light with clean, understated accents.
    ///
    /// Same frosted-glass philosophy as Dark but for light backgrounds.
    /// Accents are deeper/more saturated to maintain contrast on white.
    static let light = ThemePalette(
        // Base 13
        bg:          Color(uiColor: .systemBackground),
        bgDark:      Color(uiColor: .secondarySystemBackground),
        bgHighlight: Color(uiColor: .tertiarySystemBackground),
        fg:          Color(uiColor: .label),
        fgDim:       Color(uiColor: .secondaryLabel),
        comment:     Color(uiColor: .tertiaryLabel),
        blue:   c(0x3478C6),  // deeper blue
        cyan:   c(0x2E8A82),  // deeper teal
        green:  c(0x3A8550),  // deeper sage
        orange: c(0xA87530),  // deeper amber
        purple: c(0x7662A8),  // deeper lavender
        red:    c(0xC44E54),  // deeper rosewood
        yellow: c(0x9A8540),  // deeper khaki
        thinkingText:  Color(uiColor: .secondaryLabel),
        // User message
        userMessageBg:   Color(uiColor: .tertiarySystemBackground),
        userMessageText: Color(uiColor: .label),
        // Tool state
        toolPendingBg: c(0x3478C6).opacity(0.10),
        toolSuccessBg: c(0x3A8550).opacity(0.08),
        toolErrorBg:   c(0xC44E54).opacity(0.10),
        toolTitle:     Color(uiColor: .label),
        toolOutput:    Color(uiColor: .secondaryLabel),
        // Markdown
        mdHeading:        c(0x3478C6),  // blue
        mdLink:           c(0x2E8A82),  // teal
        mdLinkUrl:        Color(uiColor: .tertiaryLabel),
        mdCode:           c(0x2E8A82),  // teal
        mdCodeBlock:      c(0x3A8550),  // green
        mdCodeBlockBorder: c(0xC7C7CC),
        mdQuote:          Color(uiColor: .secondaryLabel),
        mdQuoteBorder:    c(0xC7C7CC),
        mdHr:             c(0xC7C7CC),
        mdListBullet:     c(0xA87530),  // orange
        // Diffs
        toolDiffAdded:   c(0x2D7A42),  // deep green
        toolDiffRemoved: c(0xB03A40),  // deep red
        toolDiffContext:  Color(uiColor: .tertiaryLabel),
        // Syntax (Xcode light inspired, clean)
        syntaxComment:     Color(uiColor: .tertiaryLabel),
        syntaxKeyword:     c(0x7662A8),  // purple
        syntaxFunction:    c(0x3478C6),  // blue
        syntaxVariable:    Color(uiColor: .label),
        syntaxString:      c(0xC44E54),  // red/rose
        syntaxNumber:      c(0xA87530),  // orange
        syntaxType:        c(0x2E8A82),  // teal
        syntaxOperator:    Color(uiColor: .label),
        syntaxPunctuation: Color(uiColor: .secondaryLabel),
        // Thinking (light grays → subtle color tint)
        thinkingOff:     c(0xAEAEB2),
        thinkingMinimal: c(0x8E8E93),
        thinkingLow:     c(0x5A7A90),
        thinkingMedium:  c(0x4A6D85),
        thinkingHigh:    c(0x6E5A8A),
        thinkingXhigh:   c(0x8A4EB0)
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

    /// Force palette recomputation (e.g. after editing a custom theme's colors).
    static func invalidateCache() {
        state.withLock { $0.palette = $0.themeID.palette }
    }
}
