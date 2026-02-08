import SwiftUI

/// Renders markdown text with code block extraction and syntax highlighting.
///
/// Supports: bold, italic, code, links, headings, lists, fenced code blocks.
/// Code blocks render with syntax highlighting in a monospaced chrome container.
///
/// **Streaming mode** (`isStreaming: true`):
/// - Fenced code blocks are still rendered with chrome and language labels
/// - Completed code blocks (closed with ```) get full syntax highlighting
/// - The active (unclosed) code block renders as plain monospaced text — avoids
///   running the highlighter on every 33ms delta
/// - Prose sections render as plain `Text` — skips `AttributedString(markdown:)`
///   parsing which is expensive to re-run at 30fps
///
/// **Finalized mode** (`isStreaming: false`):
/// - All code blocks get full syntax highlighting
/// - Prose sections parse through `AttributedString(markdown:)` for inline formatting
struct MarkdownText: View {
    let content: String
    let isStreaming: Bool

    init(_ content: String, isStreaming: Bool = false) {
        self.content = content
        self.isStreaming = isStreaming
    }

    var body: some View {
        let blocks = parseCodeBlocks(content)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let text):
                    proseBlock(text)

                case .codeBlock(let language, let code, let isComplete):
                    if isStreaming && !isComplete {
                        // Active streaming code block — plain monospaced, no highlighting
                        StreamingCodeBlockView(language: language, code: code)
                    } else {
                        CodeBlockView(language: language, code: code)
                    }

                case .table(let headers, let rows):
                    TableBlockView(headers: headers, rows: rows)
                }
            }
        }
    }

    @ViewBuilder
    private func proseBlock(_ text: String) -> some View {
        if isStreaming {
            // Plain text during streaming — avoids AttributedString re-parse per delta
            Text(text)
                .foregroundStyle(.tokyoFg)
        } else if let attributed = try? AttributedString(
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
    }
}

// MARK: - Code Block Views

/// Shared chrome for code block containers.
private struct CodeBlockChrome<Content: View>: View {
    let language: String?
    let code: String
    @ViewBuilder let content: () -> Content

    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language + copy button
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

            ScrollView(.horizontal, showsIndicators: false) {
                content()
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

/// Code block with async syntax highlighting.
///
/// Renders plain monospaced text immediately, then highlights asynchronously
/// via `Task.detached`. Prevents main-thread stalls when multiple code blocks
/// finalize simultaneously (e.g., long assistant message with 5+ code blocks).
private struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var highlighted: AttributedString?

    var body: some View {
        CodeBlockChrome(language: language, code: code) {
            if let highlighted {
                Text(highlighted)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tokyoFg)
                    .textSelection(.enabled)
            }
        }
        .task(id: codeIdentity) {
            let lang = language.map { SyntaxLanguage.detect($0) } ?? .unknown
            guard lang != .unknown else { return }
            let result = await Task.detached(priority: .userInitiated) {
                SyntaxHighlighter.highlight(code, language: lang)
            }.value
            highlighted = result
        }
    }

    /// Stable identity for `.task(id:)` — avoids re-highlighting unchanged code.
    private var codeIdentity: String {
        "\(language ?? "")\(code.count)"
    }
}

/// Streaming code block — plain monospaced text, no syntax highlighting.
///
/// Used for the active (unclosed) code block during streaming to avoid
/// running the highlighter on every 33ms delta flush.
private struct StreamingCodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        CodeBlockChrome(language: language, code: code) {
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tokyoFg)
        }
    }
}

// MARK: - Table Block

/// Compact, horizontally-scrollable markdown table.
///
/// Renders with a small monospaced font so tables don't dominate the
/// chat on mobile screens. Uses a grid layout with subtle dividers.
private struct TableBlockView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { i, header in
                        if i > 0 {
                            Divider()
                                .frame(height: 16)
                                .overlay(Color.tokyoComment.opacity(0.3))
                        }
                        Text(header)
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(.tokyoCyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                }
                .background(Color.tokyoBgHighlight)

                // Separator
                Rectangle()
                    .fill(Color.tokyoComment.opacity(0.35))
                    .frame(height: 1)

