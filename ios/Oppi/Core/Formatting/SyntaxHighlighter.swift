import SwiftUI // Theme color resolution (Color.themeSyntax* → UIColor)
import UIKit

// swiftlint:disable large_tuple

// MARK: - SyntaxLanguage

/// Language identification for syntax highlighting.
///
/// Maps file extensions and markdown fence names to language-specific
/// highlighting rules (keywords, comment patterns).
enum SyntaxLanguage: Sendable, Hashable {
    case swift
    case typescript
    case javascript
    case python
    case go
    case rust
    case ruby
    case shell
    case html
    case css
    case json
    case yaml
    case toml
    case sql
    case c
    case cpp
    case java
    case kotlin
    case zig
    case unknown

    /// Detect language from file extension or code fence name.
    static func detect(_ identifier: String) -> Self {
        switch identifier.lowercased() {
        case "swift": return .swift
        case "ts", "tsx", "mts", "cts", "typescript": return .typescript
        case "js", "jsx", "mjs", "cjs", "javascript": return .javascript
        case "py", "pyi", "python": return .python
        case "go", "golang": return .go
        case "rs", "rust": return .rust
        case "rb", "ruby": return .ruby
        case "sh", "bash", "zsh", "fish", "shell": return .shell
        case "html", "htm": return .html
        case "css", "scss", "less": return .css
        case "json", "jsonl", "geojson": return .json
        case "yaml", "yml": return .yaml
        case "toml": return .toml
        case "sql": return .sql
        case "c", "h": return .c
        case "cpp", "cc", "cxx", "hpp", "hxx", "c++": return .cpp
        case "java": return .java
        case "kt", "kts", "kotlin": return .kotlin
        case "zig": return .zig
        default: return .unknown
        }
    }

    var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .typescript: return "TypeScript"
        case .javascript: return "JavaScript"
        case .python: return "Python"
        case .go: return "Go"
        case .rust: return "Rust"
        case .ruby: return "Ruby"
        case .shell: return "Shell"
        case .html: return "HTML"
        case .css: return "CSS"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .toml: return "TOML"
        case .sql: return "SQL"
        case .c: return "C"
        case .cpp: return "C++"
        case .java: return "Java"
        case .kotlin: return "Kotlin"
        case .zig: return "Zig"
        case .unknown: return "Text"
        }
    }

    var lineCommentPrefix: [Character]? {
        switch self {
        case .swift, .typescript, .javascript, .go, .rust, .c, .cpp, .java, .kotlin, .zig, .css:
            return ["/", "/"]
        case .python, .ruby, .shell, .yaml, .toml:
            return ["#"]
        case .sql:
            return ["-", "-"]
        case .html, .json, .unknown:
            return nil
        }
    }

    var hasBlockComments: Bool {
        switch self {
        case .swift, .typescript, .javascript, .go, .rust, .c, .cpp, .java, .kotlin, .zig, .css:
            return true
        default:
            return false
        }
    }

    var keywords: Set<String> {
        switch self {
        case .swift:
            return swiftKeywords
        case .typescript, .javascript:
            return tsKeywords
        case .python:
            return pythonKeywords
        case .go:
            return goKeywords
        case .rust:
            return rustKeywords
        case .ruby:
            return rubyKeywords
        case .shell:
            return shellKeywords
        case .sql:
            return sqlKeywords
        case .c, .cpp:
            return cKeywords
        case .java:
            return javaKeywords
        case .kotlin:
            return kotlinKeywords
        case .zig:
            return zigKeywords
        case .html, .css, .json, .yaml, .toml, .unknown:
            return []
        }
    }
}

// MARK: - Keyword Sets (private)

private let swiftKeywords: Set<String> = [
    "import", "func", "let", "var", "if", "else", "guard", "return",
    "struct", "class", "enum", "protocol", "extension", "private",
    "public", "internal", "static", "final", "self", "Self", "nil",
    "true", "false", "switch", "case", "default", "for", "while",
    "in", "throws", "async", "await", "some", "any", "typealias",
    "init", "deinit", "override", "mutating", "weak", "try",
    "catch", "throw", "do", "break", "continue", "where",
]

