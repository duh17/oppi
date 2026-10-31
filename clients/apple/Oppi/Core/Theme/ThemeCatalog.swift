import Foundation
import SwiftUI
import os
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Identifies one palette build, so a value derived from a palette can be
/// cached by identity rather than by comparing all 51 colors.
///
/// Every palette built gets its own, and a palette's colors never change after it
/// is built (`ThemePalette`'s tokens are `let`), so nothing keyed on a palette's
/// identity can go stale. A copy of a palette is the same build and shares its
/// identity, which is what lets `palette.ui` cache one set of colours per build.
struct PaletteIdentity: Hashable, Sendable {
    private let value: UInt64

    init() {
        value = PaletteIdentity.next()
    }

    private static func next() -> UInt64 {
        counter.withLock { value in
            defer { value += 1 }
            return value
        }
    }

    private static let counter = OSAllocatedUnfairLock(initialState: UInt64(1))
}

/// Color palette for the entire app — 51 tokens (49 required, 2 optional on import).
///
/// 13 base colors (used by `Color.theme*` static accessors) plus 38 semantic
/// tokens for UI surfaces, syntax highlighting, markdown, diffs, and thinking.
///
/// A palette does not change after it is built: `ThemeContrast` reads a seed and
/// builds the adjusted palette.
struct ThemePalette: Sendable, ProviderIconTintPalette {
    /// Which palette build this value is: one per construction, never written
    /// again, so nothing derived from a palette can go stale. See
    /// `PaletteIdentity`.
    let identity = PaletteIdentity()

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

    // ── User / assistant message (4) ──
    let userMessageBg: Color
    let userMessageText: Color
    /// Assistant row fill. Built-ins use `Color.clear` (no wash).
    let assistantMessageBg: Color
    /// Optional leading strip on the user card. Built-ins use `nil` (no
    /// strip); a custom theme opts in with `userMessageAccent`.
    let userMessageAccent: Color?

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

// MARK: - Theme IDs

enum ThemeID: Hashable, Codable, Sendable {
    case dark
    case oled
    case light
    case night
    case custom(String)

    /// Built-in themes (shipped in the app). Custom/imported themes added separately.
    static let builtins: [Self] = [.dark, .oled, .light, .night]

    /// Themes shown in a Settings picker.
    ///
    /// Pass `.light` or `.dark` to keep day and night lists from mixing.
    /// Pass `nil` for the manual picker, which can choose any theme.
    static func pickerThemes(matching scheme: ColorScheme?) -> [Self] {
        let builtinMatches = builtins.filter { scheme == nil || $0.preferredColorScheme == scheme }
        let customMatches = CustomThemeStore.names().compactMap { name -> Self? in
            let themeID = Self.custom(name)
            guard scheme == nil || themeID.preferredColorScheme == scheme else { return nil }
            return themeID
        }
        return builtinMatches + customMatches
    }

    /// Default built-in for a system appearance slot.
    static func defaultTheme(for scheme: ColorScheme) -> Self {
        scheme == .light ? .light : .dark
    }

    /// Keep a persisted Light/Dark preset on the matching side of the picker.
    func matching(scheme: ColorScheme) -> Self {
        preferredColorScheme == scheme ? self : Self.defaultTheme(for: scheme)
    }

    var isImported: Bool {
        if case .custom = self { return true }
        return false
    }

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

    /// Contrast-solved chat surfaces. Built-ins only; custom themes keep
    /// their JSON colors as written.
    var chatSurfaces: ThemeChatSurfaces? {
        switch self {
        case .dark: ThemePalettes.darkTheme.surfaces
        case .oled: ThemePalettes.oledTheme.surfaces
        case .light: ThemePalettes.lightTheme.surfaces
        case .night: ThemePalettes.nightTheme.surfaces
        case .custom: nil
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
            return CustomThemeStore.palette(name: name) ?? ThemePalettes.dark // fallback
        }
    }
}

// MARK: - Built-in Palettes

/// Built-in palettes are seeds: `ThemeContrast.resolve` keeps each color's
/// hue and chroma and moves its lightness until every contrast rule holds,
/// and derives the chat surfaces (assistant card, user bubbles) from them.
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
    static let darkTheme = ThemeContrast.resolve(isDark: true, seed: ThemePalette(
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
        // User / assistant message
        userMessageBg: c(0x3A4568),
        userMessageText: c(0xC8D1EB),
        assistantMessageBg: .clear,
        userMessageAccent: nil,
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
    ))

