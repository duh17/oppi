import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Chat surfaces solved for a built-in theme (`ThemeID.chatSurfaces`).
struct ThemeChatSurfaces: Sendable {
    /// Conversation-layout assistant card.
    let assistantCard: Color
    /// User bubble when Increase Contrast is on.
    let strongUserBubble: Color
}

/// Auto contrast for the built-in themes, after Pi's system theme (Earendil,
/// "There are many themes, but this one is yours", 2026-10-09,
/// https://earendil.com/posts/system-theme/).
///
/// Contrast is mostly lightness, so every color keeps its OKLCH hue and
/// chroma from the seed palette (chroma only shrinks to stay inside sRGB) and
/// the solver picks its lightness from WCAG 2 contrast rules:
/// 1. Surfaces first, landing exactly on their level. The assistant card
///    lifts one small step off `bg`; the user bubble sits a bigger step toward
///    the ink from both `bg` and the card, so the two speakers always read
///    apart; `bgHighlight` (inline code, table headers, the work pill) keeps
///    showing on the card.
/// 2. Text and accents then move only as far as their rule needs on every
///    surface they are drawn on, so hand-tuned colors that already pass keep
///    their exact value.
///
/// Custom JSON themes are not solved; they keep the colors as written.
enum ThemeContrast {
    /// Minimum WCAG 2 contrast ratios.
    enum Level {
        /// Assistant card against `bg`: reads as a sheet, not a box.
        static let cardLift: Double = 1.07
        /// `bgHighlight` against the card and `bg`.
        static let embedded: Double = 1.12
        /// User bubble against `bg` and the assistant card.
        static let bubble: Double = 1.6
        /// Increase Contrast user bubble against `bg` and the card.
        static let strongBubble: Double = 2.2
        /// Body text and accents used as text (WCAG AA).
        static let text: Double = 4.5
        /// Glyphs and indicators (WCAG non-text).
        static let glyph: Double = 3.0
    }

    struct Resolved: Sendable {
        let palette: ThemePalette
        let surfaces: ThemeChatSurfaces
    }

    /// `isDark` sets which way ink goes: lighter than its surface in dark
    /// themes, darker in light ones. Elevated surfaces go lighter in both.
    static func resolve(isDark: Bool, seed: ThemePalette) -> Resolved {
        var palette = seed
        let ink: Direction = isDark ? .lighter : .darker
        let bg = SRGB(seed.bg)

        let card = solve(SRGB(seed.bgHighlight), on: [bg], level: Level.cardLift, toward: .lighter)
        palette.bgHighlight = adjust(seed.bgHighlight, on: [bg, card], level: Level.embedded, toward: ink)
        let userBubble = solve(SRGB(seed.userMessageBg), on: [bg, card], level: Level.bubble, toward: ink)
        let strongBubble = solve(SRGB(seed.userMessageBg), on: [bg, card], level: Level.strongBubble, toward: ink)
        palette.userMessageBg = userBubble.color

        let highlight = SRGB(palette.bgHighlight)
        let codeBlock = SRGB(palette.bgDark)
        let toolPanels = [palette.toolPendingBg, palette.toolSuccessBg, palette.toolErrorBg].map {
            SRGB($0).composited(over: bg)
        }
        let prose = [bg, card, highlight] + toolPanels

        func enforce(_ tokens: [WritableKeyPath<ThemePalette, Color>], on surfaces: [SRGB], level: Double) {
            for token in tokens {
                palette[keyPath: token] = adjust(palette[keyPath: token], on: surfaces, level: level, toward: ink)
            }
        }
        enforce([\.fg], on: prose + [codeBlock], level: Level.text)
        enforce([\.fgDim, \.comment, \.thinkingText, \.toolTitle, \.toolOutput], on: prose, level: Level.text)
        enforce(
            [
                \.blue, \.cyan, \.green, \.orange, \.purple, \.red, \.yellow,
                \.mdHeading, \.mdLink, \.mdLinkUrl, \.mdCodeBlock, \.mdQuote, \.mdListBullet,
            ],
            on: [bg, card],
            level: Level.text
        )
        enforce([\.mdCode], on: [bg, card, highlight], level: Level.text)
        enforce(
            [
                \.syntaxComment, \.syntaxKeyword, \.syntaxFunction, \.syntaxVariable, \.syntaxString,
                \.syntaxNumber, \.syntaxType, \.syntaxOperator, \.syntaxPunctuation,
            ],
            on: [codeBlock],
            level: Level.text
        )
        enforce([\.toolDiffAdded, \.toolDiffRemoved, \.toolDiffContext], on: [codeBlock], level: Level.glyph)
        enforce([\.userMessageText], on: [userBubble, strongBubble], level: Level.text)

        return Resolved(
            palette: palette,
            surfaces: ThemeChatSurfaces(assistantCard: card.color, strongUserBubble: strongBubble.color)
        )
    }

    // MARK: - Solver

    enum Direction {
        case lighter
        case darker
    }

