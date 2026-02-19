import SwiftUI
import UIKit

// MARK: - ANSIParser

/// Parses ANSI escape sequences into `AttributedString` with Tokyo Night colors.
///
/// Handles SGR (Select Graphic Rendition) codes:
/// - Reset (0), Bold (1), Dim (2), Italic (3), Underline (4)
/// - Standard colors 30-37, bright colors 90-97
/// - 256-color (38;5;n) and RGB (38;2;r;g;b) foreground
///
/// Unknown sequences are silently stripped.
enum ANSIParser {

    /// Strip all ANSI escape sequences, returning plain text.
    static func strip(_ input: String) -> String {
        input.replacing(Self.escapePattern, with: "")
    }

    /// Parse ANSI escape sequences into an `AttributedString`.
    ///
    /// Maps ANSI colors to the Tokyo Night palette for visual consistency.
    static func attributedString(
        from input: String,
        baseFont: Font = .caption.monospaced(),
        baseForeground: Color = .themeFg
    ) -> AttributedString {
        var result = AttributedString()
        var state = SGRState()

        let scanner = Scanner(input)
        for segment in scanner {
            switch segment {
            case .text(let str):
                var attrs = AttributedString(str)
                attrs.font = state.font(base: baseFont)
                let foreground = state.foreground ?? baseForeground
                attrs.foregroundColor = foreground
                attrs[AttributeScopes.UIKitAttributes.ForegroundColorAttribute.self] = UIColor(foreground)
                if state.underline {
                    attrs.underlineStyle = .single
                }
                result.append(attrs)

            case .sgr(let codes):
                state.apply(codes)
            }
        }

        return result
    }

    // MARK: - Regex

    /// Matches any ANSI escape sequence: ESC [ ... final-byte
    nonisolated(unsafe) fileprivate static let escapePattern: Regex<Substring> = /\x1B\[[0-9;]*[A-Za-z]/
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
    var foreground: Color?

    func font(base: Font) -> Font {
        var f = base
        if bold { f = f.bold() }
        if italic { f = f.italic() }
        return f
    }

    mutating func apply(_ codes: [Int]) {
        var i = 0
        while i < codes.count {
            let code = codes[i]
            switch code {
            case 0: // Reset
                bold = false; dim = false; italic = false
                underline = false; foreground = nil

            case 1: bold = true
            case 2: dim = true
            case 3: italic = true
            case 4: underline = true
            case 22: bold = false; dim = false
            case 23: italic = false
            case 24: underline = false
            case 39: foreground = nil // default fg

            // Standard colors (30-37)
            case 30: foreground = .themeFgDim       // black → dim
            case 31: foreground = .themeRed
            case 32: foreground = .themeGreen
            case 33: foreground = .themeYellow
            case 34: foreground = .themeBlue
            case 35: foreground = .themePurple
            case 36: foreground = .themeCyan
            case 37: foreground = .themeFg           // white → fg

            // Bright colors (90-97)
            case 90: foreground = .themeComment      // bright black → comment
            case 91: foreground = .themeRed
            case 92: foreground = .themeGreen
            case 93: foreground = .themeYellow
            case 94: foreground = .themeBlue
            case 95: foreground = .themePurple
            case 96: foreground = .themeCyan
            case 97: foreground = .themeFg

            // 256-color: 38;5;n
            case 38:
                if i + 1 < codes.count, codes[i + 1] == 5, i + 2 < codes.count {
                    foreground = color256(codes[i + 2])
                    i += 2
                } else if i + 1 < codes.count, codes[i + 1] == 2, i + 4 < codes.count {
                    // RGB: 38;2;r;g;b
                    foreground = Color(
                        red: Double(codes[i + 2]) / 255,
                        green: Double(codes[i + 3]) / 255,
                        blue: Double(codes[i + 4]) / 255
                    )
                    i += 4
                }

            default: break // ignore background, blink, etc.
            }
            i += 1
        }
    }

    /// Map 256-color palette to Tokyo Night approximations.
    private func color256(_ n: Int) -> Color {
        switch n {
        case 0: return .themeFgDim
        case 1: return .themeRed
        case 2: return .themeGreen
        case 3: return .themeYellow
        case 4: return .themeBlue
        case 5: return .themePurple
        case 6: return .themeCyan
        case 7: return .themeFg
        case 8...15: return color256(n - 8) // bright = same mapping
        case 232...255: // grayscale ramp
            let gray = Double(n - 232) / 23.0
            return Color(white: gray)
        default:
            // 216-color cube (16-231): approximate with hue
            let idx = n - 16
            let r = Double((idx / 36) % 6) / 5.0
            let g = Double((idx / 6) % 6) / 5.0
            let b = Double(idx % 6) / 5.0
            return Color(red: r, green: g, blue: b)
        }
    }
}
