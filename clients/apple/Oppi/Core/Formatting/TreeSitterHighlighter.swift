import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitter

// MARK: - TreeSitterHighlighter

/// Query-based syntax highlighter backed by tree-sitter grammars.
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
    private static let captureKindMap: [String: SyntaxHighlighter.TokenKind] = [
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
    private static func tokenKind(for captureName: String) -> SyntaxHighlighter.TokenKind? {
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
            register(.shell, tsLanguage: tree_sitter_bash(), name: "Bash")
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
            name: String
        ) {
            let language = Language(language: tsLanguage)
            let highlightsQuery = Self.loadHighlightsQuery(
                language: language,
                bundleName: "TreeSitter\(name)_TreeSitter\(name)"
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
            bundleName: String
        ) -> Query? {
            // Find the resource bundle embedded in the app.
            guard let bundleURL = Bundle.main.url(
                forResource: bundleName,
                withExtension: "bundle"
            ) else {
                return nil
            }

            // Locate highlights.scm inside the bundle.
            // iOS: bundle/queries/highlights.scm
            let queriesURL = bundleURL.appendingPathComponent("queries", isDirectory: true)
            let highlightsURL = queriesURL.appendingPathComponent("highlights.scm")

            guard FileManager.default.isReadableFile(atPath: highlightsURL.path) else {
                return nil
            }

            do {
                // Load upstream highlights.scm
                var queryData = try Data(contentsOf: highlightsURL)

                // Append supplementary patterns for operators that the upstream
                // highlights.scm doesn't cover. This keeps us conformant with
                // upstream while filling gaps for common shell operators.
                let supplement = """
                
                ;; Oppi supplements — operators missing from upstream highlights.scm
                ["||" "|&" "<<<" ">|" "&>" "&>>" ";;" ";&" ";;&"] @operator
                """
                if let supplementData = supplement.data(using: .utf8) {
                    queryData.append(supplementData)
                }

                return try Query(language: language, data: queryData)
            } catch {
                return nil
            }
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

    /// Scan source code using tree-sitter and return token ranges.
    ///
    /// Returns nil if the language isn't registered, signaling the
    /// caller to fall back to the hand-written scanner.
    ///
    /// Token locations are UTF-16 code unit offsets (matching NSRange).
    static func scanTokenRanges(
        _ code: String,
        language: SyntaxLanguage
    ) -> [SyntaxHighlighter.TokenRange]? {
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
            return scanWithQuery(query: query, tree: mutableTree)
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
        tree: MutableTree
    ) -> [SyntaxHighlighter.TokenRange] {
        let cursor = query.execute(in: tree)
        var ranges: [SyntaxHighlighter.TokenRange] = []
        ranges.reserveCapacity(256)

        for match in cursor {
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

        // Sort: position ascending, then length descending (broad first).
        // This ensures last-write-wins gives priority to specific captures.
        ranges.sort { a, b in
            if a.location != b.location {
                return a.location < b.location
            }
            return a.length > b.length
        }

        return ranges
    }
}