private let tsKeywords: Set<String> = [
    "function", "const", "let", "var", "if", "else", "return",
    "import", "export", "from", "class", "interface", "type",
    "enum", "private", "public", "static", "readonly", "this",
    "null", "undefined", "true", "false", "switch", "case",
    "default", "for", "while", "of", "in", "async", "await",
    "throw", "try", "catch", "finally", "new", "typeof",
    "extends", "implements", "super", "as", "declare",
]

private let pythonKeywords: Set<String> = [
    "def", "class", "if", "elif", "else", "return", "import",
    "from", "as", "self", "None", "True", "False", "for",
    "while", "in", "with", "try", "except", "finally", "raise",
    "pass", "lambda", "yield", "async", "await", "not", "and",
    "or", "is", "del", "global", "assert", "break", "continue",
]

private let goKeywords: Set<String> = [
    "func", "var", "const", "if", "else", "return", "import",
    "package", "struct", "interface", "type", "for", "range",
    "switch", "case", "default", "go", "chan", "defer", "nil",
    "true", "false", "map", "make", "select", "break",
    "continue", "fallthrough",
]

private let rustKeywords: Set<String> = [
    "fn", "let", "mut", "if", "else", "return", "use", "mod",
    "struct", "enum", "impl", "trait", "pub", "self", "Self",
    "match", "for", "while", "in", "loop", "async", "await",
    "true", "false", "where", "type", "const", "static",
    "ref", "move", "unsafe", "crate", "super", "as", "dyn",
]

private let rubyKeywords: Set<String> = [
    "def", "class", "module", "if", "elsif", "else", "unless",
    "return", "require", "include", "end", "do", "begin",
    "rescue", "ensure", "raise", "yield", "self", "nil",
    "true", "false", "and", "or", "not", "while", "until",
    "for", "in", "case", "when",
]

private let shellKeywords: Set<String> = [
    "if", "then", "else", "elif", "fi", "for", "do", "done",
    "while", "until", "case", "esac", "function", "return",
    "exit", "export", "local", "source", "echo", "set",
    "unset", "true", "false",
]

private let shellCommandStarterKeywords: Set<String> = [
    "if", "then", "elif", "else", "do", "while", "until", "case",
]

private let sqlKeywords: Set<String> = [
    "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES",
    "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "ALTER",
    "DROP", "JOIN", "LEFT", "RIGHT", "INNER", "ON", "AND",
    "OR", "NOT", "NULL", "IS", "IN", "ORDER", "BY", "GROUP",
    "HAVING", "LIMIT", "AS", "DISTINCT", "CASE", "WHEN",
    "THEN", "ELSE", "END",
    "select", "from", "where", "insert", "into", "values",
    "update", "set", "delete", "create", "table", "alter",
    "drop", "join", "on", "and", "or", "not", "null", "is",
    "in", "order", "by", "group", "having", "limit", "as",
    "distinct", "case", "when", "then", "else", "end",
]

private let cKeywords: Set<String> = [
    "if", "else", "for", "while", "do", "switch", "case",
    "default", "return", "break", "continue", "struct",
    "enum", "union", "typedef", "const", "static", "extern",
    "void", "int", "char", "float", "double", "long", "short",
    "unsigned", "sizeof", "NULL", "true", "false", "include",
    "define", "ifdef", "ifndef", "endif",
    "class", "public", "private", "protected", "virtual",
    "override", "namespace", "using", "template", "auto",
    "nullptr", "new", "delete", "this", "throw", "try", "catch",
]

private let javaKeywords: Set<String> = [
    "class", "interface", "enum", "abstract", "extends",
    "implements", "public", "private", "protected", "static",
    "final", "void", "int", "long", "double", "float",
    "boolean", "String", "if", "else", "for", "while",
    "switch", "case", "default", "return", "break", "new",
    "this", "super", "null", "true", "false", "try", "catch",
    "finally", "throw", "import", "package", "instanceof",
]