    /// OLED — true black variant of Dark for dark rooms and battery maximalism.
    ///
    /// Keeps the same cool, modern family as Dark, but tightens the surfaces all
    /// the way down to black. Secondary text is intentionally brighter than the
    /// first pass so bash/tool output stays readable.
    static let oledTheme = ThemeContrast.resolve(isDark: true, seed: ThemePalette(
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
        // User / assistant message
        userMessageBg: c(0x243044),
        userMessageText: c(0xC5CEEA),
        assistantMessageBg: .clear,
        userMessageAccent: nil,
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
    ))

    /// Night — warm dark-room theme with low-saturation accents.
    ///
    /// Designed for reading in the dark. Key choices:
    /// - Near-black background (#0E0D0B) avoids OLED smearing vs pure #000000
    /// - Warm parchment text (#C8BFB0) reduces blue light and glare
    /// - ~10:1 contrast ratio (vs 21:1 max) — easier on dark-adapted eyes
    /// - All accents warm-shifted: amber hero, blues → steel, cyans → sage teal
    /// - Low saturation across the board — nothing screams at dilated pupils
    static let nightTheme = ThemeContrast.resolve(isDark: true, seed: ThemePalette(
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
        // User / assistant message
        userMessageBg: c(0x3A3226),
        userMessageText: c(0xC8BFB0),
        assistantMessageBg: .clear,
        userMessageAccent: nil,
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
    ))

    /// Light — Latte Things-inspired light theme with softer accent chroma.
    ///
    /// Uses the warm paper/granite surfaces from the bundled Latte Things theme,
    /// but tones the mauve family down so the overall UI leans more blue/teal
    /// than purple.
    static let lightTheme = ThemeContrast.resolve(isDark: false, seed: ThemePalette(
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
        // User / assistant message
        userMessageBg: c(0xD1CDC6),
        userMessageText: c(0x3A3330),
        assistantMessageBg: .clear,
        userMessageAccent: nil,
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
    ))

    static var dark: ThemePalette { darkTheme.palette }
    static var oled: ThemePalette { oledTheme.palette }
    static var night: ThemePalette { nightTheme.palette }
    static var light: ThemePalette { lightTheme.palette }
}
// swiftlint:enable function_body_length

// MARK: - UIKit Palette

#if canImport(UIKit)
/// UIKit view of the active `ThemePalette`, for view controllers.
///
/// `Color.theme*` and `UIColor.theme*` resolve from the same cached palette:
/// `ThemeRuntimeState` builds this once per theme change, so a UIKit view that
/// reads `UIColor.themeFg` in `updateProperties()` paints the token a SwiftUI
/// view reads as `.themeFg`. Palette colors are static sRGB values, so caching
/// the `UIColor` conversions cannot go stale against a trait collection.
struct ThemeUIKitPalette: @unchecked Sendable {
    let bg: UIColor
    let bgDark: UIColor
    let bgHighlight: UIColor

    let fg: UIColor
    let fgDim: UIColor
    let comment: UIColor

    let blue: UIColor
    let cyan: UIColor
    let green: UIColor
    let orange: UIColor
    let purple: UIColor
    let red: UIColor
    let yellow: UIColor

    let toolSuccessBg: UIColor
    let toolTitle: UIColor
    let toolOutput: UIColor

    let scrim: UIColor
    let dimScrim: UIColor
    let recessedInset: UIColor
    let onBlue: UIColor
    let onGreen: UIColor

    let syntaxComment: UIColor
    let syntaxKeyword: UIColor
    let syntaxFunction: UIColor
    let syntaxString: UIColor
    let syntaxNumber: UIColor
    let syntaxType: UIColor
    let syntaxPunctuation: UIColor

    let diffAdded: UIColor
    let diffRemoved: UIColor
    let diffContext: UIColor

    private let surfaces: [ThemeSurfaceRole: ThemeUIKitSurface]

