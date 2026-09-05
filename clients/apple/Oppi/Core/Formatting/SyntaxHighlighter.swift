import SwiftUI // Theme color resolution (Color.themeSyntax* → UIColor)
import UIKit

// MARK: - SyntaxHighlighter

/// Identity of one highlight request. Views keep one current identity so a
/// delayed paint cannot install onto replaced content or a stale theme.
struct SyntaxHighlightIdentity: Equatable, Sendable {
    let code: String
    let language: String?
    let themeID: ThemeID
}

/// UIKit syntax-highlighting adapter used by the iOS app.
///
/// Token ranges come from OppiCore's shared provider (`TreeSitterHighlighter`
/// with `SyntaxTokenScanner` fallback). This type handles iOS-specific theme
/// color resolution and `NSAttributedString` construction.
enum SyntaxHighlighter {

    typealias TokenKind = SyntaxTokenKind
    typealias TokenRange = SyntaxTokenRange

    /// Maximum lines that receive syntax color. Displayed source is not truncated.
    static let maxLines = SyntaxTokenScanner.maxLines

    // MARK: - Pre-computed Token Attributes

    /// Resolved UIColor attribute dictionaries for each token type.
    /// Created once per top-level highlight call to avoid repeated
    /// `UIColor(Color)` conversions per token.
    private struct TokenAttrs {
        let comment: [NSAttributedString.Key: Any]
        let keyword: [NSAttributedString.Key: Any]
        let string: [NSAttributedString.Key: Any]
        let number: [NSAttributedString.Key: Any]
        let type: [NSAttributedString.Key: Any]
        let variable: [NSAttributedString.Key: Any]
        let punctuation: [NSAttributedString.Key: Any]
        let function: [NSAttributedString.Key: Any]
        let `operator`: [NSAttributedString.Key: Any]

        // Cache: UIColor(Color) is expensive (~10μs each × 9 = ~90μs per call).
        // Key by theme because tool render caches may ask for a fresh render after
        // `ThemeRuntimeState` changes without restarting the process.
        private final class CacheBox: @unchecked Sendable {
            private let lock = NSLock()
            private var cached: TokenAttrs?
            private var cachedThemeID: ThemeID?

            func attrs(for themeID: ThemeID) -> TokenAttrs {
                lock.lock()
                if let cached, cachedThemeID == themeID {
                    lock.unlock()
                    return cached
                }
                lock.unlock()

                let palette = themeID.palette
                let attrs = TokenAttrs(
                    comment: [.foregroundColor: UIColor(palette.syntaxComment)],
                    keyword: [.foregroundColor: UIColor(palette.syntaxKeyword)],
                    string: [.foregroundColor: UIColor(palette.syntaxString)],
                    number: [.foregroundColor: UIColor(palette.syntaxNumber)],
                    type: [.foregroundColor: UIColor(palette.syntaxType)],
                    variable: [.foregroundColor: UIColor(palette.syntaxVariable)],
                    punctuation: [.foregroundColor: UIColor(palette.syntaxPunctuation)],
                    function: [.foregroundColor: UIColor(palette.syntaxFunction)],
                    operator: [.foregroundColor: UIColor(palette.syntaxOperator)]
                )

                lock.lock()
                cached = attrs
                cachedThemeID = themeID
                lock.unlock()
                return attrs
            }
        }

        private static let cacheBox = CacheBox()

        // Called from Task.detached for performance — must remain nonisolated.
        static func forTheme(_ themeID: ThemeID) -> Self {
            cacheBox.attrs(for: themeID)
        }
    }

    // MARK: - Public API

    /// Resolve a token kind to its UIColor using the cached TokenAttrs.
    static func color(for kind: TokenKind, themeID: ThemeID = ThemeRuntimeState.currentThemeID()) -> UIColor? {
        guard kind != .variable else { return nil }
        let attrs = TokenAttrs.forTheme(themeID)
        let dict: [NSAttributedString.Key: Any]
        switch kind {
        case .variable: return nil
        case .comment: dict = attrs.comment
        case .keyword: dict = attrs.keyword
        case .string: dict = attrs.string
        case .number: dict = attrs.number
        case .type: dict = attrs.type
        case .punctuation: dict = attrs.punctuation
        case .function: dict = attrs.function
        case .operator: dict = attrs.operator
        }
        return dict[.foregroundColor] as? UIColor
    }