                // Data rows
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                            if colIdx > 0 {
                                Divider()
                                    .frame(height: 14)
                                    .overlay(Color.tokyoComment.opacity(0.2))
                            }
                            Text(cell)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tokyoFg)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                        }
                    }

                    if rowIdx < rows.count - 1 {
                        Rectangle()
                            .fill(Color.tokyoComment.opacity(0.15))
                            .frame(height: 1)
                    }
                }
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

enum ContentBlock: Equatable {
    case markdown(String)
    /// - `isComplete`: `true` when the closing ``` was found; `false` for an
    ///   unclosed (still-streaming) block. Used to decide whether to run
    ///   syntax highlighting during streaming.
    case codeBlock(language: String?, code: String, isComplete: Bool)
    /// Markdown table — rendered compact and horizontally scrollable.
    case table(headers: [String], rows: [[String]])
}

/// Split markdown content into alternating prose, fenced code blocks, and tables.
///
/// Tracks whether each code block is complete (closed with ```) so callers
/// can skip expensive highlighting on the active streaming block.
func parseCodeBlocks(_ content: String) -> [ContentBlock] {
    var blocks: [ContentBlock] = []
    var current = ""
    var inCodeBlock = false
    var codeLanguage: String?
    var codeContent = ""
    /// Accumulated table lines (header + separator + rows). Flushed when a
    /// non-table line is encountered or at end-of-content.
    var tableLines: [Substring] = []

    /// Flush accumulated prose into a `.markdown` block.
    func flushProse() {
        guard !current.isEmpty else { return }
        blocks.append(.markdown(current))
        current = ""
    }

    /// Flush accumulated table lines into a `.table` block.
    func flushTable() {
        guard tableLines.count >= 2 else {
            // Not a valid table (need header + separator at minimum).
            // Push lines back as prose.
            for line in tableLines {
                if !current.isEmpty { current += "\n" }
                current += line
            }
            tableLines.removeAll()
            return
        }

        // Validate: line[1] must be the separator (|---|---|)
        let sepLine = tableLines[1]
        let isSeparator = sepLine.contains("-") && sepLine.split(separator: "|").allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).allSatisfy { $0 == "-" || $0 == ":" }
        }
        guard isSeparator else {
            for line in tableLines {
                if !current.isEmpty { current += "\n" }
                current += line
            }
            tableLines.removeAll()
            return
        }

        flushProse()

        let headers = parseTableRow(tableLines[0])
        var rows: [[String]] = []
        for line in tableLines.dropFirst(2) {
            rows.append(parseTableRow(line))
        }
        blocks.append(.table(headers: headers, rows: rows))
        tableLines.removeAll()
    }

    for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
        if !inCodeBlock && line.hasPrefix("```") {
            // Start of code block — flush any pending table first
            flushTable()
            flushProse()
            inCodeBlock = true
            let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            codeLanguage = lang.isEmpty ? nil : lang
            codeContent = ""
        } else if inCodeBlock && line.hasPrefix("```") {
            // End of code block — complete
            blocks.append(.codeBlock(language: codeLanguage, code: codeContent, isComplete: true))
            inCodeBlock = false
            codeLanguage = nil
            codeContent = ""
        } else if inCodeBlock {
            if !codeContent.isEmpty { codeContent += "\n" }
            codeContent += line
        } else if isTableLine(line) {
            // Accumulate table lines
            if tableLines.isEmpty {
                flushProse()
            }
            tableLines.append(line)
        } else {
            // Non-table prose — flush any pending table
            if !tableLines.isEmpty {
                flushTable()
            }
            if !current.isEmpty { current += "\n" }
            current += line
        }
    }

    // Flush remaining
    if inCodeBlock {
        flushTable()
        blocks.append(.codeBlock(language: codeLanguage, code: codeContent, isComplete: false))
    } else {
        flushTable()
        if !current.isEmpty {
            blocks.append(.markdown(current))
        }
    }

    return blocks
}

/// Returns `true` if the line looks like a markdown table row (`| ... | ... |`).
private func isTableLine(_ line: Substring) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 1
}

/// Parse a single table row into cell strings, trimming outer pipes and whitespace.
private func parseTableRow(_ line: Substring) -> [String] {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    // Drop leading/trailing pipes, then split
    let inner = trimmed.dropFirst().dropLast()
    return inner.split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
}
