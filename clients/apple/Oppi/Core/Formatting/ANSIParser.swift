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

        var result = [UInt8]()
        result.reserveCapacity(input.utf8.count)

        input.utf8.withContiguousStorageIfAvailable { buf in
            let count = buf.count
            var i = 0
            while i < count {
                if buf[i] == 0x1B, i + 1 < count, buf[i + 1] == 0x5B {
                    var j = i + 2
                    while j < count {
                        let b = buf[j]
                        if b >= 0x40 && b <= 0x7E {
                            j += 1
                            break
                        }
                        j += 1
                    }
                    i = j
                } else {
                    result.append(buf[i])
                    i += 1
                }
            }
        }

        return String(bytes: result, encoding: .utf8) ?? input
    }

    /// Parse ANSI escape sequences into an `NSAttributedString`.
    ///
    /// Maps ANSI colors to the Tokyo Night palette for visual consistency.
    /// Single-pass UTF-8 scan → plain text + attribute runs → NSAttributedString.
    static func attributedString(
        from input: String,
        baseForeground: Color = .themeFg
    ) -> NSAttributedString {
        let baseFg = UIColor(baseForeground)
        let baseFont = AppFont.mono

        // Fast path: no ESC byte means no ANSI codes.
        guard input.utf8.contains(0x1B) else {
            return NSAttributedString(
                string: input,
                attributes: [.font: baseFont, .foregroundColor: baseFg]
            )
        }

        var fontCache = FontCache(base: baseFont)
        var state = SGRState()

        // Phase 1: Single-pass scan. Build plain text and record attribute runs.
        struct AttrRun {
            let utf16Start: Int
            let utf16Length: Int
            let font: UIFont
            let fg: UIColor?
            let bg: UIColor?
            let underline: Bool
        }

        var plainBytes = [UInt8]()
        var runs = [AttrRun]()

        // Track UTF-16 position incrementally as we build plainBytes.
        var utf16Pos = 0
        var runStart16 = 0
        var hasSGR = false

        input.utf8.withContiguousStorageIfAvailable { buf in
            let count = buf.count
            plainBytes.reserveCapacity(count)
            var i = 0

            while i < count {
                if buf[i] == 0x1B, i + 1 < count, buf[i + 1] == 0x5B {
                    var j = i + 2
                    while j < count {
                        let b = buf[j]
                        if b >= 0x40 && b <= 0x7E { break }
                        j += 1
                    }

                    if j < count && buf[j] == 0x6D { // 'm' → SGR
                        let runLen16 = utf16Pos - runStart16
                        if hasSGR && runLen16 > 0 {
                            runs.append(AttrRun(
                                utf16Start: runStart16,
                                utf16Length: runLen16,
                                font: fontCache.font(bold: state.bold, italic: state.italic),
                                fg: state.foregroundUIColor,
                                bg: state.backgroundUIColor,
                                underline: state.underline
                            ))
                        }

                        state.applyFromBuffer(buf, from: i + 2, to: j)
                        hasSGR = true
                        runStart16 = utf16Pos
                    }

                    i = j + 1
                } else {
                    let b = buf[i]
                    plainBytes.append(b)
                    if b < 0x80 { utf16Pos += 1; i += 1 }
                    else if b < 0xC0 { i += 1 }
                    else if b < 0xE0 {
                        if i + 1 < count { plainBytes.append(buf[i + 1]) }
                        utf16Pos += 1; i += 2
                    } else if b < 0xF0 {
                        if i + 1 < count { plainBytes.append(buf[i + 1]) }
                        if i + 2 < count { plainBytes.append(buf[i + 2]) }
                        utf16Pos += 1; i += 3
                    } else {
                        if i + 1 < count { plainBytes.append(buf[i + 1]) }
                        if i + 2 < count { plainBytes.append(buf[i + 2]) }
                        if i + 3 < count { plainBytes.append(buf[i + 3]) }
                        utf16Pos += 2; i += 4
                    }
                }
            }
        }

        // Close final run
        if hasSGR {
            let runLen16 = utf16Pos - runStart16
            if runLen16 > 0 {
                runs.append(AttrRun(
                    utf16Start: runStart16,
                    utf16Length: runLen16,
                    font: fontCache.font(bold: state.bold, italic: state.italic),
                    fg: state.foregroundUIColor,
                    bg: state.backgroundUIColor,
                    underline: state.underline
                ))
            }
        }

        // Phase 2: Build NSMutableAttributedString
        let plainString = String(bytes: plainBytes, encoding: .utf8) ?? ""
        let result = NSMutableAttributedString(
            string: plainString,
            attributes: [.font: baseFont, .foregroundColor: baseFg]
        )

        guard !runs.isEmpty else { return result }

        result.beginEditing()

        for run in runs {
            let nsRange = NSRange(location: run.utf16Start, length: run.utf16Length)

            if run.font !== baseFont {
                result.addAttribute(.font, value: run.font, range: nsRange)
            }
            if let fg = run.fg {
                result.addAttribute(.foregroundColor, value: fg, range: nsRange)
            }
            if run.underline {
                result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: nsRange)
            }
            if let bg = run.bg {
                result.addAttribute(.backgroundColor, value: bg, range: nsRange)
            }
        }

        result.endEditing()
        return result
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

