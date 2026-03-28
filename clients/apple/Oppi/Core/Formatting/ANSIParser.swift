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
/// Uses direct UTF-8 byte scanning (no regex) for O(n) performance.
/// Builds `NSMutableAttributedString` directly, consistent with `SyntaxHighlighter`.
enum ANSIParser {

    /// Strip all ANSI escape sequences, returning plain text.
    static func strip(_ input: String) -> String {
        // Fast path: no ESC byte means no ANSI codes.
        guard input.utf8.contains(0x1B) else { return input }

        let utf8 = Array(input.utf8)
        var result = [UInt8]()
        result.reserveCapacity(utf8.count)
        var i = 0
        let count = utf8.count

        while i < count {
            if utf8[i] == 0x1B, i + 1 < count, utf8[i + 1] == 0x5B /* [ */ {
                // Skip ESC [ ... final-byte
                var j = i + 2
                while j < count {
                    let b = utf8[j]
                    if b >= 0x40 && b <= 0x7E { // final byte A-Z a-z @-~
                        j += 1
                        break
                    }
                    j += 1
                }
                i = j
            } else {
                result.append(utf8[i])
                i += 1
            }
        }

        return String(bytes: result, encoding: .utf8) ?? input
    }

    /// Parse ANSI escape sequences into an `NSAttributedString`.
    ///
    /// Maps ANSI colors to the Tokyo Night palette for visual consistency.
    /// Uses direct UTF-8 byte scanning (no regex) for O(n) performance.
    static func attributedString(
        from input: String,
        baseForeground: Color = .themeFg
    ) -> NSAttributedString {
        let baseFg = UIColor(baseForeground)
        let baseFont = AppFont.mono

        // Fast path: no ESC byte means no ANSI codes — return plain text directly.
        guard input.utf8.contains(0x1B) else {
            return NSAttributedString(
                string: input,
                attributes: [.font: baseFont, .foregroundColor: baseFg]
            )
        }

        var fontCache = FontCache(base: baseFont)
        var state = SGRState()

        // Work with UTF-8 bytes for fast scanning.
        let utf8 = Array(input.utf8)
        let count = utf8.count

        // Phase 1: Scan UTF-8 bytes. Build plain text (escapes removed) and
        // record SGR events with their positions in the plain-text output.
        var plainBytes = [UInt8]()
        plainBytes.reserveCapacity(count)

        // SGR event: (byte offset in plainBytes where this SGR takes effect, parsed codes)
        var sgrEvents: [(offset: Int, codes: [Int])] = []

        var i = 0
        while i < count {
            if utf8[i] == 0x1B, i + 1 < count, utf8[i + 1] == 0x5B /* [ */ {
                // Found ESC [  — parse parameter bytes and find final byte
                var j = i + 2
                while j < count {
                    let b = utf8[j]
                    if b >= 0x40 && b <= 0x7E { // final byte
                        break
                    }
                    j += 1
                }

                if j < count && utf8[j] == 0x6D /* 'm' */ {
                    // SGR sequence — parse the parameters
                    let codes = parseCSIParams(utf8, from: i + 2, to: j)
                    sgrEvents.append((offset: plainBytes.count, codes: codes))
                }
                // else: non-SGR sequence — silently stripped

                i = j + 1
            } else {
                plainBytes.append(utf8[i])
                i += 1
            }
        }

        // Phase 2: Build a byte→UTF-16 offset map for the plain text.
        let plainString = String(bytes: plainBytes, encoding: .utf8) ?? ""
        let plainCount = plainBytes.count

        var byteToUTF16 = [Int](repeating: 0, count: plainCount + 1)
        do {
            var bIdx = 0
            var u16Idx = 0
            while bIdx < plainCount {
                byteToUTF16[bIdx] = u16Idx
                let b = plainBytes[bIdx]
                let seqLen: Int
                if b < 0x80 { seqLen = 1 }
                else if b < 0xE0 { seqLen = 2 }
                else if b < 0xF0 { seqLen = 3 }
                else { seqLen = 4 }
                let utf16Units = seqLen == 4 ? 2 : 1
                bIdx += seqLen
                u16Idx += utf16Units
            }
            byteToUTF16[plainCount] = u16Idx
        }

        // Phase 3: Create attributed string with base attributes, then apply
        // SGR overrides in a single beginEditing/endEditing batch.
        let result = NSMutableAttributedString(
            string: plainString,
            attributes: [.font: baseFont, .foregroundColor: baseFg]
        )

        guard !sgrEvents.isEmpty else { return result }

        result.beginEditing()

        // Walk SGR events. Each event changes state; apply that state to the
        // text range from this event's offset to the next event's offset (or end).
        for eventIdx in 0..<sgrEvents.count {
            state.apply(sgrEvents[eventIdx].codes)

            let rangeStartByte = sgrEvents[eventIdx].offset
            let rangeEndByte = eventIdx + 1 < sgrEvents.count
                ? sgrEvents[eventIdx + 1].offset
                : plainCount

            guard rangeEndByte > rangeStartByte else { continue }

            let utf16Start = byteToUTF16[rangeStartByte]
            let utf16End = byteToUTF16[rangeEndByte]
            let rangeLen = utf16End - utf16Start
            guard rangeLen > 0 else { continue }

            let nsRange = NSRange(location: utf16Start, length: rangeLen)

            // Apply font only when not the default
            let font = fontCache.font(bold: state.bold, italic: state.italic)
            if font !== baseFont {
                result.addAttribute(.font, value: font, range: nsRange)
            }

            // Apply foreground color only when changed from base
            if let fg = state.foregroundUIColor {
                result.addAttribute(.foregroundColor, value: fg, range: nsRange)
            }

            if state.underline {
                result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: nsRange)
            }

            if let bg = state.backgroundUIColor {
                result.addAttribute(.backgroundColor, value: bg, range: nsRange)
            }
        }

