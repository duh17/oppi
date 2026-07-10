import SwiftUI // Theme color resolution (Color.themeSyntax* → UIColor)
import UIKit

// MARK: - SyntaxHighlighter

/// UIKit syntax-highlighting adapter used by the iOS app.
///
/// The scanner itself lives in `OppiCore` as `SyntaxTokenScanner`; this type
/// handles iOS-specific theme color resolution, optional tree-sitter dispatch,
/// and `NSAttributedString` construction.
enum SyntaxHighlighter {

    typealias TokenKind = SyntaxTokenKind
    typealias TokenRange = SyntaxTokenRange

    /// Maximum lines to highlight before truncating.
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

            func current() -> TokenAttrs {
                let currentThemeID = ThemeRuntimeState.currentThemeID()

                lock.lock()
                if let cached, cachedThemeID == currentThemeID {
                    lock.unlock()
                    return cached
                }
                lock.unlock()

                let palette = currentThemeID.palette
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
                cachedThemeID = currentThemeID
                lock.unlock()
                return attrs
            }
        }

        private static let cacheBox = CacheBox()

        // Called from Task.detached for performance — must remain nonisolated.
        static func current() -> Self {
            cacheBox.current()
        }
    }

    // MARK: - Public API

    /// Resolve a token kind to its UIColor using the cached TokenAttrs.
    static func color(for kind: TokenKind) -> UIColor? {
        guard kind != .variable else { return nil }
        let attrs = TokenAttrs.current()
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
    /// Tree-sitter is used when a grammar is registered; otherwise this falls
    /// back to the shared `SyntaxTokenScanner` in `OppiCore`.
    static func scanTokenRanges(
        _ code: String,
        language: SyntaxLanguage
    ) -> [TokenRange] {
        resolveTokenRanges(code, language: language)
    }

    /// ASCII-optimized scanner using raw UTF-8 bytes where possible.
    ///
    /// Used by `DiffAttributedStringBuilder` for batch syntax scanning. When
    /// tree-sitter supports a language, dispatch through that path first so iOS
    /// shell highlighting keeps the upstream Bash grammar behavior.
    static func scanTokenRangesUTF8(
        _ text: String,
        language: SyntaxLanguage
    ) -> [TokenRange] {
        guard language != .unknown else { return [] }

        if TreeSitterHighlighter.supports(language) {
            return resolveTokenRanges(text, language: language)
        }

        return SyntaxTokenScanner.scanTokenRangesUTF8(text, language: language)
    }

    /// Highlight source code using range-based attribute application.
    ///
    /// Builds a single NSMutableAttributedString from the full text with default
    /// (variable) color, then applies token-specific colors by NSRange. This avoids
    /// creating thousands of intermediate NSAttributedString objects per token.
    static func highlight(_ code: String, language: SyntaxLanguage) -> NSAttributedString {
        let truncated = SyntaxTokenScanner.truncatedCode(code)
        let attrs = TokenAttrs.current()

        // Build the full attributed string with default variable color.
        let result = NSMutableAttributedString(string: truncated, attributes: attrs.variable)

        // Scan for token ranges via unified dispatch (tree-sitter or fallback).
        let tokenRanges = resolveTokenRanges(truncated, language: language)

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
                result.addAttribute(
                    .foregroundColor,
                    value: color,
                    range: NSRange(location: token.location, length: token.length)
                )
            }
        }

        return result
    }

    // MARK: - Unified Dispatch

    /// Single dispatch point for tree-sitter vs shared fallback scanner.
    private static func resolveTokenRanges(
        _ code: String,
        language: SyntaxLanguage
    ) -> [TokenRange] {
        if let tsRanges = TreeSitterHighlighter.scanTokenRanges(code, language: language) {
            return tsRanges
        }
        return SyntaxTokenScanner.scanTokenRanges(code, language: language)
    }
}