    /// Surface rule: start level with the nearest surface and move in
    /// `direction` until the contrast against every surface reaches `level`.
    private static func solve(
        _ seed: SRGB,
        on surfaces: [SRGB],
        level: Double,
        toward direction: Direction
    ) -> SRGB {
        let lightnesses = surfaces.map(\.oklch.l)
        let start = direction == .lighter ? lightnesses.max() ?? 0 : lightnesses.min() ?? 1
        return search(seed, from: start, on: surfaces, level: level, toward: direction)
    }

    /// Text rule: a seed that already passes keeps its exact value; otherwise
    /// only its lightness moves, as little as the rule needs.
    private static func adjust(
        _ color: Color,
        on surfaces: [SRGB],
        level: Double,
        toward direction: Direction
    ) -> Color {
        let seed = SRGB(color)
        guard !seed.passes(on: surfaces, level: level) else { return color }
        return search(seed, from: seed.oklch.l, on: surfaces, level: level, toward: direction).color
    }

    /// Smallest lightness step from `start` toward `direction` that passes,
    /// at the seed's hue and chroma. Returns the extreme when nothing passes.
    private static func search(
        _ seed: SRGB,
        from start: Double,
        on surfaces: [SRGB],
        level: Double,
        toward direction: Direction
    ) -> SRGB {
        let lch = seed.oklch
        func candidate(_ lightness: Double) -> SRGB {
            SRGB(oklchLightness: lightness, chroma: lch.c, hue: lch.h)
        }
        let end: Double = direction == .lighter ? 1 : 0
        if candidate(start).passes(on: surfaces, level: level) { return candidate(start) }
        guard candidate(end).passes(on: surfaces, level: level) else { return candidate(end) }
        var failing = start
        var passing = end
        for _ in 0..<32 {
            let mid = (failing + passing) / 2
            if candidate(mid).passes(on: surfaces, level: level) {
                passing = mid
            } else {
                failing = mid
            }
        }
        return candidate(passing)
    }
}

// MARK: - Color math

/// Gamma-encoded sRGB with conversions to WCAG luminance and OKLCH
/// (Björn Ottosson, https://bottosson.github.io/posts/oklab/).
private struct SRGB {
    var r: Double
    var g: Double
    var b: Double
    var alpha: Double = 1

    init(r: Double, g: Double, b: Double, alpha: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.alpha = alpha
    }

    init(_ color: Color) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, opacity: CGFloat = 1
        #if canImport(UIKit)
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &opacity)
        #elseif canImport(AppKit)
        if let srgb = NSColor(color).usingColorSpace(.sRGB) {
            srgb.getRed(&red, green: &green, blue: &blue, alpha: &opacity)
        }
        #endif
        self.init(r: Double(red), g: Double(green), b: Double(blue), alpha: Double(opacity))
    }

    /// Closest in-gamut color at this OKLCH lightness and hue; chroma shrinks
    /// until the color fits in sRGB, so lightness stays where it was solved.
    init(oklchLightness l: Double, chroma: Double, hue: Double) {
        func linear(_ c: Double) -> (Double, Double, Double) {
            Self.oklabToLinear(l, c * cos(hue), c * sin(hue))
        }
        func inGamut(_ v: (Double, Double, Double)) -> Bool {
            [v.0, v.1, v.2].allSatisfy { $0 >= -1e-7 && $0 <= 1 + 1e-7 }
        }
        var rgb = linear(chroma)
        if !inGamut(rgb) {
            var low = 0.0
            var high = chroma
            for _ in 0..<24 {
                let mid = (low + high) / 2
                if inGamut(linear(mid)) { low = mid } else { high = mid }
            }
            rgb = linear(low)
        }
        self.init(r: Self.encode(rgb.0), g: Self.encode(rgb.1), b: Self.encode(rgb.2))
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: alpha) }

    func composited(over base: SRGB) -> SRGB {
        SRGB(
            r: r * alpha + base.r * (1 - alpha),
            g: g * alpha + base.g * (1 - alpha),
            b: b * alpha + base.b * (1 - alpha)
        )
    }

    var luminance: Double {
        0.2126 * Self.decode(r) + 0.7152 * Self.decode(g) + 0.0722 * Self.decode(b)
    }

    func contrast(with other: SRGB) -> Double {
        let a = luminance
        let b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    func passes(on surfaces: [SRGB], level: Double) -> Bool {
        surfaces.allSatisfy { contrast(with: $0) >= level }
    }

    var oklch: (l: Double, c: Double, h: Double) {
        let lr = Self.decode(r), lg = Self.decode(g), lb = Self.decode(b)
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        let okL = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let okA = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let okB = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return (okL, hypot(okA, okB), atan2(okB, okA))
    }

    private static func oklabToLinear(_ okL: Double, _ okA: Double, _ okB: Double) -> (Double, Double, Double) {
        let l = pow(okL + 0.3963377774 * okA + 0.2158037573 * okB, 3)
        let m = pow(okL - 0.1055613458 * okA - 0.0638541728 * okB, 3)
        let s = pow(okL - 0.0894841775 * okA - 1.2914855480 * okB, 3)
        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    private static func decode(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func encode(_ v: Double) -> Double {
        let clamped = min(1, max(0, v))
        return clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }
}