    init(palette: ThemePalette) {
        bg = UIColor(palette.bg)
        bgDark = UIColor(palette.bgDark)
        bgHighlight = UIColor(palette.bgHighlight)

        fg = UIColor(palette.fg)
        fgDim = UIColor(palette.fgDim)
        comment = UIColor(palette.comment)

        blue = UIColor(palette.blue)
        cyan = UIColor(palette.cyan)
        green = UIColor(palette.green)
        orange = UIColor(palette.orange)
        purple = UIColor(palette.purple)
        red = UIColor(palette.red)
        yellow = UIColor(palette.yellow)

        toolSuccessBg = UIColor(palette.toolSuccessBg)
        toolTitle = UIColor(palette.toolTitle)
        toolOutput = UIColor(palette.toolOutput)

        scrim = UIColor(palette.bgDark.opacity(0.82))
        dimScrim = UIColor(palette.bg.opacity(0.5))
        recessedInset = UIColor(palette.bg.opacity(0.30))
        // Not `ThemeColorContrast.foreground(for:)`: its candidates are
        // `Color.themeFg`/`.themeBg`, which read the runtime palette, and this
        // init runs inside that palette's one-time initialization.
        onBlue = UIColor(ThemeColorContrast.contrastingForeground(
            on: palette.blue,
            candidates: [palette.fg, palette.bg]
        ))
        onGreen = UIColor(ThemeColorContrast.contrastingForeground(
            on: palette.green,
            candidates: [palette.fg, palette.bg]
        ))

        syntaxComment = UIColor(palette.syntaxComment)
        syntaxKeyword = UIColor(palette.syntaxKeyword)
        syntaxFunction = UIColor(palette.syntaxFunction)
        syntaxString = UIColor(palette.syntaxString)
        syntaxNumber = UIColor(palette.syntaxNumber)
        syntaxType = UIColor(palette.syntaxType)
        syntaxPunctuation = UIColor(palette.syntaxPunctuation)

        diffAdded = UIColor(palette.toolDiffAdded)
        diffRemoved = UIColor(palette.toolDiffRemoved)
        diffContext = UIColor(palette.toolDiffContext)

        surfaces = ThemeSurfaceRole.allCases.reduce(into: [:]) { surfaces, role in
            let style = ThemeSurfaceStyle.resolve(role, palette: palette)
            surfaces[role] = ThemeUIKitSurface(
                fill: UIColor(style.fill),
                stroke: style.stroke.map { UIColor($0) }
            )
        }
    }

    /// Role fill for a themed surface, with the role's opacity math already
    /// applied by `ThemeSurfaceStyle.resolve`.
    func surfaceFill(_ role: ThemeSurfaceRole) -> UIColor {
        surfaces[role]?.fill ?? bg
    }

    func surfaceStroke(_ role: ThemeSurfaceRole) -> UIColor? {
        surfaces[role]?.stroke
    }
}

/// One resolved themed surface, as UIKit colors.
struct ThemeUIKitSurface: @unchecked Sendable {
    let fill: UIColor
    let stroke: UIColor?
}

/// UIKit view of a `ThemePalette`, for view controllers.
///
/// `ThemeUIKitPalette` carries the tokens the SwiftUI surfaces share; this adds
/// the rest, so a UIKit call site reads a `UIColor` instead of bridging
/// `UIColor(Color)` (`palette.ui` in ThemePalette+UIKit.swift). Every palette
/// token has a color here: a new UIKit surface needs no bridge, and the UIKit
/// structure guard fails one.
///
/// A class, so handing it to a call site is one retain: it holds a `UIColor` per
/// token, and `palette.ui` is on cell configure and draw paths.
final class ThemeUIKitTokens: @unchecked Sendable {
    /// The tokens `ThemeUIKitPalette` already carries.
    private let shared: ThemeUIKitPalette