// MARK: - Inline SGR Code Buffer

/// Fixed-capacity buffer for parsing SGR codes inline (no heap allocation).
/// Uses two 2-tuples to stay within SwiftLint's large_tuple limit while
/// supporting up to 6 codes (covers `48;2;r;g;b` = 5 codes + spare).
private struct InlineSGRCodes {
    private var lo: (Int, Int) = (0, 0)
    private var hi: (Int, Int) = (0, 0)
    private var ex: (Int, Int) = (0, 0)
    private(set) var count = 0

    mutating func append(_ value: Int) {
        switch count {
        case 0: lo.0 = value
        case 1: lo.1 = value
        case 2: hi.0 = value
        case 3: hi.1 = value
        case 4: ex.0 = value
        case 5: ex.1 = value
        default: return
        }
        count += 1
    }

    subscript(index: Int) -> Int {
        switch index {
        case 0: return lo.0
        case 1: return lo.1
        case 2: return hi.0
        case 3: return hi.1
        case 4: return ex.0
        case 5: return ex.1
        default: return 0
        }
    }
}

// MARK: - Cached Theme Colors

/// Pre-resolved UIColors for ANSI → Tokyo Night mapping.
/// Created once, avoids repeated `UIColor(Color.themeX)` bridge calls.
private enum ANSIColorCache {
    // Foreground
    static let fgDim = UIColor(Color.themeFgDim)
    static let red = UIColor(Color.themeRed)
    static let green = UIColor(Color.themeGreen)
    static let yellow = UIColor(Color.themeYellow)
    static let blue = UIColor(Color.themeBlue)
    static let purple = UIColor(Color.themePurple)
    static let cyan = UIColor(Color.themeCyan)
    static let fg = UIColor(Color.themeFg)
    static let comment = UIColor(Color.themeComment)

    // Background (standard 40-47)
    static let bgBlack = UIColor(Color.themeFgDim.opacity(0.35))
    static let bgRed = UIColor(Color.themeRed.opacity(0.55))
    static let bgGreen = UIColor(Color.themeGreen.opacity(0.45))
    static let bgYellow = UIColor(Color.themeYellow.opacity(0.45))
    static let bgBlue = UIColor(Color.themeBlue.opacity(0.45))
    static let bgPurple = UIColor(Color.themePurple.opacity(0.45))
    static let bgCyan = UIColor(Color.themeCyan.opacity(0.40))
    static let bgWhite = UIColor(Color.themeFg.opacity(0.20))

    // Background (bright 100-107)
    static let bgBrightBlack = UIColor(Color.themeComment.opacity(0.30))
    static let bgBrightRed = UIColor(Color.themeRed.opacity(0.65))
    static let bgBrightGreen = UIColor(Color.themeGreen.opacity(0.55))
    static let bgBrightYellow = UIColor(Color.themeYellow.opacity(0.55))
    static let bgBrightBlue = UIColor(Color.themeBlue.opacity(0.55))
    static let bgBrightPurple = UIColor(Color.themePurple.opacity(0.55))
    static let bgBrightCyan = UIColor(Color.themeCyan.opacity(0.50))
    static let bgBrightWhite = UIColor(Color.themeFg.opacity(0.30))
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

    /// Apply SGR codes parsed directly from a UTF-8 buffer pointer.
    /// Parses semicolon-separated integers inline — no array allocation.
    mutating func applyFromBuffer(
        _ buf: UnsafeBufferPointer<UInt8>,
        from start: Int,
        to end: Int
    ) {
        if start >= end {
            // Bare ESC[m = reset
            reset()
            return
        }

        // Fast path: single-code sequences (most common).
        // Check if the sequence contains no semicolons.
        var hasSemicolon = false
        var singleValue = 0
        var digitCount = 0
        for i in start..<end {
            let b = buf[i]
            if b == 0x3B { hasSemicolon = true; break }
            if b >= 0x30 && b <= 0x39 {
                singleValue = singleValue &* 10 &+ Int(b &- 0x30)
                digitCount += 1
            }
        }

        if !hasSemicolon {
            applySingleCode(digitCount > 0 ? singleValue : 0)
            return
        }

        // Multi-code sequence — parse all codes
        var codes = InlineSGRCodes()
        var current = 0
        var hasDigit = false

        for i in start..<end {
            let b = buf[i]
            if b >= 0x30 && b <= 0x39 {
                current = current &* 10 &+ Int(b &- 0x30)
                hasDigit = true
            } else if b == 0x3B {
                codes.append(hasDigit ? current : 0)
                current = 0
                hasDigit = false
            }
        }
        codes.append(hasDigit ? current : 0)

        // Apply codes with lookahead for extended colors
        var i = 0
        while i < codes.count {
            let code = codes[i]

            if code == 38, i + 2 < codes.count, codes[i + 1] == 5 {
                foregroundUIColor = color256(codes[i + 2])
                i += 3; continue
            }
            if code == 38, i + 4 < codes.count, codes[i + 1] == 2 {
                foregroundUIColor = UIColor(
                    red: CGFloat(codes[i + 2]) / 255,
                    green: CGFloat(codes[i + 3]) / 255,
                    blue: CGFloat(codes[i + 4]) / 255,
                    alpha: 1
                )
                i += 5; continue
            }
            if code == 48, i + 2 < codes.count, codes[i + 1] == 5 {
                backgroundUIColor = color256(codes[i + 2])
                i += 3; continue
            }
            if code == 48, i + 4 < codes.count, codes[i + 1] == 2 {
                backgroundUIColor = UIColor(
                    red: CGFloat(codes[i + 2]) / 255,
                    green: CGFloat(codes[i + 3]) / 255,
                    blue: CGFloat(codes[i + 4]) / 255,
                    alpha: 1
                )
                i += 5; continue
            }

            applySingleCode(code)
            i += 1
        }
    }

