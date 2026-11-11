import Foundation
import UniformTypeIdentifiers

// MARK: - FileKind

/// What a file is, as far as the app decides how to detect, label, and open it.
///
/// Every kind is declared here and found through `FileKindTable`; callers read
/// what a kind says about itself (`previewCategory`, `syntaxLanguage`) and never
/// look at an extension. Kinds compare by value, so `kind == .markdown` names a
/// kind, not a path suffix.
struct FileKind: Equatable, Sendable {
    let displayLabel: String
    let previewCategory: FilePreviewCategory
    /// Source-listing syntax language for this kind.
    ///
    /// Rendering distinctions stay on the kind (JSON vs code, HTML preview vs
    /// source, document renderers). This projection is only for painters.
    let syntaxLanguage: SyntaxLanguage?
    private let isSourceCode: Bool

    private init(
        _ displayLabel: String,
        _ previewCategory: FilePreviewCategory,
        syntax: SyntaxLanguage? = nil,
        isSourceCode: Bool = false
    ) {
        self.displayLabel = displayLabel
        self.previewCategory = previewCategory
        self.syntaxLanguage = syntax
        self.isSourceCode = isSourceCode
    }

    /// The language of a source file this table has no document renderer for.
    var codeLanguage: SyntaxLanguage? { isSourceCode ? syntaxLanguage : nil }

    static func code(language: SyntaxLanguage) -> Self {
        Self(language.displayName, .text, syntax: language, isSourceCode: true)
    }

    static let markdown = Self("Markdown", .text)
    static let html = Self("HTML", .text, syntax: .html)
    static let json = Self("JSON", .text, syntax: .json)
    static let image = Self("Image", .image)
    static let audio = Self("Audio", .audio)
    static let video = Self("Video", .video)
    static let pdf = Self("PDF", .pdf)
    static let usdz = Self("USDZ", .usdz)
    /// An EPUB book: a whole archive the phone opens and reads itself.
    static let book = Self("EPUB", .book)
    static let binary = Self("Binary", .binary)
    static let plain = Self("Text", .text)

    // Document renderers: native rendering from spec.
    static let latex = Self("LaTeX", .text, syntax: .latex)
    static let orgMode = Self("Org", .text, syntax: .orgMode)
    static let mermaid = Self("Mermaid", .text, syntax: .mermaid)
    static let graphviz = Self("Graphviz", .text, syntax: .dot)
    static let csv = Self("CSV", .text)
    static let tsv = Self("TSV", .text)
    static let geojson = Self("GeoJSON", .text, syntax: .json)
    static let topojson = Self("TopoJSON", .text, syntax: .json)

    /// Detect from file path extension (or well-known filenames), with
    /// optional shebang fallback for extensionless scripts.
    static func detect(from path: String?, content: String? = nil) -> Self {
        guard let path else {
            if let lang = shebangLanguage(from: content) {
                return .code(language: lang)
            }
            return .plain
        }

        let filename = (path as NSString).lastPathComponent.lowercased()
        let ext = (path as NSString).pathExtension.lowercased()

        // Well-known filenames without extension
        switch filename {
        case "dockerfile", "containerfile", "makefile", "gnumakefile",
             "justfile":
            return .code(language: .shell)
        case "rakefile":
            return .code(language: .ruby)
        case ".gitignore", ".dockerignore", ".prettierignore", ".eslintignore",
             ".npmignore", ".hgignore":
            return .code(language: .shell)
        case ".env", ".env.local", ".env.development", ".env.production",
             ".env.test", ".env.staging":
            return .code(language: .shell)
        default:
            break
        }

        // Dotfiles that are typically JSON
        if filename.hasPrefix(".") && ext.isEmpty {
            switch filename {
            case ".prettierrc", ".eslintrc", ".babelrc", ".swcrc":
                return .json
            default:
                break
            }
        }

        if ext.isEmpty {
            if let lang = shebangLanguage(from: content) {
                return .code(language: lang)
            }
            return .plain
        }

        if let row = FileKindTable.row(forExtension: ext) {
            return row.kind
        }
        let lang = SyntaxLanguage.detect(ext)
        if lang == .json {
            if let geographic = GeographicJSONSniffer.fileKind(from: content) {
                return geographic
            }
            return .json
        }
        if lang != .unknown { return .code(language: lang) }
        return .plain
    }

    /// The uniform type a file is shared as, so the app that receives it
    /// knows what it is: a video for Photos, a scene for Quick Look, a book
    /// for Books. The system's type for the extension when it fits what the
    /// table opens the path as (a `.ts` source file is text, not a transport
    /// stream), else the type of the table's MIME type, else the category's.
    static func contentType(forPath path: String) -> UTType {
        let ext = (path as NSString).pathExtension.lowercased()
        let base = detect(from: path).previewCategory.baseContentType
        if let byExtension = UTType(filenameExtension: ext), byExtension.isDeclared, byExtension.conforms(to: base) {
            return byExtension
        }
        if let mimeType = FileKindTable.row(forExtension: ext)?.mimeType,
           let byMimeType = UTType(mimeType: mimeType), byMimeType.isDeclared {
            return byMimeType
        }
        return base
    }

    private static func shebangLanguage(from content: String?) -> SyntaxLanguage? {
        guard let content, !content.isEmpty else { return nil }
        guard let firstLine = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return nil
        }

        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#!") else { return nil }

        let shebang = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard !shebang.isEmpty else { return nil }

        let tokens = shebang.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }

        let command: String
        let interpreter = (tokens[0] as NSString).lastPathComponent.lowercased()

        if interpreter == "env" {
            var index = 1
            while index < tokens.count, tokens[index].hasPrefix("-") {
                index += 1
            }
            guard index < tokens.count else { return nil }
            command = (tokens[index] as NSString).lastPathComponent.lowercased()
        } else {
            command = interpreter
        }

        switch command {
        case "sh", "bash", "zsh", "fish", "ksh", "dash", "ash":
            return .shell
        case "python", "python2", "python3", "pypy", "pypy3":
            return .python
        case "ruby", "jruby":
            return .ruby
        case "node", "nodejs", "bun", "deno":
            return .javascript
        default:
            return nil
        }
    }
}

// MARK: - FilePreviewCategory

/// How the file viewer opens a kind.
enum FilePreviewCategory: Equatable {
    case image
    case audio
    case video
    case pdf
    case usdz
    /// An EPUB book, opened by the native reader after it downloads.
    case book
    case text
    case binary

    /// The widest uniform type every file of this category is.
    var baseContentType: UTType {
        switch self {
        case .image: .image
        case .audio: .audio
        case .video: .movie
        case .pdf: .pdf
        case .usdz: .usdz
        case .book: .epub
        case .text: .text
        case .binary: .data
        }
    }
}
