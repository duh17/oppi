import SwiftUI // Theme color resolution (Color.theme* → UIColor)
import UIKit

// MARK: - ANSIParser

/// Parses ANSI escape sequences into `NSAttributedString` with Tokyo Night colors.
///
/// Handles SGR (Select Graphic Rendition) codes:
/// - Reset (0), Bold (1), Dim (2), Italic (3), Underline (4)
/// - Standard colors 30-37, bright colors 90-97
/// - 256-color (38;5;n) and RGB (38;2;r;g;b) foreground
///
/// Unknown sequences are silently stripped.
///
/// Builds `NSMutableAttributedString` directly for O(n) construction,
/// consistent with `SyntaxHighlighter`.
enum ANSIParser {

    /// Strip all ANSI escape sequences, returning plain text.
    static func strip(_ input: String) -> String {
        input.replacing(Self.escapePattern, with: "")
    }

    /// Parse ANSI escape sequences into an `NSAttributedString`.
    ///
    /// Maps ANSI colors to the Tokyo Night palette for visual consistency.
    static func attributedString(
        from input: String,
        baseForeground: Color = .themeFg
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var state = SGRState()
        let baseFg = UIColor(baseForeground)
        let baseFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        let scanner = Scanner(input)
        for segment in scanner {
            switch segment {
            case .text(let str):
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: state.uiFont(base: baseFont),
                    .foregroundColor: state.foregroundUIColor ?? baseFg,
                ]
                if state.underline {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                if let bgColor = state.backgroundUIColor {
                    attrs[.backgroundColor] = bgColor
                }
                result.append(NSAttributedString(string: str, attributes: attrs))

            case .sgr(let codes):
                state.apply(codes)
            }
        }

        return result
    }

    // MARK: - Regex

    /// Matches any ANSI escape sequence: ESC [ ... final-byte
    ///
    /// Computed to avoid a global mutable-concurrency escape hatch.
    fileprivate static var escapePattern: Regex<Substring> {
        /\x1B\[[0-9;]*[A-Za-z]/
    }
}

// MARK: - Scanner

/// Splits input into alternating text and SGR segments.
private struct Scanner: Sequence, IteratorProtocol {
    private let input: String
    private var index: String.Index

    init(_ input: String) {
        self.input = input
        self.index = input.startIndex
    }

    enum Segment {
        case text(String)
        case sgr([Int])
    }

    mutating func next() -> Segment? {
        guard index < input.endIndex else { return nil }

        // Find next ESC
        if let match = input[index...].firstMatch(of: ANSIParser.escapePattern) {
            let matchStart = match.range.lowerBound
            let matchEnd = match.range.upperBound

            // Emit text before the escape
            if matchStart > index {
                let text = String(input[index..<matchStart])
                index = matchStart
                return .text(text)
            }

            // Parse the SGR sequence
            index = matchEnd
            let raw = String(match.output)

            // Only handle SGR (ends with 'm')
            guard raw.hasSuffix("m") else {
                return next() // skip non-SGR sequences
            }

            // Extract numbers between ESC[ and m
            let numbersStr = raw.dropFirst(2).dropLast() // drop \e[ and m
            let codes = numbersStr.split(separator: ";").compactMap { Int($0) }
            return .sgr(codes.isEmpty ? [0] : codes)
        }

        // No more escapes — emit remaining text
        let text = String(input[index...])
        index = input.endIndex
        return .text(text)
    }
}

// MARK: - SGR State

/// Tracks cumulative SGR state across escape sequences.
private struct SGRState {
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var foregroundUIColor: UIColor?
    var backgroundUIColor: UIColor?

    func uiFont(base: UIFont) -> UIFont {
        if !bold && !italic { return base }

        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }

