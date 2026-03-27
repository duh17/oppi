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
    case video
    case pdf
    case binary
    case plain

    // Document renderers — native rendering from spec
    case latex
    case orgMode
    case mermaid
    case graphviz

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

        switch ext {
        // Document renderers
        case "tex", "latex":
            return .latex
        case "org":
            return .orgMode
        case "mmd", "mermaid":
            return .mermaid
        case "dot", "gv":
            return .graphviz

        case "md", "mdx", "markdown":
            return .markdown
        case "html", "htm":
            return .html
        case "jpg", "jpeg", "png", "gif", "webp", "ico", "bmp", "tiff":
            return .image
        case "svg":
            return .image
        case "wav", "mp3", "m4a", "aac", "flac", "ogg", "opus", "caf":
            return .audio
        case "mp4", "mov", "m4v", "avi", "webm":
            return .video
        case "pdf":
            return .pdf
        case "gz", "zip", "tar", "bz2", "xz", "7z", "rar",
             "dmg", "iso", "img",
             "car", "nib", "mobileprovision", "p12", "cer",
             "dylib", "so", "a", "o", "exe", "dll",
             "woff", "woff2", "ttf", "otf", "eot":
            return .binary
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
        case .video: return "Video"
        case .pdf: return "PDF"
        case .binary: return "Binary"
        case .plain: return "Text"
        case .latex: return "LaTeX"
        case .orgMode: return "Org"
        case .mermaid: return "Mermaid"
        case .graphviz: return "Graphviz"
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
