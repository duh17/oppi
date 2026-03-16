import SwiftUI

// MARK: - FileType

/// Detected file type for content-aware rendering.
enum FileType: Equatable {
    case markdown
    case html
    case code(language: SyntaxLanguage)
    case json
    case image
    case audio
    case plain

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
        case "dockerfile", "containerfile", "makefile", "gnumakefile":
            return .code(language: .shell)
        default:
            break
        }

        if ext.isEmpty {
            if let lang = shebangLanguage(from: content) {
                return .code(language: lang)
            }
            return .plain
        }

        switch ext {
        case "md", "mdx", "markdown":
            return .markdown
        case "html", "htm":
            return .html
        case "jpg", "jpeg", "png", "gif", "webp", "svg", "ico", "bmp", "tiff":
            return .image
        case "wav", "mp3", "m4a", "aac", "flac", "ogg", "opus", "caf":
            return .audio
        default:
            let lang = SyntaxLanguage.detect(ext)
            if lang == .json { return .json }
            if lang != .unknown { return .code(language: lang) }
            return .plain
        }
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

    var displayLabel: String {
        switch self {
        case .markdown: return "Markdown"
        case .html: return "HTML"
        case .code(let lang): return lang.displayName
        case .json: return "JSON"
        case .image: return "Image"
        case .audio: return "Audio"
        case .plain: return "Text"
        }
    }
}

// MARK: - FileContentPresentation

enum FileContentPresentation {
    /// Compact card-style rendering used inside timeline/list rows.
    case inline
    /// Native full-page rendering for dedicated file viewers.
    case document

    var usesInlineChrome: Bool {
        self == .inline
    }

    var viewportMaxHeight: CGFloat? {
        usesInlineChrome ? 500 : nil
    }

    var allowsExpansionAffordance: Bool {
        usesInlineChrome
    }
}

enum ExpandableInlineTextSelectionPolicy {
    static func allowsInlineSelection(hasFullScreenAffordance: Bool) -> Bool {
        !hasFullScreenAffordance
    }
}

extension View {
    @ViewBuilder
    func applyInlineTextSelectionPolicy(_ enabled: Bool) -> some View {
        if enabled {
            textSelection(.enabled)
        } else {
            textSelection(.disabled)
        }
    }
}