        // Preserve monospaced trait from base font.
        let baseTraits = base.fontDescriptor.symbolicTraits
        if baseTraits.contains(.traitMonoSpace) {
            traits.insert(.traitMonoSpace)
        }

        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    mutating func apply(_ codes: [Int]) {
        var i = 0
        while i < codes.count {
            let code = codes[i]
            switch code {
            case 0: // Reset
                bold = false; dim = false; italic = false
                underline = false; foregroundUIColor = nil; backgroundUIColor = nil

            case 1: bold = true
            case 2: dim = true
            case 3: italic = true
            case 4: underline = true
            case 22: bold = false; dim = false
            case 23: italic = false
            case 24: underline = false
            case 39: foregroundUIColor = nil // default fg
            case 49: backgroundUIColor = nil // default bg

            // Standard fg colors (30-37)
            case 30: foregroundUIColor = UIColor(Color.themeFgDim)       // black → dim
            case 31: foregroundUIColor = UIColor(Color.themeRed)
            case 32: foregroundUIColor = UIColor(Color.themeGreen)
            case 33: foregroundUIColor = UIColor(Color.themeYellow)
            case 34: foregroundUIColor = UIColor(Color.themeBlue)
            case 35: foregroundUIColor = UIColor(Color.themePurple)
            case 36: foregroundUIColor = UIColor(Color.themeCyan)
            case 37: foregroundUIColor = UIColor(Color.themeFg)           // white → fg

            // Bright fg colors (90-97)
            case 90: foregroundUIColor = UIColor(Color.themeComment)      // bright black → comment
            case 91: foregroundUIColor = UIColor(Color.themeRed)
            case 92: foregroundUIColor = UIColor(Color.themeGreen)
            case 93: foregroundUIColor = UIColor(Color.themeYellow)
            case 94: foregroundUIColor = UIColor(Color.themeBlue)
            case 95: foregroundUIColor = UIColor(Color.themePurple)
            case 96: foregroundUIColor = UIColor(Color.themeCyan)
            case 97: foregroundUIColor = UIColor(Color.themeFg)

            // Standard bg colors (40-47)
            case 40: backgroundUIColor = UIColor(Color.themeFgDim.opacity(0.35))  // black bg
            case 41: backgroundUIColor = UIColor(Color.themeRed.opacity(0.55))
            case 42: backgroundUIColor = UIColor(Color.themeGreen.opacity(0.45))
            case 43: backgroundUIColor = UIColor(Color.themeYellow.opacity(0.45))
            case 44: backgroundUIColor = UIColor(Color.themeBlue.opacity(0.45))
            case 45: backgroundUIColor = UIColor(Color.themePurple.opacity(0.45))
            case 46: backgroundUIColor = UIColor(Color.themeCyan.opacity(0.40))
            case 47: backgroundUIColor = UIColor(Color.themeFg.opacity(0.20))    // white bg

            // Bright bg colors (100-107)
            case 100: backgroundUIColor = UIColor(Color.themeComment.opacity(0.30))
            case 101: backgroundUIColor = UIColor(Color.themeRed.opacity(0.65))
            case 102: backgroundUIColor = UIColor(Color.themeGreen.opacity(0.55))
            case 103: backgroundUIColor = UIColor(Color.themeYellow.opacity(0.55))
            case 104: backgroundUIColor = UIColor(Color.themeBlue.opacity(0.55))
            case 105: backgroundUIColor = UIColor(Color.themePurple.opacity(0.55))
            case 106: backgroundUIColor = UIColor(Color.themeCyan.opacity(0.50))
            case 107: backgroundUIColor = UIColor(Color.themeFg.opacity(0.30))

            // 256-color fg: 38;5;n  /  rgb fg: 38;2;r;g;b
            case 38:
                if i + 1 < codes.count, codes[i + 1] == 5, i + 2 < codes.count {
                    foregroundUIColor = color256(codes[i + 2])
                    i += 2
                } else if i + 1 < codes.count, codes[i + 1] == 2, i + 4 < codes.count {
                    // RGB: 38;2;r;g;b
                    foregroundUIColor = UIColor(
                        red: CGFloat(codes[i + 2]) / 255,
                        green: CGFloat(codes[i + 3]) / 255,
                        blue: CGFloat(codes[i + 4]) / 255,
                        alpha: 1
                    )
                    i += 4
                }

            // 256-color bg: 48;5;n  /  rgb bg: 48;2;r;g;b
            case 48:
                if i + 1 < codes.count, codes[i + 1] == 5, i + 2 < codes.count {
                    backgroundUIColor = color256(codes[i + 2])
                    i += 2
                } else if i + 1 < codes.count, codes[i + 1] == 2, i + 4 < codes.count {
                    backgroundUIColor = UIColor(
                        red: CGFloat(codes[i + 2]) / 255,
                        green: CGFloat(codes[i + 3]) / 255,
                        blue: CGFloat(codes[i + 4]) / 255,
                        alpha: 1
                    )
                    i += 4
                }

            default: break // ignore blink, reverse, etc.
            }
            i += 1
        }
    }

    /// Map 256-color palette to Tokyo Night approximations.
    private func color256(_ n: Int) -> UIColor {
        switch n {
        case 0: return UIColor(Color.themeFgDim)
        case 1: return UIColor(Color.themeRed)
        case 2: return UIColor(Color.themeGreen)
        case 3: return UIColor(Color.themeYellow)
        case 4: return UIColor(Color.themeBlue)
        case 5: return UIColor(Color.themePurple)
        case 6: return UIColor(Color.themeCyan)
        case 7: return UIColor(Color.themeFg)
        case 8...15: return color256(n - 8) // bright = same mapping
        case 232...255: // grayscale ramp
            let gray = CGFloat(n - 232) / 23.0
            return UIColor(white: gray, alpha: 1)
        default:
            // 216-color cube (16-231): approximate with hue
            let idx = n - 16
            let r = CGFloat((idx / 36) % 6) / 5.0
            let g = CGFloat((idx / 6) % 6) / 5.0
            let b = CGFloat(idx % 6) / 5.0
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        }
    }
}