        result.endEditing()
        return result
    }

    // MARK: - CSI Parameter Parsing

    /// Parse semicolon-separated integer parameters from CSI sequence bytes.
    /// Scans utf8[from..<to], returns array of integers.
    private static func parseCSIParams(_ utf8: [UInt8], from start: Int, to end: Int) -> [Int] {
        if start >= end { return [0] }

        var codes = [Int]()
        var current = 0
        var hasDigit = false

        for i in start..<end {
            let b = utf8[i]
            if b >= 0x30 && b <= 0x39 { // '0'-'9'
                current = current &* 10 &+ Int(b &- 0x30)
                hasDigit = true
            } else if b == 0x3B { // ';'
                codes.append(hasDigit ? current : 0)
                current = 0
                hasDigit = false
            }
            // Skip other parameter/intermediate bytes
        }

        codes.append(hasDigit ? current : 0)
        return codes.isEmpty ? [0] : codes
    }
}

// MARK: - Font Cache

/// Caches UIFont variants to avoid repeated fontDescriptor lookups.
private struct FontCache {
    let base: UIFont
    private var boldFont: UIFont?
    private var italicFont: UIFont?
    private var boldItalicFont: UIFont?

    init(base: UIFont) {
        self.base = base
    }

    mutating func font(bold: Bool, italic: Bool) -> UIFont {
        if !bold && !italic { return base }

        if bold && italic {
            if let cached = boldItalicFont { return cached }
            let f = makeFont(bold: true, italic: true)
            boldItalicFont = f
            return f
        }

        if bold {
            if let cached = boldFont { return cached }
            let f = makeFont(bold: true, italic: false)
            boldFont = f
            return f
        }

        if let cached = italicFont { return cached }
        let f = makeFont(bold: false, italic: true)
        italicFont = f
        return f
    }

    private func makeFont(bold: Bool, italic: Bool) -> UIFont {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let baseTraits = base.fontDescriptor.symbolicTraits
        if baseTraits.contains(.traitMonoSpace) {
            traits.insert(.traitMonoSpace)
        }
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: base.pointSize)
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