private let kotlinKeywords: Set<String> = [
    "fun", "val", "var", "if", "else", "when", "for", "while",
    "return", "class", "interface", "object", "enum", "data",
    "sealed", "abstract", "open", "override", "private",
    "public", "internal", "import", "package", "this", "super",
    "null", "true", "false", "is", "as", "in", "throw", "try",
    "catch", "finally", "suspend",
]

private let zigKeywords: Set<String> = [
    "const", "var", "fn", "pub", "return", "if", "else", "while",
    "for", "switch", "break", "continue", "struct", "enum", "union",
    "error", "try", "catch", "defer", "errdefer", "comptime",
    "inline", "export", "extern", "test", "unreachable", "undefined",
    "null", "true", "false", "orelse", "and", "or", "async", "await",
    "import", "usingnamespace", "threadlocal", "volatile",
]

// MARK: - SyntaxHighlighter

/// Lightweight deterministic syntax highlighter used across chat, file viewer,
/// and diff surfaces.
///
/// Uses a fast scanner (comments/strings/numbers/keywords) with predictable
/// performance and no external parser dependencies.
///
/// Returns `NSAttributedString` built via `NSMutableAttributedString` internally
/// to avoid the O(n^2) cost of SwiftUI `AttributedString` concatenation.
enum SyntaxHighlighter {

    /// Maximum lines to process (performance bound).
    static let maxLines = 500

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

