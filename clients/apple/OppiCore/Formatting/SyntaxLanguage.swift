import Foundation

/// Language identification for syntax highlighting and file/content rendering.
///
/// Maps file extensions and markdown fence names to language-specific
/// highlighting rules. Kept in OppiCore so iOS and Mac choose the same
/// renderer for code, Markdown fences, diffs, and document formats.
enum SyntaxLanguage: Sendable, Hashable {
    case swift
    case typescript
    case tsx
    case javascript
    case jsx
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
    case xml
    case protobuf
    case graphql
    case diff
    case latex
    case orgMode
    case mermaid
    case dot
    case unknown

    /// Detect language from file extension or code fence name.
    static func detect(_ identifier: String) -> Self {
        switch identifier.lowercased() {
        case "swift": return .swift
        case "ts", "mts", "cts", "typescript": return .typescript
        case "tsx": return .tsx
        case "js", "mjs", "cjs", "javascript": return .javascript
        case "jsx": return .jsx
        case "py", "pyi", "pyw", "python": return .python
        case "go", "golang": return .go
        case "rs", "rust": return .rust
        case "rb", "erb", "ruby": return .ruby
        case "sh", "bash", "zsh", "fish", "ksh", "csh", "shell": return .shell
        case "html", "htm": return .html
        case "css", "scss", "less", "sass": return .css
        case "json", "jsonl", "geojson", "jsonc": return .json
        case "yaml", "yml": return .yaml
        case "toml": return .toml
        case "sql": return .sql
        case "c", "h": return .c
        case "cpp", "cc", "cxx", "hpp", "hxx", "hh", "c++": return .cpp
        case "java": return .java
        case "kt", "kts", "kotlin": return .kotlin
        case "zig": return .zig
        case "xml", "xsl", "xslt", "xsd", "plist", "xcscheme", "xcworkspacedata",
             "storyboard", "xib", "csproj", "vcxproj", "sln": return .xml
        case "proto", "protobuf": return .protobuf
        case "graphql", "gql": return .graphql
        case "diff", "patch": return .diff
        case "tex", "latex", "math": return .latex
        case "org": return .orgMode
        case "mmd", "mermaid": return .mermaid
        case "dot", "gv": return .dot
        default: return .unknown
        }
    }

    var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .typescript: return "TypeScript"
        case .tsx: return "TSX"
        case .javascript: return "JavaScript"
        case .jsx: return "JSX"
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
        case .xml: return "XML"
        case .protobuf: return "Protobuf"
        case .graphql: return "GraphQL"
        case .diff: return "Diff"
        case .latex: return "LaTeX"
        case .orgMode: return "Org"
        case .mermaid: return "Mermaid"
        case .dot: return "Graphviz"
        case .unknown: return "Text"
        }
    }

    var lineCommentPrefix: [Character]? {
        switch self {
        case .swift, .typescript, .tsx, .javascript, .jsx, .go, .rust, .c, .cpp, .java, .kotlin, .zig, .css,
             .protobuf, .graphql:
            return ["/", "/"]
        case .python, .ruby, .shell, .yaml, .toml:
            return ["#"]
        case .sql:
            return ["-", "-"]
        case .latex:
            return ["%"]
        case .orgMode:
            return ["#"]
        case .mermaid:
            return ["%", "%"]
        case .dot:
            return ["/", "/"]
        case .html, .json, .xml, .diff, .unknown:
            return nil
        }
    }

    var hasBlockComments: Bool {
        switch self {
        case .swift, .typescript, .tsx, .javascript, .jsx, .go, .rust, .c, .cpp, .java, .kotlin, .zig, .css,
             .protobuf, .graphql, .dot:
            return true
        case .xml:
            return true // <!-- --> handled by XML scanner
        default:
            return false
        }
    }

    var keywords: Set<String> {
        switch self {
        case .swift:
            return swiftKeywords
        case .typescript, .tsx, .javascript, .jsx:
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
        case .protobuf:
            return protobufKeywords
        case .graphql:
            return graphqlKeywords
        case .latex:
            return latexKeywords
        case .orgMode:
            return orgModeKeywords
        case .mermaid:
            return mermaidKeywords
        case .dot:
            return dotKeywords
        case .html, .css, .json, .yaml, .toml, .xml, .diff, .unknown:
            return []
        }
    }
}