    /// Scan source code and return token ranges for non-default tokens.
    ///
    /// Delegates to the shared OppiCore provider so iOS and Mac paint the same
    /// `[SyntaxTokenRange]` values.
    static func scanTokenRanges(
        _ code: String,
        language: SyntaxLanguage
    ) -> [TokenRange] {
        TreeSitterHighlighter.resolvedTokenRanges(code, language: language)
    }

    /// Highlight source code using range-based attribute application.
    ///
    /// Builds a single NSMutableAttributedString from the full text with default
    /// (variable) color, then applies token-specific colors by NSRange. This avoids
    /// creating thousands of intermediate NSAttributedString objects per token.
    static func highlight(_ code: String, language: SyntaxLanguage) -> NSAttributedString {
        highlight(code, language: language, themeID: ThemeRuntimeState.currentThemeID())
    }

    static func highlight(_ code: String, language: SyntaxLanguage, themeID: ThemeID) -> NSAttributedString {
        let attrs = TokenAttrs.forTheme(themeID)

        // Keep the full source. Token work is bounded by SyntaxTokenScanner.maxLines.
        let result = NSMutableAttributedString(string: code, attributes: attrs.variable)
        let tokenRanges = TreeSitterHighlighter.resolvedTokenRanges(code, language: language)
        let nsLength = result.length

        // Pre-extract UIColors to avoid dictionary lookup + cast per token.
        let commentColor = attrs.comment[.foregroundColor] as? UIColor
        let keywordColor = attrs.keyword[.foregroundColor] as? UIColor
        let stringColor = attrs.string[.foregroundColor] as? UIColor
        let numberColor = attrs.number[.foregroundColor] as? UIColor
        let typeColor = attrs.type[.foregroundColor] as? UIColor
        let punctuationColor = attrs.punctuation[.foregroundColor] as? UIColor
        let functionColor = attrs.function[.foregroundColor] as? UIColor
        let operatorColor = attrs.operator[.foregroundColor] as? UIColor

        // Apply token colors by range.
        for token in tokenRanges {
            let color: UIColor?
            switch token.kind {
            case .variable: continue // already default
            case .comment: color = commentColor
            case .keyword: color = keywordColor
            case .string: color = stringColor
            case .number: color = numberColor
            case .type: color = typeColor
            case .punctuation: color = punctuationColor
            case .function: color = functionColor
            case .operator: color = operatorColor
            }
            if let color {
                let range = NSRange(location: token.location, length: token.length)
                guard range.location >= 0, NSMaxRange(range) <= nsLength else { continue }
                result.addAttribute(
                    .foregroundColor,
                    value: color,
                    range: range
                )
            }
        }

        return result
    }

    /// Maps one source-space token onto sorted line starts, then walks only
    /// forward while a line can still overlap the token.
    ///
    /// Used by guttered code and per-hunk diff painting. Each token is located
    /// independently so out-of-order captures (XML `<`/`>` after attributes)
    /// still hit earlier lines. Returns how many lines the inner walk inspected.
    @discardableResult
    static func forEachOverlappingSourceLine(
        lineStarts: [Int],
        tokenStart: Int,
        tokenEnd: Int,
        lineLengthAt: (Int) -> Int,
        body: (_ lineIndex: Int, _ overlapStart: Int, _ overlapEnd: Int) -> Void
    ) -> Int {
        var examined = 0
        guard tokenEnd > tokenStart, !lineStarts.isEmpty else { return 0 }

        // Last start <= tokenStart is the line that contains the token start
        // (or line 0 if the token begins before the first line).
        var low = 0
        var high = lineStarts.count
        while low < high {
            let mid = low + (high - low) / 2
            if lineStarts[mid] <= tokenStart {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var lineIdx = low == 0 ? 0 : low - 1

        while lineIdx < lineStarts.count {
            let lineStart = lineStarts[lineIdx]
            if lineStart >= tokenEnd { break }
            examined += 1
            let lineEnd = lineStart + lineLengthAt(lineIdx)
            let overlapStart = max(tokenStart, lineStart)
            let overlapEnd = min(tokenEnd, lineEnd)
            if overlapStart < overlapEnd {
                body(lineIdx, overlapStart, overlapEnd)
            }
            lineIdx += 1
        }
        return examined
    }
}
