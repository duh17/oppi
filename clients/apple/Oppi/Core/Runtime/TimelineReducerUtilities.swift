import Foundation

// MARK: - ISO 8601 Fast Parser

/// Fast ISO 8601 date parser using ASCII arithmetic instead of DateFormatter.
/// Handles the fixed format `YYYY-MM-DDTHH:MM:SS.mmmZ` (~27μs → <1μs per call).
enum FastISO8601Parser {

    /// Parse an ISO 8601 timestamp string.
    /// Falls back to the slow formatter for non-standard formats.
    static func parse(_ s: String, fallback: ISO8601DateFormatter) -> Date {
        let utf8 = s.utf8
        // Minimum: "2006-01-02T15:04:05Z" = 20 chars
        // With fractional: "2006-01-02T15:04:05.000Z" = 24 chars
        guard utf8.count >= 20 else {
            return fallback.date(from: s) ?? Date()
        }

        var it = utf8.makeIterator()

        @inline(__always)
        func nextDigit() -> Int? {
            guard let byte = it.next() else { return nil }
            let d = Int(byte) - 48 // ASCII '0'
            guard d >= 0, d <= 9 else { return nil }
            return d
        }

        @inline(__always)
        func expect(_ expected: UInt8) -> Bool {
            guard let byte = it.next() else { return false }
            return byte == expected
        }

        // YYYY
        guard let y1 = nextDigit(), let y2 = nextDigit(),
              let y3 = nextDigit(), let y4 = nextDigit() else {
            return fallback.date(from: s) ?? Date()
        }
        let year = y1 * 1000 + y2 * 100 + y3 * 10 + y4

        guard expect(0x2D) else { return fallback.date(from: s) ?? Date() } // '-'

        // MM
        guard let m1 = nextDigit(), let m2 = nextDigit() else {
            return fallback.date(from: s) ?? Date()
        }
        let month = m1 * 10 + m2

        guard expect(0x2D) else { return fallback.date(from: s) ?? Date() } // '-'

        // DD
        guard let d1 = nextDigit(), let d2 = nextDigit() else {
            return fallback.date(from: s) ?? Date()
        }
        let day = d1 * 10 + d2

        guard expect(0x54) else { return fallback.date(from: s) ?? Date() } // 'T'

        // HH
        guard let h1 = nextDigit(), let h2 = nextDigit() else {
            return fallback.date(from: s) ?? Date()
        }
        let hour = h1 * 10 + h2

        guard expect(0x3A) else { return fallback.date(from: s) ?? Date() } // ':'

        // MM
        guard let mi1 = nextDigit(), let mi2 = nextDigit() else {
            return fallback.date(from: s) ?? Date()
        }
        let minute = mi1 * 10 + mi2

        guard expect(0x3A) else { return fallback.date(from: s) ?? Date() } // ':'

        // SS
        guard let s1 = nextDigit(), let s2 = nextDigit() else {
            return fallback.date(from: s) ?? Date()
        }
        let second = s1 * 10 + s2

        // Optional fractional seconds (.mmm or .mmmmmm)
        var fractionalSeconds: Double = 0
        if let next = it.next() {
            if next == 0x2E { // '.'
                var frac = 0
                var divisor = 1
                while let d = it.next() {
                    let digit = Int(d) - 48
                    if digit >= 0, digit <= 9 {
                        frac = frac * 10 + digit
                        divisor *= 10
                    } else {
                        // Should be 'Z' or '+'/'-' for timezone
                        break
                    }
                }
                if divisor > 1 {
                    fractionalSeconds = Double(frac) / Double(divisor)
                }
            }
            // else: next should be 'Z' — we accept it
        }

        // Direct epoch computation — avoids Calendar.date(from:) overhead.
        // Uses the civil date → days algorithm from Howard Hinnant.
        let days = daysFromCivil(year: year, month: month, day: day)
        let secs = Double(days) * 86400.0
            + Double(hour) * 3600.0
            + Double(minute) * 60.0
            + Double(second)
            + fractionalSeconds
        return Date(timeIntervalSince1970: secs)
    }

    /// Convert a civil date to days since Unix epoch (1970-01-01).
    /// Algorithm: Howard Hinnant's `days_from_civil` (public domain).
    @inline(__always)
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        var y = year
        var m = month
        if m <= 2 { y -= 1; m += 9 } else { m -= 3 }
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * m + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
}

// MARK: - String Fast Checks

/// Byte-level string utilities that avoid Unicode normalization overhead.
enum StringFastChecks {

    /// Fast byte-level check for "data:image/" substring.
    /// Avoids String.contains which does Unicode normalization (slow).
    @inline(__always)
    static func textContainsDataImagePrefix(_ text: String) -> Bool {
        // "data:image/" as UTF-8 bytes
        let needle: [UInt8] = [0x64, 0x61, 0x74, 0x61, 0x3A, 0x69, 0x6D, 0x61, 0x67, 0x65, 0x2F]
        let utf8 = text.utf8
        let needleCount = needle.count
        guard utf8.count >= needleCount else { return false }

        var idx = utf8.startIndex
        let end = utf8.endIndex
        while idx < end {
            if utf8[idx] == 0x64 { // 'd'
                // Check remaining bytes
                var ni = 1
                var si = utf8.index(after: idx)
                var match = true
                while ni < needleCount {
                    guard si < end else { match = false; break }
                    if utf8[si] != needle[ni] { match = false; break }
                    ni += 1
                    si = utf8.index(after: si)
                }
                if match { return true }
            }
            idx = utf8.index(after: idx)
        }
        return false
    }

    /// Fast whitespace-only check. Avoids `trimmingCharacters` allocation
    /// by scanning UTF-8 bytes directly.
    @inline(__always)
    static func isEffectivelyEmpty(_ text: String) -> Bool {
        if text.isEmpty { return true }
        for byte in text.utf8 {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D: continue // space, tab, newline, CR
            default: return false
            }
        }
        return true
    }
}

// MARK: - User Message Image Extraction

/// Extract data URI images from user message text.
///
/// Trace events store images as `data:image/...;base64,...` inline in the
/// text field. Rendering 1MB+ of base64 as `SwiftUI.Text` freezes the
/// main thread. This splits the text into clean display text + image
/// attachments for proper thumbnail rendering.
enum UserMessageImageExtractor {

    static func extractImagesFromText(_ text: String) -> (String, [ImageAttachment]) {
        // Fast path: skip regex when text cannot contain data URIs.
        // Use UTF-8 byte scan for 'd','a','t','a',':' prefix instead of
        // String.contains which is O(n) with Unicode normalization.
        guard text.utf8.count >= 22, // "data:image/x;base64,AA" minimum
              StringFastChecks.textContainsDataImagePrefix(text) else {
            return (text, [])
        }
        let extracted = ImageExtractor.extract(from: text)
        guard !extracted.isEmpty else { return (text, []) }

        var cleanText = text
        // Remove data URIs from text in reverse order to preserve ranges
        for image in extracted.reversed() {
            cleanText.removeSubrange(image.range)
        }
        cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

        let attachments = extracted.map { img in
            ImageAttachment(data: img.base64, mimeType: img.mimeType ?? "image/jpeg")
        }

        return (cleanText, attachments)
    }
}

// MARK: - Token Formatting

/// Format a token count with locale-aware decimal formatting (e.g. "200,000").
func formatTokenCountDecimal(_ value: Int) -> String {
    NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
}
