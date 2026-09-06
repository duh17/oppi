import Foundation
import OSLog
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterTSX
import TreeSitterTypeScript

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

        private struct QueryResource {
            let bundleName: String
            let fileName: String
        }

        /// Map from SyntaxLanguage to cached grammar entry.
        private var entries: [SyntaxLanguage: Entry] = [:]

        private init() {
            registerAll()
        }

        /// Register all available grammars.
        /// Add new grammars here as SPM dependencies are added.
        /// JS/Python stay on 0.23.x: 0.25 Package.swift skips scanner.c under Xcode SPM.
        private func registerAll() {
            let bash = Self.bundleName("TreeSitterBash")
            let c = Self.bundleName("TreeSitterC")
            let cpp = Self.bundleName("TreeSitterCPP")
            let css = Self.bundleName("TreeSitterCSS")
            let go = Self.bundleName("TreeSitterGo")
            let html = Self.bundleName("TreeSitterHTML")
            let java = Self.bundleName("TreeSitterJava")
            let javascript = Self.bundleName("TreeSitterJavaScript")
            let python = Self.bundleName("TreeSitterPython")
            let ruby = Self.bundleName("TreeSitterRuby")
            let rust = Self.bundleName("TreeSitterRust")
            let typescript = Self.bundleName("TreeSitterTypeScript")

            register(
                .shell,
                tsLanguage: tree_sitter_bash(),
                queryResources: [QueryResource(bundleName: bash, fileName: "highlights.scm")],
                supplement: """
                
                ;; Oppi supplements — operators missing from upstream bash highlights.scm
                ["||" "|&" "<<<" ">|" "&>" "&>>" ";;" ";&" ";;&"] @operator
                """
            )
            register(
                .javascript,
                tsLanguage: tree_sitter_javascript(),
                queryResources: [QueryResource(bundleName: javascript, fileName: "highlights.scm")]
            )
            register(
                .jsx,
                tsLanguage: tree_sitter_javascript(),
                queryResources: [
                    QueryResource(bundleName: javascript, fileName: "highlights.scm"),
                    QueryResource(bundleName: javascript, fileName: "highlights-jsx.scm"),
                ]
            )
            register(
                .python,
                tsLanguage: tree_sitter_python(),
                queryResources: [QueryResource(bundleName: python, fileName: "highlights.scm")]
            )
            register(
                .typescript,
                tsLanguage: tree_sitter_typescript(),
                queryResources: [
                    QueryResource(bundleName: javascript, fileName: "highlights.scm"),
                    QueryResource(bundleName: typescript, fileName: "highlights.scm"),
                ]
            )
            register(
                .tsx,
                tsLanguage: tree_sitter_tsx(),
                queryResources: [
                    QueryResource(bundleName: javascript, fileName: "highlights.scm"),
                    QueryResource(bundleName: javascript, fileName: "highlights-jsx.scm"),
                    QueryResource(bundleName: typescript, fileName: "highlights.scm"),
                ]
            )
            register(
                .go,
                tsLanguage: tree_sitter_go(),
                queryResources: [QueryResource(bundleName: go, fileName: "highlights.scm")]
            )
            register(
                .rust,
                tsLanguage: tree_sitter_rust(),
                queryResources: [QueryResource(bundleName: rust, fileName: "highlights.scm")]
            )
            register(
                .c,
                tsLanguage: tree_sitter_c(),
                queryResources: [QueryResource(bundleName: c, fileName: "highlights.scm")]
            )
            // SwiftTreeSitter Query() does not honor `; inherits:`. C++ highlights
            // are C++-only, so concatenate the C query the same way TS concatenates JS.
            register(
                .cpp,
                tsLanguage: tree_sitter_cpp(),
                queryResources: [
                    QueryResource(bundleName: c, fileName: "highlights.scm"),
                    QueryResource(bundleName: cpp, fileName: "highlights.scm"),
                ]
            )
            register(
                .html,
                tsLanguage: tree_sitter_html(),
                queryResources: [QueryResource(bundleName: html, fileName: "highlights.scm")]
            )
            register(
                .css,
                tsLanguage: tree_sitter_css(),
                queryResources: [QueryResource(bundleName: css, fileName: "highlights.scm")]
            )
            register(
                .ruby,
                tsLanguage: tree_sitter_ruby(),
                queryResources: [QueryResource(bundleName: ruby, fileName: "highlights.scm")]
            )
            register(
                .java,
                tsLanguage: tree_sitter_java(),
                queryResources: [QueryResource(bundleName: java, fileName: "highlights.scm")]
            )
            // Swift: no official tree-sitter-swift SPM package. Keep the scanner.
            // JSON, XML, and diff stay on dedicated scanners. Do not register JSON.
            // HTML tree-sitter is SyntaxLanguage.html only; XML stays on scanXMLRanges.
        }

        private static func bundleName(_ module: String) -> String {
            "\(module)_\(module)"
        }

        /// Register a grammar by loading its highlights queries from SPM bundles.
        ///
        /// The language is always registered so a missing query resource paints
        /// plain text instead of silently falling back to the line scanner.
        private func register(
            _ syntaxLanguage: SyntaxLanguage,
            tsLanguage: OpaquePointer,
            queryResources: [QueryResource],
            supplement: String? = nil
        ) {
            let language = Language(language: tsLanguage)
            let highlightsQuery = Self.loadHighlightsQuery(
                language: language,
                queryResources: queryResources,
                supplement: supplement,
                syntaxLanguage: syntaxLanguage
            )

            entries[syntaxLanguage] = Entry(
                language: language,
                highlightsQuery: highlightsQuery
            )
        }

        /// Load and concatenate query files from grammar SPM resource bundles.
        ///
        /// SPM embeds resource bundles at the top level of the app bundle.
        /// The naming convention is `TreeSitter<Name>_TreeSitter<Name>.bundle/queries/<file>`.
        /// Any missing file or compile failure returns nil so the language paints as plain text.
        private static func loadHighlightsQuery(
            language: Language,
            queryResources: [QueryResource],
            supplement: String?,
            syntaxLanguage: SyntaxLanguage
        ) -> Query? {
            var queryData = Data()
            for resource in queryResources {
                guard let bundleURL = Bundle.main.url(
                    forResource: resource.bundleName,
                    withExtension: "bundle"
                ) else {
                    logger.warning(
                        "tree-sitter bundle \(resource.bundleName, privacy: .public) missing; \(syntaxLanguage.displayName, privacy: .public) paints as plain text"
                    )
                    return nil
                }

                guard let fileURL = queryFileURL(bundleURL: bundleURL, fileName: resource.fileName) else {
                    logger.warning(
                        "tree-sitter query \(resource.bundleName, privacy: .public)/queries/\(resource.fileName, privacy: .public) missing; \(syntaxLanguage.displayName, privacy: .public) paints as plain text"
                    )
                    return nil
                }

                do {
                    queryData.append(try Data(contentsOf: fileURL))
                    queryData.append(contentsOf: [0x0A])
                } catch {
                    logger.warning(
                        "tree-sitter query \(resource.fileName, privacy: .public) unreadable: \(error.localizedDescription, privacy: .public); \(syntaxLanguage.displayName, privacy: .public) paints as plain text"
                    )
                    return nil
                }
            }

            if let supplement, let supplementData = supplement.data(using: .utf8) {
                queryData.append(supplementData)
            }

            do {
                return try Query(language: language, data: queryData)
            } catch {
                if case QueryError.nodeType(let offset) = error {
                    logger.warning(
                        "Query nodeType error at offset \(offset, privacy: .public) for \(syntaxLanguage.displayName, privacy: .public)"
                    )
                } else {
                    logger.warning(
                        "Query compilation failed for \(syntaxLanguage.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
                return nil
            }
        }

        /// Locate a query file inside an SPM grammar resource bundle.
        ///
        /// iOS SPM bundles are flat (`bundle/queries/<file>`).
        /// macOS copies the same resources as a real bundle
        /// (`bundle/Contents/Resources/queries/<file>`).
        static func queryFileURL(bundleURL: URL, fileName: String) -> URL? {
            let candidates = [
                bundleURL.appendingPathComponent("queries/\(fileName)"),
                bundleURL.appendingPathComponent("Contents/Resources/queries/\(fileName)"),
            ]
            if let url = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) {
                return url
            }
            let resource = URL(fileURLWithPath: fileName)
            let ext = resource.pathExtension
            let name = resource.deletingPathExtension().lastPathComponent
            return Bundle(url: bundleURL)?.url(
                forResource: name,
                withExtension: ext.isEmpty ? nil : ext,
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
    /// Uses tree-sitter when a grammar is registered. A registered language
    /// with a missing query paints as plain text rather than the line scanner.
    /// Unregistered languages use `SyntaxTokenScanner`. Token locations are
    /// UTF-16 code unit offsets (matching `NSRange`). Token work is bounded by
    /// `SyntaxTokenScanner.maxLines`.
    static func resolvedTokenRanges(
        _ code: String,
        language: SyntaxLanguage
    ) -> [SyntaxTokenRange] {
        if supports(language) {
            return scanTokenRanges(code, language: language) ?? []
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
    /// Parsing is bounded by `SyntaxTokenScanner.maxLines`.
    static func scanTokenRanges(
        _ code: String,
        language: SyntaxLanguage
    ) -> [SyntaxTokenRange]? {
        let source = SyntaxTokenScanner.truncatedCode(code)
        let registry = GrammarRegistry.shared

        guard let tsLanguage = registry.language(for: language) else {
            return nil
        }
        guard let query = registry.highlightsQuery(for: language) else {
            return nil
        }

        let parser = Parser()
        do {
            try parser.setLanguage(tsLanguage)
        } catch {
            return nil
        }

        guard let mutableTree = parser.parse(source) else {
            return nil
        }

        return scanWithQuery(query: query, tree: mutableTree, source: source)
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
