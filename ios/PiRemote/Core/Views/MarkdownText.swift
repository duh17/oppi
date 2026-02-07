import SwiftUI

/// Renders markdown text using `AttributedString`.
///
/// Supports: bold, italic, code, links, headings, lists.
/// Code blocks render in monospaced font with a tinted background.
///
/// Falls back to plain `Text` if markdown parsing fails.
struct MarkdownText: View {
    let content: String
    let isStreaming: Bool

    init(_ content: String, isStreaming: Bool = false) {
        self.content = content
        self.isStreaming = isStreaming
    }

    var body: some View {
        if isStreaming {
            // During streaming, skip markdown parsing entirely — the full
            // AttributedString + code-block parse runs on every delta flush
            // and is the #1 cause of UI jank.  Parse once on finalization.
            plainText
        } else {
            markdownText
        }
    }

    @ViewBuilder
    private var markdownText: some View {
        let blocks = parseCodeBlocks(content)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let text):
                    if let attributed = try? AttributedString(
                        markdown: text,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                    ) {
                        Text(attributed)
                            .foregroundStyle(.tokyoFg)
                            .textSelection(.enabled)
                    } else {
                        Text(text)
                            .foregroundStyle(.tokyoFg)
                            .textSelection(.enabled)
                    }

                case .codeBlock(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
    }

    private var plainText: some View {
        Text(content)
            .font(.body)
            .foregroundStyle(.tokyoFg)
    }
}

// MARK: - Code Block View

private struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language + copy button
            if language != nil || true {
                HStack {
                    Text(language ?? "code")
                        .font(.caption2)
                        .foregroundStyle(.tokyoComment)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = code
                        isCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            isCopied = false
                        }
                    } label: {
                        Label(
                            isCopied ? "Copied" : "Copy",
                            systemImage: isCopied ? "checkmark" : "doc.on.doc"
                        )
                        .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tokyoFgDim)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.tokyoBgHighlight)
            }

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tokyoFg)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color.tokyoBgDark)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.tokyoComment.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Code Block Parser

private enum ContentBlock {
    case markdown(String)
    case codeBlock(language: String?, code: String)
}

/// Split markdown content into alternating prose and fenced code blocks.
private func parseCodeBlocks(_ content: String) -> [ContentBlock] {
    var blocks: [ContentBlock] = []
    var current = ""
    var inCodeBlock = false
    var codeLanguage: String?
    var codeContent = ""

    for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
        if !inCodeBlock && line.hasPrefix("```") {
            // Start of code block
            if !current.isEmpty {
                blocks.append(.markdown(current))
                current = ""
            }
            inCodeBlock = true
            let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            codeLanguage = lang.isEmpty ? nil : lang
            codeContent = ""
        } else if inCodeBlock && line.hasPrefix("```") {
            // End of code block
            blocks.append(.codeBlock(language: codeLanguage, code: codeContent))
            inCodeBlock = false
            codeLanguage = nil
            codeContent = ""
        } else if inCodeBlock {
            if !codeContent.isEmpty { codeContent += "\n" }
            codeContent += line
        } else {
            if !current.isEmpty { current += "\n" }
            current += line
        }
    }

    // Flush remaining
    if inCodeBlock {
        // Unclosed code block (streaming) — render as code
        blocks.append(.codeBlock(language: codeLanguage, code: codeContent))
    } else if !current.isEmpty {
        blocks.append(.markdown(current))
    }

    return blocks
}
