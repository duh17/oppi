import Foundation
import OSLog
import SwiftTreeSitter
import TreeSitterBash

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "TreeSitter")

// MARK: - TreeSitterHighlighter

/// Query-based syntax token provider backed by tree-sitter grammars.
///
/// Uses each grammar's bundled `highlights.scm` query file — the same
/// definitions used by Neovim, Zed, and every other tree-sitter consumer.
/// This means our highlighting automatically conforms to upstream grammar
/// updates without maintaining manual node-type mapping tables.
///
/// Adding a new language:
/// 1. Add the SPM dependency in `project.yml`
/// 2. Import the grammar module
/// 3. Add a `register()` call in `GrammarRegistry.shared`
/// 4. Add conformance tests in `TreeSitter<Lang>HighlightTests.swift`
///
/// Thread safety: `Parser` is not Sendable, so each `scanTokenRanges`
/// call creates a fresh instance. Tree-sitter parsing is fast (~0.5ms
/// for typical inputs) so this is cheaper than synchronization.
enum TreeSitterHighlighter {

    // MARK: - Capture Name → TokenKind Mapping

    /// Map tree-sitter capture names (from highlights.scm) to our token kinds.
    ///
    /// This table is shared across ALL languages. Capture names are
    /// standardized by the tree-sitter community:
    ///   https://tree-sitter.github.io/tree-sitter/3-syntax-highlighting#theme
    ///
    /// Unmapped captures (e.g. @embedded, @punctuation.bracket) get no color,
    /// falling through to the default variable/foreground color.
    private static let captureKindMap: [String: SyntaxTokenKind] = [
        // Comments
        "comment": .comment,

        // Strings and string-like
        "string": .string,
        "string.special": .string,
        "character": .string,

        // Keywords
        "keyword": .keyword,
        "keyword.function": .keyword,
        "keyword.return": .keyword,
        "keyword.operator": .operator,
        "keyword.conditional": .keyword,
        "keyword.repeat": .keyword,
        "keyword.import": .keyword,
        "keyword.exception": .keyword,
        "keyword.storage": .keyword,
        "keyword.directive": .keyword,

        // Functions
        "function": .function,
        "function.call": .function,
        "function.builtin": .function,
        "function.method": .function,
        "function.method.call": .function,
        "function.macro": .function,
        "constructor": .function,

        // Variables and properties
        "variable": .variable,
        "variable.builtin": .type,
        "variable.parameter": .variable,
        "property": .type,
        "field": .type,
        "label": .type,

        // Types
        "type": .type,
        "type.builtin": .type,
        "type.definition": .type,
        "type.qualifier": .keyword,
        "attribute": .type,
        "namespace": .type,
        "module": .type,

        // Literals
        "number": .number,
        "number.float": .number,
        "float": .number,
        "boolean": .keyword,
        "constant": .number,
        "constant.builtin": .number,

        // Operators
        "operator": .operator,

        // Punctuation (mapped but often left as default)
        "punctuation": .punctuation,
        "punctuation.bracket": .punctuation,
        "punctuation.delimiter": .punctuation,
        "punctuation.special": .operator,

        // Tags (HTML/XML)
        "tag": .keyword,
        "tag.attribute": .type,
        "tag.delimiter": .punctuation,
    ]

    /// Resolve a capture name (potentially dotted like "keyword.function")
    /// to a TokenKind. Tries exact match first, then strips the last
    /// component for fallback (e.g. "keyword.function" → "keyword").
    private static func tokenKind(for captureName: String) -> SyntaxTokenKind? {
        if let kind = captureKindMap[captureName] {
            return kind
        }

        // Fallback: strip last component. "function.method.call" → "function.method" → "function"
        if let dotIndex = captureName.lastIndex(of: ".") {
            let parent = String(captureName[..<dotIndex])
            return captureKindMap[parent]
        }

        return nil
    }

    // MARK: - Grammar Registry

    /// Cached grammar configurations. Each entry holds the compiled
    /// Language and highlights Query, created once and reused.
    final class GrammarRegistry: @unchecked Sendable {
        static let shared = GrammarRegistry()

        private struct Entry {
            let language: Language
            let highlightsQuery: Query?
        }

        /// Map from SyntaxLanguage to cached grammar entry.
        private var entries: [SyntaxLanguage: Entry] = [:]

        private init() {
            registerAll()
        }

