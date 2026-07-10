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

    // MARK: - Incremental Stripper

    /// Tracks state for incremental ANSI stripping of monotonically growing content.
    ///
    /// During streaming, each chunk delivers the full accumulated output. Calling
    /// `strip()` on the whole string every time creates O(n^2) total work.
    /// `IncrementalStripper` only processes new bytes, keeping each update O(delta).
    ///
    /// Usage:
    /// ```
    /// var stripper = ANSIParser.IncrementalStripper()
    /// // On each streaming chunk (fullOutput grows monotonically):
    /// if let delta = stripper.delta(fullOutput) {
    ///     label.text?.append(delta)
    /// }
    /// ```
    struct IncrementalStripper {

        /// Input byte count fully processed so far.
        private(set) var processedInputBytes: Int = 0

        /// UTF-16 length of all stripped output produced so far.
        private(set) var strippedUTF16Length: Int = 0

        /// Whether the last processed byte was inside an incomplete escape sequence.
        private var pendingEscapeStart: Int = -1

        /// Return stripped delta text from new bytes in a growing input.
        ///
        /// Returns `nil` when the input hasn't grown (or only added bytes
        /// inside an incomplete escape sequence at the tail).
        mutating func delta(_ fullInput: String) -> String? {
            // Use withUTF8 for contiguous access without copying.
            var result: String?
            var input = fullInput
            input.withUTF8 { buffer in
                result = processDelta(buffer)
            }
            return result
        }

        /// Reset state. Call when the input is replaced (not just appended),
        /// e.g., cell reuse for a different tool's output.
        mutating func reset() {
            processedInputBytes = 0
            strippedUTF16Length = 0
            pendingEscapeStart = -1
        }

        // MARK: - Private

        private mutating func processDelta(
            _ buf: UnsafeBufferPointer<UInt8>
        ) -> String? {
            let count = buf.count
            guard count > processedInputBytes else { return nil }

            // Start scanning from where we left off.
            // If there was a pending incomplete escape, re-scan from its start.
            let scanStart: Int
            if pendingEscapeStart >= 0 {
                scanStart = pendingEscapeStart
            } else {
                scanStart = processedInputBytes
            }
            pendingEscapeStart = -1

            // Only emit bytes at or past the processedInputBytes boundary.
            let emitBoundary = processedInputBytes

            var out = [UInt8]()
            out.reserveCapacity(count - scanStart)

            var i = scanStart
            while i < count {
                if buf[i] == 0x1B {
                    // Incomplete escape introducer at chunk boundary.
                    if i + 1 >= count {
                        pendingEscapeStart = i
                        processedInputBytes = i
                        break
                    }

                    if buf[i + 1] == 0x5B {
                        // Start of CSI sequence.
                        let escStart = i
                        var j = i + 2
                        var foundTerminator = false
                        while j < count {
                            let b = buf[j]
                            if b >= 0x40 && b <= 0x7E {
                                j += 1
                                foundTerminator = true
                                break
                            }
                            j += 1
                        }
                        if !foundTerminator {
                            // Incomplete escape — save position for re-scan.
                            pendingEscapeStart = escStart
                            processedInputBytes = escStart
                            break
                        }
                        i = j
                        continue
                    }

                    // Unsupported / standalone ESC byte. Drop it and keep scanning.
                    i += 1
                    continue
                }

                // Scan forward through non-ESC bytes.
                let start = i
                while i < count && buf[i] != 0x1B {
                    i += 1
                }
                // Only emit bytes past the boundary.
                let emitStart = max(start, emitBoundary)
                if emitStart < i {
                    for idx in emitStart..<i {
                        out.append(buf[idx])
                    }
                }
            }

            if pendingEscapeStart < 0 {
                processedInputBytes = count
            }

            guard !out.isEmpty else { return nil }
            let delta = String(decoding: out, as: UTF8.self)
            strippedUTF16Length += (delta as NSString).length
            return delta
        }
    }

    /// Strip ANSI codes from at most `maxInputBytes` of the input.
    ///
    /// O(min(n, maxInputBytes)) — safe for main-thread use on any input size.
    /// Returns the stripped prefix; the result may end mid-character if the
    /// byte boundary falls inside a multi-byte UTF-8 sequence, but
    /// `String(decoding:as:)` handles that gracefully.
    static func stripPrefix(_ input: String, maxInputBytes: Int) -> String {
        guard maxInputBytes > 0 else { return "" }
        var result: String = ""
        var mutableInput = input
        mutableInput.withUTF8 { buffer in
            let limit = min(buffer.count, maxInputBytes)
            guard limit > 0 else { return }
            // Fast path: no ESC in the prefix region.
            var hasEsc = false
            for idx in 0..<limit where buffer[idx] == 0x1B {
                hasEsc = true
                break
            }
            guard hasEsc else {
                result = String(decoding: buffer[..<limit], as: UTF8.self)
                return
            }
            var out = [UInt8]()
            out.reserveCapacity(limit)
            var i = 0
            while i < limit {
                if buffer[i] == 0x1B {
                    if i + 1 < limit, buffer[i + 1] == 0x5B {
                        var j = i + 2
                        while j < limit {
                            let b = buffer[j]
                            if b >= 0x40 && b <= 0x7E {
                                j += 1
                                break
                            }
                            j += 1
                        }
                        i = j
                    } else {
                        // Drop unsupported / standalone ESC byte.
                        i += 1
                    }
                    continue
                }

                let start = i
                while i < limit && buffer[i] != 0x1B { i += 1 }
                for idx in start..<i {
                    out.append(buffer[idx])
                }
            }
            result = String(decoding: out, as: UTF8.self)
        }
        return result
    }

    /// Strip all ANSI escape sequences, returning plain text.
    static func strip(_ input: String) -> String {
        // Fast path: no ESC byte means no ANSI codes.
        guard input.utf8.contains(0x1B) else { return input }

        let buf = Array(input.utf8)
        let count = buf.count
        var result = [UInt8]()
        result.reserveCapacity(count)

        var i = 0
        while i < count {
            if buf[i] == 0x1B {
                if i + 1 < count, buf[i + 1] == 0x5B {
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
                    // Drop unsupported / standalone ESC byte.
                    i += 1
                }
                continue
            }

            // Scan forward through non-ESC bytes in bulk.
            let start = i
            while i < count && buf[i] != 0x1B {
                i += 1
            }
            result.append(contentsOf: buf[start..<i])
        }

        return String(decoding: result, as: UTF8.self)
    }

    /// Parse ANSI escape sequences into an `NSAttributedString`.
    ///
    /// Maps ANSI colors to the Tokyo Night palette for visual consistency.
    /// Single-pass UTF-8 scan -> plain text + attribute runs -> NSAttributedString.
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
        let ansiColors = ANSIColorCache.current()
        var state = SGRState(colors: ansiColors)

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

        let buf = Array(input.utf8)
        let count = buf.count
        plainBytes.reserveCapacity(count)
        var i = 0

        while i < count {
            if buf[i] == 0x1B {
                if i + 1 < count, buf[i + 1] == 0x5B {
                    var j = i + 2
                    while j < count {
                        let b = buf[j]
                        if b >= 0x40 && b <= 0x7E { break }
                        j += 1
                    }

                    if j < count && buf[j] == 0x6D { // 'm' -> SGR
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
                    // Drop unsupported / standalone ESC byte.
                    i += 1
                }
                continue
            }

            // Fast inner loop: scan forward through ASCII bytes (< 0x80, != 0x1B)
            // without per-byte branching. This covers the vast majority of
            // terminal output (English text, numbers, punctuation).
            let textStart = i
            while i < count {
                let b = buf[i]
                if b == 0x1B || b >= 0x80 { break }
                i += 1
            }

            if i > textStart {
                // Batch-append the ASCII chunk.
                let asciiLen = i - textStart
                plainBytes.append(contentsOf: buf[textStart..<i])
                utf16Pos += asciiLen // ASCII: 1 byte = 1 UTF-16 unit
            }

            // Handle non-ASCII byte (if that's what stopped us).
            if i < count && buf[i] >= 0x80 {
                let b = buf[i]
                plainBytes.append(b)
                if b < 0xC0 { utf16Pos += 1; i += 1 }
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
        let plainString = String(decoding: plainBytes, as: UTF8.self)
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

// MARK: - Cached Theme Colors

/// Pre-resolved UIColors for ANSI output for one active theme.
private struct ANSIThemeColors {
    // Foreground
    let fgDim: UIColor
    let red: UIColor
    let green: UIColor
    let yellow: UIColor
    let blue: UIColor
    let purple: UIColor
    let cyan: UIColor
    let fg: UIColor
    let comment: UIColor

    // Background (standard 40-47)
    let bgBlack: UIColor
    let bgRed: UIColor
    let bgGreen: UIColor
    let bgYellow: UIColor
    let bgBlue: UIColor
    let bgPurple: UIColor
    let bgCyan: UIColor
    let bgWhite: UIColor

    // Background (bright 100-107)
    let bgBrightBlack: UIColor
    let bgBrightRed: UIColor
    let bgBrightGreen: UIColor
    let bgBrightYellow: UIColor
    let bgBrightBlue: UIColor
    let bgBrightPurple: UIColor
    let bgBrightCyan: UIColor
    let bgBrightWhite: UIColor

    let color256Palette: [UIColor]

    init(themeID: ThemeID) {
        let palette = themeID.palette
        let fgDim = UIColor(palette.fgDim)
        let red = UIColor(palette.red)
        let green = UIColor(palette.green)
        let yellow = UIColor(palette.yellow)
        let blue = UIColor(palette.blue)
        let purple = UIColor(palette.purple)
        let cyan = UIColor(palette.cyan)
        let fg = UIColor(palette.fg)
        let comment = UIColor(palette.comment)

        self.fgDim = fgDim
        self.red = red
        self.green = green
        self.yellow = yellow
        self.blue = blue
        self.purple = purple
        self.cyan = cyan
        self.fg = fg
        self.comment = comment

        self.bgBlack = UIColor(palette.fgDim.opacity(0.35))
        self.bgRed = UIColor(palette.red.opacity(0.55))
        self.bgGreen = UIColor(palette.green.opacity(0.45))
        self.bgYellow = UIColor(palette.yellow.opacity(0.45))
        self.bgBlue = UIColor(palette.blue.opacity(0.45))
        self.bgPurple = UIColor(palette.purple.opacity(0.45))
        self.bgCyan = UIColor(palette.cyan.opacity(0.40))
        self.bgWhite = UIColor(palette.fg.opacity(0.20))

        self.bgBrightBlack = UIColor(palette.comment.opacity(0.30))
        self.bgBrightRed = UIColor(palette.red.opacity(0.65))
        self.bgBrightGreen = UIColor(palette.green.opacity(0.55))
        self.bgBrightYellow = UIColor(palette.yellow.opacity(0.55))
        self.bgBrightBlue = UIColor(palette.blue.opacity(0.55))
        self.bgBrightPurple = UIColor(palette.purple.opacity(0.55))
        self.bgBrightCyan = UIColor(palette.cyan.opacity(0.50))
        self.bgBrightWhite = UIColor(palette.fg.opacity(0.30))

        var colors = Array(repeating: fg, count: 256)
        colors[0] = fgDim
        colors[1] = red
        colors[2] = green
        colors[3] = yellow
        colors[4] = blue
        colors[5] = purple
        colors[6] = cyan
        colors[7] = fg
        colors[8] = fgDim
        colors[9] = red
        colors[10] = green
        colors[11] = yellow
        colors[12] = blue
        colors[13] = purple
        colors[14] = cyan
        colors[15] = fg

        for n in 16..<232 {
            let idx = n - 16
            let redComponent = CGFloat((idx / 36) % 6) / 5.0
            let greenComponent = CGFloat((idx / 6) % 6) / 5.0
            let blueComponent = CGFloat(idx % 6) / 5.0
            colors[n] = UIColor(red: redComponent, green: greenComponent, blue: blueComponent, alpha: 1)
        }

        for n in 232..<256 {
            let gray = CGFloat(n - 232) / 23.0
            colors[n] = UIColor(white: gray, alpha: 1)
        }

        self.color256Palette = colors
    }
}

/// Created once per active theme, avoids repeated `UIColor(Color.themeX)` bridge calls.
private enum ANSIColorCache {
    private final class CacheBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: ANSIThemeColors?
        private var cachedThemeID: ThemeID?

        func current() -> ANSIThemeColors {
            let currentThemeID = ThemeRuntimeState.currentThemeID()

            lock.lock()
            if let cached, cachedThemeID == currentThemeID {
                lock.unlock()
                return cached
            }
            lock.unlock()

            let colors = ANSIThemeColors(themeID: currentThemeID)

            lock.lock()
            cached = colors
            cachedThemeID = currentThemeID
            lock.unlock()
            return colors
        }
    }

    private static let cacheBox = CacheBox()

    static func current() -> ANSIThemeColors {
        cacheBox.current()
    }
}

// MARK: - SGR State

/// Tracks cumulative SGR state across escape sequences.
private struct SGRState {
    let colors: ANSIThemeColors

    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var foregroundUIColor: UIColor?
    var backgroundUIColor: UIColor?

    /// Apply SGR codes parsed directly from a UTF-8 byte array.
    /// Parses semicolon-separated integers inline -- no array allocation.
    mutating func applyFromBuffer(
        _ buf: [UInt8],
        from start: Int,
        to end: Int
    ) {
        if start >= end {
            // Bare ESC[m = reset
            reset()
            return
        }

        if applyDirectExtendedColorFastPath(buf, from: start, to: end) {
            return
        }
        if applyDirectSingleCodeFastPath(buf, from: start, to: end) {
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

        // Multi-code sequence -- parse and apply in one pass to avoid an
        // intermediate array allocation.
        var current = 0
        var hasDigit = false
        var pendingColorTarget = 0 // 38 or 48
        var pendingColorMode = 0 // 5 or 2
        var rgb0 = 0
        var rgb1 = 0
        var rgbComponent = 0

        func applyPendingColor(_ color: UIColor) {
            if pendingColorTarget == 38 {
                foregroundUIColor = color
            } else if pendingColorTarget == 48 {
                backgroundUIColor = color
            }
            pendingColorTarget = 0
            pendingColorMode = 0
            rgbComponent = 0
        }

        func applyCode(_ code: Int) {
            if pendingColorMode == 5 {
                applyPendingColor(color256(code))
                return
            }

            if pendingColorMode == 2 {
                switch rgbComponent {
                case 0:
                    rgb0 = code
                    rgbComponent = 1
                case 1:
                    rgb1 = code
                    rgbComponent = 2
                default:
                    applyPendingColor(UIColor(
                        red: CGFloat(rgb0) / 255,
                        green: CGFloat(rgb1) / 255,
                        blue: CGFloat(code) / 255,
                        alpha: 1
                    ))
                }
                return
            }

            if pendingColorTarget != 0 {
                if code == 5 || code == 2 {
                    pendingColorMode = code
                    rgbComponent = 0
                    return
                }
                pendingColorTarget = 0
            }

            if code == 38 || code == 48 {
                pendingColorTarget = code
                return
            }

            applySingleCode(code)
        }

        for i in start..<end {
            let b = buf[i]
            if b >= 0x30 && b <= 0x39 {
                current = current &* 10 &+ Int(b &- 0x30)
                hasDigit = true
            } else if b == 0x3B {
                applyCode(hasDigit ? current : 0)
                current = 0
                hasDigit = false
            }
        }
        applyCode(hasDigit ? current : 0)
    }

    // MARK: - Fast Paths

    private mutating func applyDirectSingleCodeFastPath(
        _ buf: [UInt8],
        from start: Int,
        to end: Int
    ) -> Bool {
        let length = end - start
        switch length {
        case 1:
            let b0 = buf[start]
            switch b0 {
            case 0x30: applySingleCode(0); return true
            case 0x31: applySingleCode(1); return true
            case 0x32: applySingleCode(2); return true
            case 0x33: applySingleCode(3); return true
            case 0x34: applySingleCode(4); return true
            default: return false
            }
        case 2:
            let b0 = buf[start]
            let b1 = buf[start + 1]
            guard b0 >= 0x30, b0 <= 0x39, b1 >= 0x30, b1 <= 0x39 else { return false }
            let value = Int(b0 - 0x30) * 10 + Int(b1 - 0x30)
            applySingleCode(value)
            return true
        default:
            return false
        }
    }

    private mutating func applyDirectExtendedColorFastPath(
        _ buf: [UInt8],
        from start: Int,
        to end: Int
    ) -> Bool {
        guard end - start >= 6 else { return false }

        if buf[start] == 0x33, buf[start + 1] == 0x38, buf[start + 2] == 0x3B { // 38;
            if buf[start + 3] == 0x35, buf[start + 4] == 0x3B, // 5;
               let value = parseDecimal(buf, from: start + 5, to: end) {
                foregroundUIColor = color256(value)
                return true
            }
            if buf[start + 3] == 0x32, buf[start + 4] == 0x3B, // 2;
               let rgb = parseRGBTriplet(buf, from: start + 5, to: end) {
                foregroundUIColor = UIColor(
                    red: CGFloat(rgb.0) / 255,
                    green: CGFloat(rgb.1) / 255,
                    blue: CGFloat(rgb.2) / 255,
                    alpha: 1
                )
                return true
            }
        }

        if buf[start] == 0x34, buf[start + 1] == 0x38, buf[start + 2] == 0x3B { // 48;
            if buf[start + 3] == 0x35, buf[start + 4] == 0x3B,
               let value = parseDecimal(buf, from: start + 5, to: end) {
                backgroundUIColor = color256(value)
                return true
            }
            if buf[start + 3] == 0x32, buf[start + 4] == 0x3B,
               let rgb = parseRGBTriplet(buf, from: start + 5, to: end) {
                backgroundUIColor = UIColor(
                    red: CGFloat(rgb.0) / 255,
                    green: CGFloat(rgb.1) / 255,
                    blue: CGFloat(rgb.2) / 255,
                    alpha: 1
                )
                return true
            }
        }

        return false
    }

    private func parseDecimal(
        _ buf: [UInt8],
        from start: Int,
        to end: Int
    ) -> Int? {
        guard start < end else { return nil }
        var value = 0
        for i in start..<end {
            let b = buf[i]
            guard b >= 0x30 && b <= 0x39 else { return nil }
            value = value * 10 + Int(b - 0x30)
        }
        return value
    }

    private func parseRGBTriplet(
        _ buf: [UInt8],
        from start: Int,
        to end: Int
    ) -> (Int, Int, Int)? {
        var values = (0, 0, 0)
        var component = 0
        var current = 0
        var hasDigit = false

        for i in start..<end {
            let b = buf[i]
            if b >= 0x30 && b <= 0x39 {
                current = current * 10 + Int(b - 0x30)
                hasDigit = true
            } else if b == 0x3B {
                guard hasDigit, component < 2 else { return nil }
                if component == 0 { values.0 = current }
                else { values.1 = current }
                component += 1
                current = 0
                hasDigit = false
            } else {
                return nil
            }
        }

        guard hasDigit, component == 2 else { return nil }
        values.2 = current
        return values
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

        case 30: foregroundUIColor = colors.fgDim
        case 31: foregroundUIColor = colors.red
        case 32: foregroundUIColor = colors.green
        case 33: foregroundUIColor = colors.yellow
        case 34: foregroundUIColor = colors.blue
        case 35: foregroundUIColor = colors.purple
        case 36: foregroundUIColor = colors.cyan
        case 37: foregroundUIColor = colors.fg

        case 90: foregroundUIColor = colors.comment
        case 91: foregroundUIColor = colors.red
        case 92: foregroundUIColor = colors.green
        case 93: foregroundUIColor = colors.yellow
        case 94: foregroundUIColor = colors.blue
        case 95: foregroundUIColor = colors.purple
        case 96: foregroundUIColor = colors.cyan
        case 97: foregroundUIColor = colors.fg

        case 40: backgroundUIColor = colors.bgBlack
        case 41: backgroundUIColor = colors.bgRed
        case 42: backgroundUIColor = colors.bgGreen
        case 43: backgroundUIColor = colors.bgYellow
        case 44: backgroundUIColor = colors.bgBlue
        case 45: backgroundUIColor = colors.bgPurple
        case 46: backgroundUIColor = colors.bgCyan
        case 47: backgroundUIColor = colors.bgWhite

        case 100: backgroundUIColor = colors.bgBrightBlack
        case 101: backgroundUIColor = colors.bgBrightRed
        case 102: backgroundUIColor = colors.bgBrightGreen
        case 103: backgroundUIColor = colors.bgBrightYellow
        case 104: backgroundUIColor = colors.bgBrightBlue
        case 105: backgroundUIColor = colors.bgBrightPurple
        case 106: backgroundUIColor = colors.bgBrightCyan
        case 107: backgroundUIColor = colors.bgBrightWhite

        default: break
        }
    }

    private func color256(_ n: Int) -> UIColor {
        if n >= 0 && n < colors.color256Palette.count {
            return colors.color256Palette[n]
        }
        return colors.fg
    }
}