    // MARK: - Single Code

    private mutating func reset() {
        bold = false; dim = false; italic = false
        underline = false; foregroundUIColor = nil; backgroundUIColor = nil
    }

    private mutating func applySingleCode(_ code: Int) {
        switch code {
        case 0: reset()
        case 1: bold = true
        case 2: dim = true
        case 3: italic = true
        case 4: underline = true
        case 22: bold = false; dim = false
        case 23: italic = false
        case 24: underline = false
        case 39: foregroundUIColor = nil
        case 49: backgroundUIColor = nil

        case 30: foregroundUIColor = ANSIColorCache.fgDim
        case 31: foregroundUIColor = ANSIColorCache.red
        case 32: foregroundUIColor = ANSIColorCache.green
        case 33: foregroundUIColor = ANSIColorCache.yellow
        case 34: foregroundUIColor = ANSIColorCache.blue
        case 35: foregroundUIColor = ANSIColorCache.purple
        case 36: foregroundUIColor = ANSIColorCache.cyan
        case 37: foregroundUIColor = ANSIColorCache.fg

        case 90: foregroundUIColor = ANSIColorCache.comment
        case 91: foregroundUIColor = ANSIColorCache.red
        case 92: foregroundUIColor = ANSIColorCache.green
        case 93: foregroundUIColor = ANSIColorCache.yellow
        case 94: foregroundUIColor = ANSIColorCache.blue
        case 95: foregroundUIColor = ANSIColorCache.purple
        case 96: foregroundUIColor = ANSIColorCache.cyan
        case 97: foregroundUIColor = ANSIColorCache.fg

        case 40: backgroundUIColor = ANSIColorCache.bgBlack
        case 41: backgroundUIColor = ANSIColorCache.bgRed
        case 42: backgroundUIColor = ANSIColorCache.bgGreen
        case 43: backgroundUIColor = ANSIColorCache.bgYellow
        case 44: backgroundUIColor = ANSIColorCache.bgBlue
        case 45: backgroundUIColor = ANSIColorCache.bgPurple
        case 46: backgroundUIColor = ANSIColorCache.bgCyan
        case 47: backgroundUIColor = ANSIColorCache.bgWhite

        case 100: backgroundUIColor = ANSIColorCache.bgBrightBlack
        case 101: backgroundUIColor = ANSIColorCache.bgBrightRed
        case 102: backgroundUIColor = ANSIColorCache.bgBrightGreen
        case 103: backgroundUIColor = ANSIColorCache.bgBrightYellow
        case 104: backgroundUIColor = ANSIColorCache.bgBrightBlue
        case 105: backgroundUIColor = ANSIColorCache.bgBrightPurple
        case 106: backgroundUIColor = ANSIColorCache.bgBrightCyan
        case 107: backgroundUIColor = ANSIColorCache.bgBrightWhite

        default: break
        }
    }

    private func color256(_ n: Int) -> UIColor {
        switch n {
        case 0: return ANSIColorCache.fgDim
        case 1: return ANSIColorCache.red
        case 2: return ANSIColorCache.green
        case 3: return ANSIColorCache.yellow
        case 4: return ANSIColorCache.blue
        case 5: return ANSIColorCache.purple
        case 6: return ANSIColorCache.cyan
        case 7: return ANSIColorCache.fg
        case 8...15: return color256(n - 8)
        case 232...255:
            let gray = CGFloat(n - 232) / 23.0
            return UIColor(white: gray, alpha: 1)
        default:
            let idx = n - 16
            let r = CGFloat((idx / 36) % 6) / 5.0
            let g = CGFloat((idx / 6) % 6) / 5.0
            let b = CGFloat(idx % 6) / 5.0
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        }
    }
}