    // Tokens `ThemeUIKitPalette` leaves to SwiftUI. Add one here when a UIKit
    // call site needs it; `ThemeUIKitTokensTests` fails when a palette token has
    // no color here.
    let thinkingText: UIColor
    let userMessageBg: UIColor
    let userMessageText: UIColor
    let assistantMessageBg: UIColor
    let toolPendingBg: UIColor
    let toolErrorBg: UIColor
    let mdHeading: UIColor
    let mdLink: UIColor
    let mdLinkUrl: UIColor
    let mdCode: UIColor
    let mdCodeBlock: UIColor
    let mdCodeBlockBorder: UIColor
    let mdQuote: UIColor
    let mdQuoteBorder: UIColor
    let mdHr: UIColor
    let mdListBullet: UIColor
    let syntaxVariable: UIColor
    let syntaxOperator: UIColor
    let thinkingOff: UIColor
    let thinkingMinimal: UIColor
    let thinkingLow: UIColor
    let thinkingMedium: UIColor
    let thinkingHigh: UIColor
    let thinkingXhigh: UIColor
    /// Optional leading strip on the user card; built-ins have none.
    let userMessageAccent: UIColor?

    /// Converts the palette's tokens. Called with the palette a theme change
    /// built (`ThemeRuntimeState`) and for a palette no window paints (an SSH
    /// terminal's own theme, a gallery card), so it reads nothing but `palette`.
    init(shared: ThemeUIKitPalette, palette: ThemePalette) {
        self.shared = shared
        thinkingText = UIColor(palette.thinkingText)
        userMessageBg = UIColor(palette.userMessageBg)
        userMessageText = UIColor(palette.userMessageText)
        assistantMessageBg = UIColor(palette.assistantMessageBg)
        toolPendingBg = UIColor(palette.toolPendingBg)
        toolErrorBg = UIColor(palette.toolErrorBg)
        mdHeading = UIColor(palette.mdHeading)
        mdLink = UIColor(palette.mdLink)
        mdLinkUrl = UIColor(palette.mdLinkUrl)
        mdCode = UIColor(palette.mdCode)
        mdCodeBlock = UIColor(palette.mdCodeBlock)
        mdCodeBlockBorder = UIColor(palette.mdCodeBlockBorder)
        mdQuote = UIColor(palette.mdQuote)
        mdQuoteBorder = UIColor(palette.mdQuoteBorder)
        mdHr = UIColor(palette.mdHr)
        mdListBullet = UIColor(palette.mdListBullet)
        syntaxVariable = UIColor(palette.syntaxVariable)
        syntaxOperator = UIColor(palette.syntaxOperator)
        thinkingOff = UIColor(palette.thinkingOff)
        thinkingMinimal = UIColor(palette.thinkingMinimal)
        thinkingLow = UIColor(palette.thinkingLow)
        thinkingMedium = UIColor(palette.thinkingMedium)
        thinkingHigh = UIColor(palette.thinkingHigh)
        thinkingXhigh = UIColor(palette.thinkingXhigh)
        userMessageAccent = palette.userMessageAccent.map { UIColor($0) }
    }

    // MARK: - Shared tokens

    var bg: UIColor { shared.bg }
    var bgDark: UIColor { shared.bgDark }
    var bgHighlight: UIColor { shared.bgHighlight }
    var fg: UIColor { shared.fg }
    var fgDim: UIColor { shared.fgDim }
    var comment: UIColor { shared.comment }
    var blue: UIColor { shared.blue }
    var cyan: UIColor { shared.cyan }
    var green: UIColor { shared.green }
    var orange: UIColor { shared.orange }
    var purple: UIColor { shared.purple }
    var red: UIColor { shared.red }
    var yellow: UIColor { shared.yellow }
    var toolSuccessBg: UIColor { shared.toolSuccessBg }
    var toolTitle: UIColor { shared.toolTitle }
    var toolOutput: UIColor { shared.toolOutput }
    var scrim: UIColor { shared.scrim }
    var dimScrim: UIColor { shared.dimScrim }
    var recessedInset: UIColor { shared.recessedInset }
    var onBlue: UIColor { shared.onBlue }
    var onGreen: UIColor { shared.onGreen }
    var syntaxComment: UIColor { shared.syntaxComment }
    var syntaxKeyword: UIColor { shared.syntaxKeyword }
    var syntaxFunction: UIColor { shared.syntaxFunction }
    var syntaxString: UIColor { shared.syntaxString }
    var syntaxNumber: UIColor { shared.syntaxNumber }
    var syntaxType: UIColor { shared.syntaxType }
    var syntaxPunctuation: UIColor { shared.syntaxPunctuation }
    var diffAdded: UIColor { shared.diffAdded }
    var diffRemoved: UIColor { shared.diffRemoved }
    var diffContext: UIColor { shared.diffContext }