        static func current() -> Self {
            Self(
                comment: [.foregroundColor: UIColor(Color.themeSyntaxComment)],
                keyword: [.foregroundColor: UIColor(Color.themeSyntaxKeyword)],
                string: [.foregroundColor: UIColor(Color.themeSyntaxString)],
                number: [.foregroundColor: UIColor(Color.themeSyntaxNumber)],
                type: [.foregroundColor: UIColor(Color.themeSyntaxType)],
                variable: [.foregroundColor: UIColor(Color.themeSyntaxVariable)],
                punctuation: [.foregroundColor: UIColor(Color.themeSyntaxPunctuation)],
                function: [.foregroundColor: UIColor(Color.themeSyntaxFunction)],
                operator: [.foregroundColor: UIColor(Color.themeSyntaxOperator)]
            )
        }
    }

    // MARK: - Public API

    /// Highlight a single line independently (no cross-line block comment state).
    /// Suitable for short snippets like diff lines where each line is rendered separately.
    static func highlightLine(_ line: String, language: SyntaxLanguage) -> NSAttributedString {
        let attrs = TokenAttrs.current()
        let result = NSMutableAttributedString()
        var unused = false
        appendHighlightedLine(Array(line), language: language, inBlockComment: &unused, attrs: attrs, to: result)
        return result
    }

    /// Highlight source code and return per-line attributed strings.
    ///
    /// Shares a single `TokenAttrs` allocation and tracks block-comment state
    /// across lines, making it much cheaper than N × `highlightLine()` calls.
    /// Used by `makeCodeAttributedText` to interleave gutter numbers.
    static func highlightLines(_ code: String, language: SyntaxLanguage) -> [NSAttributedString] {
        let truncated = truncatedCode(code)
        let attrs = TokenAttrs.current()
        let rawLines = truncated.split(separator: "\n", omittingEmptySubsequences: false)

        if language == .json {
            // JSON highlighter doesn't track block comments; highlight whole then split.
            let full = highlightJSON(truncated, attrs: attrs)
            return splitAttributedStringByNewlines(full)
        }

        var inBlockComment = false
        var results: [NSAttributedString] = []
        results.reserveCapacity(rawLines.count)

        for line in rawLines {
            let lineResult = NSMutableAttributedString()
            appendHighlightedLine(
                Array(line), language: language, inBlockComment: &inBlockComment, attrs: attrs, to: lineResult
            )
            results.append(lineResult)
        }
        return results
    }

    /// Split a single `NSAttributedString` by newline characters into per-line strings.
    private static func splitAttributedStringByNewlines(_ source: NSAttributedString) -> [NSAttributedString] {
        let string = source.string as NSString
        var results: [NSAttributedString] = []
        var searchStart = 0

        while searchStart <= string.length {
            let remaining = NSRange(location: searchStart, length: string.length - searchStart)
            let newlineRange = string.range(of: "\n", range: remaining)

            if newlineRange.location == NSNotFound {
                // Last line (or only line)
                let lineRange = NSRange(location: searchStart, length: string.length - searchStart)
                results.append(source.attributedSubstring(from: lineRange))
                break
            } else {
                let lineRange = NSRange(location: searchStart, length: newlineRange.location - searchStart)
                results.append(source.attributedSubstring(from: lineRange))
                searchStart = newlineRange.location + newlineRange.length
            }
        }
        return results
    }

    /// Highlight source code.
    static func highlight(_ code: String, language: SyntaxLanguage) -> NSAttributedString {
        let truncated = truncatedCode(code)
        let attrs = TokenAttrs.current()

        if language == .json {
            return highlightJSON(truncated, attrs: attrs)
        }

        let result = NSMutableAttributedString()
        var inBlockComment = false
        let lines = truncated.split(separator: "\n", omittingEmptySubsequences: false)

        for (i, line) in lines.enumerated() {
            if i > 0 { result.mutableString.append("\n") }
            appendHighlightedLine(
                Array(line), language: language, inBlockComment: &inBlockComment, attrs: attrs, to: result
            )
        }
        return result
    }

    private static func truncatedCode(_ code: String) -> String {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= maxLines {
            return code
        }
        return lines.prefix(maxLines).joined(separator: "\n")
    }

    // MARK: - Line Scanner

    private static func appendHighlightedLine(
        _ chars: [Character],
        language: SyntaxLanguage,
        inBlockComment: inout Bool,
        attrs: TokenAttrs,
        to result: NSMutableAttributedString
    ) {
        guard !chars.isEmpty else { return }
        if language == .shell {
            appendHighlightedShellLine(chars, attrs: attrs, to: result)
            return
        }

        var i = 0
        let keywords = language.keywords
        let commentPrefix = language.lineCommentPrefix

        while i < chars.count {
            // Inside block comment — scan for close
            if inBlockComment {
                if i + 1 < chars.count, chars[i] == "*", chars[i + 1] == "/" {
                    result.append(NSAttributedString(string: "*/", attributes: attrs.comment))
                    i += 2
                    inBlockComment = false
                } else {
                    result.append(NSAttributedString(string: String(chars[i]), attributes: attrs.comment))
                    i += 1
                }
                continue
            }

            // Block comment open
            if language.hasBlockComments,
               i + 1 < chars.count, chars[i] == "/", chars[i + 1] == "*" {
                inBlockComment = true
                result.append(NSAttributedString(string: "/*", attributes: attrs.comment))
                i += 2
                continue
            }

            // Line comment
            if let prefix = commentPrefix, matchesAt(chars, offset: i, pattern: prefix) {
                result.append(NSAttributedString(string: String(chars[i...]), attributes: attrs.comment))
                return
            }

            // Preprocessor (#include, #define) for C/C++
            if chars[i] == "#", language == .c || language == .cpp {
                result.append(NSAttributedString(string: String(chars[i...]), attributes: attrs.keyword))
                return
            }

            // Decorator (@Observable, @property, etc.)
            if chars[i] == "@" {
                let start = i
                i += 1
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                    i += 1
                }
                result.append(NSAttributedString(string: String(chars[start..<i]), attributes: attrs.type))
                continue
            }

            // String literal
            let ch = chars[i]
            if ch == "\"" || ch == "'" || ch == "`" {
                let (text, end) = scanString(chars, from: i, quote: ch)
                result.append(NSAttributedString(string: text, attributes: attrs.string))
                i = end
                continue
            }

            // Number
            if ch.isNumber {
                let (text, end) = scanNumber(chars, from: i)
                result.append(NSAttributedString(string: text, attributes: attrs.number))
                i = end
                continue
            }

            // Identifier / keyword
            if ch.isLetter || ch == "_" {
                let (word, end) = scanWord(chars, from: i)
                if keywords.contains(word) {
                    result.append(NSAttributedString(string: word, attributes: attrs.keyword))
                } else if isTypeLike(word) {
                    result.append(NSAttributedString(string: word, attributes: attrs.type))
                } else {
                    result.append(NSAttributedString(string: word, attributes: attrs.variable))
                }
                i = end
                continue
            }

            // Punctuation / operators
            result.append(NSAttributedString(string: String(ch), attributes: attrs.punctuation))
            i += 1
        }
    }

    // MARK: - Shell Scanner

    private static func appendHighlightedShellLine(
        _ chars: [Character],
        attrs: TokenAttrs,
        to result: NSMutableAttributedString
    ) {
        var i = 0
        var expectCommand = true

        while i < chars.count {
            let ch = chars[i]

            if ch.isWhitespace {
                result.append(NSAttributedString(string: String(ch), attributes: attrs.variable))
                i += 1
                continue
            }

            if ch == "#", isShellCommentStart(chars, at: i) {
                result.append(NSAttributedString(string: String(chars[i...]), attributes: attrs.comment))
                return
            }

            if ch == "\"" || ch == "'" || ch == "`" {
                let (text, end) = scanString(chars, from: i, quote: ch)
                result.append(NSAttributedString(string: text, attributes: attrs.string))
                i = end
                expectCommand = false
                continue
            }

            if ch == "$" {
                let (variable, end) = scanShellVariable(chars, from: i)
                result.append(NSAttributedString(string: variable, attributes: attrs.type))
                i = end
                expectCommand = false
                continue
            }

            if let (op, end, resetsCommand) = scanShellOperator(chars, from: i) {
                result.append(NSAttributedString(string: op, attributes: attrs.operator))
                i = end
                if resetsCommand {
                    expectCommand = true
                }
                continue
            }

            if ch == "-", isShellOptionStart(chars, at: i) {
                let (option, end) = scanShellToken(chars, from: i)
                result.append(NSAttributedString(string: option, attributes: attrs.variable))
                i = end
                expectCommand = false
                continue
            }

            let (token, end) = scanShellToken(chars, from: i)
            if token.isEmpty {
                result.append(NSAttributedString(string: String(ch), attributes: attrs.variable))
                i += 1
                continue
            }

            if expectCommand, isShellAssignment(token) {
                result.append(NSAttributedString(string: token, attributes: attrs.type))
                i = end
                continue
            }

            if shellKeywords.contains(token) {
                result.append(NSAttributedString(string: token, attributes: attrs.keyword))
                expectCommand = shellCommandStarterKeywords.contains(token)
                i = end
                continue
            }

            if expectCommand {
                result.append(NSAttributedString(string: token, attributes: attrs.function))
                expectCommand = false
            } else {
                result.append(NSAttributedString(string: token, attributes: attrs.variable))
            }
            i = end
        }
    }

    private static func isShellCommentStart(_ chars: [Character], at index: Int) -> Bool {
        guard chars[index] == "#" else { return false }
        guard index > 0 else { return true }
        let prev = chars[index - 1]
        return prev.isWhitespace || prev == ";" || prev == "|" || prev == "&" || prev == "(" || prev == ")"
    }

    private static func isShellOptionStart(_ chars: [Character], at index: Int) -> Bool {
        guard chars[index] == "-", index + 1 < chars.count else { return false }
        let next = chars[index + 1]
        guard !next.isWhitespace,
              next != "|", next != "&", next != ";", next != "<", next != ">", next != ")" else {
            return false
        }
        guard index > 0 else { return true }
        let prev = chars[index - 1]
        return prev.isWhitespace || prev == "|" || prev == "&" || prev == ";" || prev == "("
    }

    private static func scanShellToken(_ chars: [Character], from start: Int) -> (String, Int) {
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace || isShellDelimiter(c) {
                break
            }
            i += 1
        }
        return (String(chars[start..<i]), i)
    }

    private static func isShellDelimiter(_ c: Character) -> Bool {
        c == "|" || c == "&" || c == ";" || c == "<" || c == ">" || c == "(" || c == ")"
    }

    private static func scanShellOperator(
        _ chars: [Character],
        from start: Int
    ) -> (String, Int, Bool)? {
        guard start < chars.count else { return nil }
        let ch = chars[start]

        // File descriptor redirection, e.g. 2>&1, 1>out.log
        if ch.isNumber {
            var i = start
            while i < chars.count, chars[i].isNumber { i += 1 }
            if i < chars.count, chars[i] == ">" || chars[i] == "<" {
                let end = scanShellRedirection(chars, from: i)
                return (String(chars[start..<end]), end, false)
            }
        }

        switch ch {
        case "|":
            if start + 1 < chars.count, chars[start + 1] == "|" {
                return ("||", start + 2, true)
            }
            if start + 1 < chars.count, chars[start + 1] == "&" {
                return ("|&", start + 2, true)
            }
            return ("|", start + 1, true)

        case "&":
            if start + 1 < chars.count, chars[start + 1] == "&" {
                return ("&&", start + 2, true)
            }
            if start + 1 < chars.count, chars[start + 1] == ">" {
                let end = scanShellRedirection(chars, from: start + 1)
                return (String(chars[start..<end]), end, false)
            }
            return ("&", start + 1, true)

        case ";":
            if start + 1 < chars.count, chars[start + 1] == ";" {
                return (";;", start + 2, true)
            }
            return (";", start + 1, true)

        case "(", ")":
            return (String(ch), start + 1, true)

        case "<", ">":
            let end = scanShellRedirection(chars, from: start)
            return (String(chars[start..<end]), end, false)

        default:
            return nil
        }
    }

    private static func scanShellRedirection(_ chars: [Character], from start: Int) -> Int {
        var i = start
        guard i < chars.count else { return i }

        let op = chars[i]
        i += 1

        if i < chars.count, chars[i] == op {
            // >> or <<
            i += 1
        } else if op == ">", i < chars.count, chars[i] == "|" {
            // >|
            i += 1
        }

        if i < chars.count, chars[i] == "&" {
            i += 1
            if i < chars.count, chars[i] == "-" {
                i += 1
            } else {
                while i < chars.count, chars[i].isNumber { i += 1 }
            }
        }

        return i
    }

    private static func scanShellVariable(_ chars: [Character], from start: Int) -> (String, Int) {
        guard start < chars.count, chars[start] == "$" else { return ("", start) }

        var i = start + 1
        guard i < chars.count else { return ("$", i) }
        let next = chars[i]

        if next == "{" {
            i += 1
            var depth = 1
            while i < chars.count, depth > 0 {
                let c = chars[i]
                if c == "{" {
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                } else if c == "\"" || c == "'" || c == "`" {
                    let (_, end) = scanString(chars, from: i, quote: c)
                    i = end
                    continue
                } else if c == "\\" {
                    i = min(i + 2, chars.count)
                    continue
                }
                i += 1
            }
            return (String(chars[start..<i]), i)
        }

        if next == "(" {
            i += 1
            var depth = 1
            while i < chars.count, depth > 0 {
                let c = chars[i]
                if c == "(" {
                    depth += 1
                } else if c == ")" {
                    depth -= 1
                    i += 1
                    continue
                } else if c == "\"" || c == "'" || c == "`" {
                    let (_, end) = scanString(chars, from: i, quote: c)
                    i = end
                    continue
                } else if c == "\\" {
                    i = min(i + 2, chars.count)
                    continue
                }
                i += 1
            }
            return (String(chars[start..<i]), i)
        }

        if next == "*" || next == "@" || next == "#" || next == "?" ||
            next == "-" || next == "$" || next == "!" || next == "_" {
            return (String(chars[start...i]), i + 1)
        }

        if next.isNumber {
            i += 1
            while i < chars.count, chars[i].isNumber { i += 1 }
            return (String(chars[start..<i]), i)
        }

        if next.isLetter || next == "_" {
            i += 1
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                i += 1
            }
            return (String(chars[start..<i]), i)
        }

        return ("$", start + 1)
    }

    private static func isShellAssignment(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return false }
        let name = token[token.startIndex..<eq]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: - Token Scanners

    private static func scanString(_ chars: [Character], from start: Int, quote: Character) -> (String, Int) {
        var i = start + 1
        var escaped = false

        while i < chars.count {
            if escaped {
                escaped = false
            } else if chars[i] == "\\" {
                escaped = true
            } else if chars[i] == quote {
                return (String(chars[start...i]), i + 1)
            }
            i += 1
        }
        return (String(chars[start...]), chars.count)
    }

    private static func scanNumber(_ chars: [Character], from start: Int) -> (String, Int) {
        var i = start

        // Hex prefix
        if chars[i] == "0", i + 1 < chars.count, chars[i + 1] == "x" || chars[i + 1] == "X" {
            i += 2
            while i < chars.count, chars[i].isHexDigit || chars[i] == "_" { i += 1 }
            return (String(chars[start..<i]), i)
        }

        // Decimal
        var hasDot = false
        while i < chars.count {
            let c = chars[i]
            if c.isNumber || c == "_" {
                i += 1
            } else if c == ".", !hasDot, i + 1 < chars.count, chars[i + 1].isNumber {
                hasDot = true
                i += 1
            } else if c == "e" || c == "E" {
                i += 1
                if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
            } else {
                break
            }
        }
        return (String(chars[start..<i]), i)
    }

    private static func scanWord(_ chars: [Character], from start: Int) -> (String, Int) {
        var i = start
        while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
            i += 1
        }
        return (String(chars[start..<i]), i)
    }

    /// Heuristic: CamelCase starting with uppercase is likely a type.
    private static func isTypeLike(_ word: String) -> Bool {
        guard let first = word.first, first.isUppercase else { return false }
        return word.contains(where: { $0.isLowercase })
    }

    private static func matchesAt(_ chars: [Character], offset: Int, pattern: [Character]) -> Bool {
        guard offset + pattern.count <= chars.count else { return false }
        for j in 0..<pattern.count where chars[offset + j] != pattern[j] {
            return false
        }
        return true
    }

    // MARK: - JSON Highlighting

    private static func highlightJSON(_ code: String, attrs: TokenAttrs) -> NSAttributedString {
        let chars = Array(code)
        let result = NSMutableAttributedString()
        var i = 0

        while i < chars.count {
            let ch = chars[i]

            if ch == "\"" {
                let (text, end) = scanString(chars, from: i, quote: "\"")
                // Key detection: string followed by optional whitespace then `:`
                var j = end
                while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                let isKey = j < chars.count && chars[j] == ":"
                result.append(NSAttributedString(string: text, attributes: isKey ? attrs.type : attrs.string))
                i = end
            } else if ch.isNumber || (ch == "-" && i + 1 < chars.count && chars[i + 1].isNumber) {
                let (text, end) = scanJSONNumber(chars, from: i)
                result.append(NSAttributedString(string: text, attributes: attrs.number))
                i = end
            } else if matchesWord(chars, at: i, word: "true") {
                result.append(NSAttributedString(string: "true", attributes: attrs.keyword))
                i += 4
            } else if matchesWord(chars, at: i, word: "false") {
                result.append(NSAttributedString(string: "false", attributes: attrs.keyword))
                i += 5
            } else if matchesWord(chars, at: i, word: "null") {
                result.append(NSAttributedString(string: "null", attributes: attrs.comment))
                i += 4
            } else {
                result.append(NSAttributedString(string: String(ch), attributes: attrs.punctuation))
                i += 1
            }
        }
        return result
    }

    private static func scanJSONNumber(_ chars: [Character], from start: Int) -> (String, Int) {
        var i = start
        if chars[i] == "-" { i += 1 }
        while i < chars.count {
            let c = chars[i]
            if c.isNumber || c == "." { i += 1 } else if c == "e" || c == "E" {
                i += 1
                if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
            } else { break }
        }
        return (String(chars[start..<i]), i)
    }

    private static func matchesWord(_ chars: [Character], at i: Int, word: String) -> Bool {
        let w = Array(word)
        guard i + w.count <= chars.count else { return false }
        for j in 0..<w.count where chars[i + j] != w[j] { return false }
        let end = i + w.count
        if end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" {
            return false
        }
        return true
    }

}