        /// Register all available grammars.
        /// Add new grammars here as SPM dependencies are added.
        private func registerAll() {
            register(
                .shell,
                tsLanguage: tree_sitter_bash(),
                name: "Bash",
                supplement: """
                
                ;; Oppi supplements — operators missing from upstream bash highlights.scm
                ["||" "|&" "<<<" ">|" "&>" "&>>" ";;" ";&" ";;&"] @operator
                """
            )
            // Swift grammar: no official tree-sitter package exists.
            // The hand-written scanner handles Swift well enough for
            // the short snippets agents produce. Revisit when official
            // grammars are available for TS, Python, Go, etc.
            // TODO: Register more grammars as SPM deps are added:
            // register(.typescript, tsLanguage: tree_sitter_typescript(), name: "TypeScript")
            // register(.javascript, tsLanguage: tree_sitter_javascript(), name: "JavaScript")
            // register(.python, tsLanguage: tree_sitter_python(), name: "Python")
            // register(.go, tsLanguage: tree_sitter_go(), name: "Go")
            // register(.rust, tsLanguage: tree_sitter_rust(), name: "Rust")
            // register(.ruby, tsLanguage: tree_sitter_ruby(), name: "Ruby")
            // register(.html, tsLanguage: tree_sitter_html(), name: "HTML")
            // register(.css, tsLanguage: tree_sitter_css(), name: "CSS")
            // register(.json, tsLanguage: tree_sitter_json(), name: "JSON")
            // register(.c, tsLanguage: tree_sitter_c(), name: "C")
            // register(.cpp, tsLanguage: tree_sitter_cpp(), name: "Cpp")
            // register(.java, tsLanguage: tree_sitter_java(), name: "Java")
        }

        /// Register a grammar by loading its highlights.scm from the SPM bundle.
        private func register(
            _ syntaxLanguage: SyntaxLanguage,
            tsLanguage: OpaquePointer,
            name: String,
            supplement: String? = nil
        ) {
            let language = Language(language: tsLanguage)
            let highlightsQuery = Self.loadHighlightsQuery(
                language: language,
                bundleName: "TreeSitter\(name)_TreeSitter\(name)",
                supplement: supplement
            )

            entries[syntaxLanguage] = Entry(
                language: language,
                highlightsQuery: highlightsQuery
            )
        }

        /// Load highlights.scm from the grammar's SPM resource bundle.
        ///
        /// SPM embeds resource bundles at the top level of the app bundle.
        /// The naming convention is `TreeSitter<Name>_TreeSitter<Name>.bundle/queries/highlights.scm`.
        private static func loadHighlightsQuery(
            language: Language,
            bundleName: String,
            supplement: String? = nil
        ) -> Query? {
            // Find the resource bundle embedded in the app.
            guard let bundleURL = Bundle.main.url(
                forResource: bundleName,
                withExtension: "bundle"
            ) else {
                return nil
            }

            // Locate highlights.scm inside the grammar resource bundle.
            // iOS SPM bundles are flat (`bundle/queries/highlights.scm`).
            // macOS copies the same resources as a real bundle
            // (`bundle/Contents/Resources/queries/highlights.scm`).
            guard let highlightsURL = Self.highlightsQueryFileURL(bundleURL: bundleURL) else {
                logger.warning("highlights.scm missing in \(bundleName, privacy: .public)")
                return nil
            }

            do {
                // Load upstream highlights.scm
                var queryData = try Data(contentsOf: highlightsURL)

                // Append per-language supplementary patterns if provided.
                if let supplement, let supplementData = supplement.data(using: .utf8) {
                    queryData.append(supplementData)
                }

                return try Query(language: language, data: queryData)
            } catch {
                // Log query compilation errors to help debug grammar issues.
                // Common cause: highlights.scm uses syntax not supported by
                // the installed tree-sitter version.
                if case QueryError.nodeType(let offset) = error {
                    logger.warning("Query nodeType error at offset \(offset, privacy: .public) in \(bundleName, privacy: .public)")
                } else {
                    logger.warning("Query compilation failed for \(bundleName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                return nil
            }
        }

        private static func highlightsQueryFileURL(bundleURL: URL) -> URL? {
            let candidates = [
                bundleURL.appendingPathComponent("queries/highlights.scm"),
                bundleURL.appendingPathComponent("Contents/Resources/queries/highlights.scm"),
            ]
            if let url = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) {
                return url
            }
            return Bundle(url: bundleURL)?.url(
                forResource: "highlights",
                withExtension: "scm",
                subdirectory: "queries"
            )
        }

        /// Get the language for parsing.
        func language(for syntaxLanguage: SyntaxLanguage) -> Language? {
            entries[syntaxLanguage]?.language
        }

        /// Get the compiled highlights query.
        func highlightsQuery(for syntaxLanguage: SyntaxLanguage) -> Query? {
            entries[syntaxLanguage]?.highlightsQuery
        }

        /// Check if a language is registered.
        func supports(_ syntaxLanguage: SyntaxLanguage) -> Bool {
            entries[syntaxLanguage] != nil
        }
    }

    // MARK: - Public API