    // MARK: - Surfaces

    /// Role fill for a themed surface, with the role's opacity math already
    /// applied by `ThemeSurfaceStyle.resolve`.
    func surfaceFill(_ role: ThemeSurfaceRole) -> UIColor {
        shared.surfaceFill(role)
    }

    /// The role's hairline stroke, when it has one.
    func surfaceStroke(_ role: ThemeSurfaceRole) -> UIColor? {
        shared.surfaceStroke(role)
    }
}
#endif

// MARK: - Runtime State

enum ThemeRuntimeState {
    private struct State {
        var themeID: ThemeID
        var palette: ThemePalette
        #if canImport(UIKit)
        var uiPalette: ThemeUIKitPalette
        var uiTokens: ThemeUIKitTokens
        #endif

        init(themeID: ThemeID) {
            let palette = themeID.palette
            self.themeID = themeID
            self.palette = palette
            #if canImport(UIKit)
            // Built here, under this state's lock, so a reader always gets the
            // colors of the palette it is being handed. Neither initializer may
            // read `ThemeRuntimeState` back (see `bee815ece`).
            let uiPalette = ThemeUIKitPalette(palette: palette)
            self.uiPalette = uiPalette
            self.uiTokens = ThemeUIKitTokens(shared: uiPalette, palette: palette)
            #endif
        }
    }

    private static let state = OSAllocatedUnfairLock(
        initialState: State(themeID: ThemeID.loadPersisted())
    )

    static func currentThemeID() -> ThemeID {
        state.withLock { $0.themeID }
    }

    static func setThemeID(_ themeID: ThemeID) {
        state.withLock { $0 = State(themeID: themeID) }
    }

    /// Cached palette — resolved once on theme change, not on every access.
    static func currentPalette() -> ThemePalette {
        state.withLock { $0.palette }
    }

    #if canImport(UIKit)
    /// Cached UIKit palette — resolved with `currentPalette()`, never separately.
    static func currentUIKitPalette() -> ThemeUIKitPalette {
        state.withLock { $0.uiPalette }
    }

    /// The palette's UIKit tokens when `identity` is the palette the window
    /// paints, nil for any other palette (an SSH terminal's own theme, a theme
    /// gallery card, a preview).
    ///
    /// An identity compare, not a color compare: this is the path every UIKit
    /// call site takes through `palette.ui`, and the tokens were built with the
    /// palette on the last theme change.
    static func currentUIKitTokens(for identity: PaletteIdentity) -> ThemeUIKitTokens? {
        state.withLock { $0.palette.identity == identity ? $0.uiTokens : nil }
    }
    #endif

    static func currentRenderTheme() -> RenderTheme {
        currentPalette().renderTheme
    }
}

extension ThemePalette {
    var renderTheme: RenderTheme {
        RenderTheme(
            foreground: Self.platformCGColor(fg),
            foregroundDim: Self.platformCGColor(fgDim),
            background: Self.platformCGColor(bg),
            backgroundDark: Self.platformCGColor(bgDark),
            comment: Self.platformCGColor(comment),
            keyword: Self.platformCGColor(syntaxKeyword),
            string: Self.platformCGColor(syntaxString),
            number: Self.platformCGColor(syntaxNumber),
            function: Self.platformCGColor(syntaxFunction),
            type: Self.platformCGColor(syntaxType),
            link: Self.platformCGColor(mdLink),
            heading: Self.platformCGColor(mdHeading),
            accentBlue: Self.platformCGColor(blue),
            accentCyan: Self.platformCGColor(cyan),
            accentGreen: Self.platformCGColor(green),
            accentOrange: Self.platformCGColor(orange),
            accentPurple: Self.platformCGColor(purple),
            accentRed: Self.platformCGColor(red),
            accentYellow: Self.platformCGColor(yellow)
        )
    }

    private static func platformCGColor(_ color: Color) -> CGColor {
        #if canImport(UIKit)
        UIColor(color).cgColor
        #elseif canImport(AppKit)
        NSColor(color).usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 0.5, alpha: 1)
        #else
        CGColor(gray: 0.5, alpha: 1)
        #endif
    }
}