    /// Check if a language has tree-sitter support.
    static func supports(_ language: SyntaxLanguage) -> Bool {
        GrammarRegistry.shared.supports(language)
    }

    /// Shared token provider for iOS and Mac painters.
    ///
    /// Uses tree-sitter when a grammar is registered; otherwise falls back
    /// to the hand-written `SyntaxTokenScanner`. Token locations are UTF-16
    /// code unit offsets (matching `NSRange`).
    static func resolvedTokenRanges(
        _ code: String,
        language: SyntaxLanguage
    ) -> [SyntaxTokenRange] {
        if let ranges = scanTokenRanges(code, language: language) {
            return ranges
        }
        return SyntaxTokenScanner.scanTokenRanges(code, language: language)
    }

    /// ASCII-optimized provider used by diff painters.
    ///
    /// Tree-sitter languages take the query path; everything else uses the
    /// shared UTF-8 scanner.
    static func resolvedTokenRangesUTF8(
        _ text: String,
        language: SyntaxLanguage
    ) -> [SyntaxTokenRange] {
        guard language != .unknown else { return [] }

        if supports(language) {
            return resolvedTokenRanges(text, language: language)
        }

        return SyntaxTokenScanner.scanTokenRangesUTF8(text, language: language)
    }

    /// Scan source code using tree-sitter and return token ranges.
    ///
    /// Returns nil if the language isn't registered, signaling the
    /// caller to fall back to the hand-written scanner.
    ///
    /// Token locations are UTF-16 code unit offsets (matching NSRange).
    static func scanTokenRanges(
        _ code: String,
        language: SyntaxLanguage
    ) -> [SyntaxTokenRange]? {
        let registry = GrammarRegistry.shared

        guard let tsLanguage = registry.language(for: language) else {
            return nil
        }

        // Parse the source code.
        let parser = Parser()
        do {
            try parser.setLanguage(tsLanguage)
        } catch {
            return nil
        }

        guard let mutableTree = parser.parse(code) else {
            return nil
        }

        // If we have a highlights query, use it (preferred path).
        if let query = registry.highlightsQuery(for: language) {
            return scanWithQuery(query: query, tree: mutableTree, source: code)
        }

        // Fallback: no highlights query. Walk AST manually.
        // This shouldn't happen for properly packaged grammars.
        return nil
    }

    // MARK: - Query-Based Scanning

    /// Execute the highlights query and convert captures to token ranges.
    ///
    /// The Query API evaluates the highlights.scm patterns against the AST
    /// and returns captures with names like "function", "string", "keyword".
    /// We map these to our TokenKind via the shared `captureKindMap`.
    ///
    /// Captures are already sorted by position and specificity by tree-sitter.
    /// More specific captures (deeper patterns) come after broader ones,
    /// which is exactly what we want for last-write-wins in NSAttributedString.
    private static func scanWithQuery(
        query: Query,
        tree: MutableTree,
        source: String
    ) -> [SyntaxTokenRange] {
        let cursor = query.execute(in: tree)
        var ranges: [SyntaxTokenRange] = []
        ranges.reserveCapacity(256)

        // Use predicate-aware iteration. Some highlights.scm patterns
        // use predicates like (#match? @name "^[A-Z]") which need the
        // source text to evaluate.
        let nsSource = source as NSString
        let context = Predicate.Context(textProvider: { range, _ in
            guard range.location >= 0, range.location + range.length <= nsSource.length else {
                return nil
            }
            return nsSource.substring(with: range)
        })

        let resolving = cursor.resolve(with: context)
        for match in resolving {
            for capture in match.captures {
                guard let name = capture.name else { continue }
                guard let kind = tokenKind(for: name) else { continue }

                let nsRange = capture.range
                guard nsRange.length > 0 else { continue }

                ranges.append(.init(
                    location: nsRange.location,
                    length: nsRange.length,
                    kind: kind
                ))
            }
        }

        // Deduplicate: when multiple captures cover the same range,
        // keep only the most specific one (highest pattern index).
        // tree-sitter returns captures sorted by position, and within
        // the same position, the broadest pattern (e.g. @variable)
        // comes AFTER more specific patterns (e.g. @function.method).
        // We want the specific one to win.
        //
        // Strategy: group by (location, length), keep the one with
        // the highest patternIndex (most specific in highlights.scm).
        // Since captures are already in document order, we just
        // track the last-seen range and replace if same position.
        if ranges.count <= 1 { return ranges }

        var deduped: [SyntaxTokenRange] = []
        deduped.reserveCapacity(ranges.count)

        for range in ranges {
            if let last = deduped.last,
               last.location == range.location,
               last.length == range.length {
                // Same range — later capture is broader (@variable).
                // Keep the earlier, more specific one.
                continue
            }
            deduped.append(range)
        }

        return deduped
    }
}
