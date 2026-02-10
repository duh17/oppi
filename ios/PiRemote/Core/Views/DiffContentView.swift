import SwiftUI

/// Renders a unified diff between two text blocks with Tokyo Night styling.
///
/// Computes a line-level LCS diff, then renders each line with:
/// - Colored left accent bar (green for added, red for removed)
/// - `+`/`-` gutter prefix
/// - Syntax-highlighted code (when file language is known)
/// - Tinted row background
struct DiffContentView: View {
    let oldText: String
    let newText: String
    let filePath: String?
    private let diffLines: [DiffLine]

    @Environment(\.theme) private var theme
    @State private var showFullScreen = false

    init(oldText: String, newText: String, filePath: String? = nil) {
        self.oldText = oldText
        self.newText = newText
        self.filePath = filePath
        self.diffLines = DiffEngine.compute(old: oldText, new: newText)
    }

    private var language: SyntaxLanguage {
        guard let path = filePath else { return .unknown }
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? .unknown : SyntaxLanguage.detect(ext)
    }

    var body: some View {
        let lines = diffLines

        VStack(alignment: .leading, spacing: 0) {
            diffHeader(changeStats: DiffEngine.stats(lines))

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        diffRow(line)
                    }
                }
            }
            .frame(maxHeight: 500)
        }
        .background(theme.bg.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.text.tertiary.opacity(0.35), lineWidth: 1)
        )
        .contextMenu {
            Button("Copy New Text", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = newText
            }
            Button("Copy Old Text", systemImage: "clock.arrow.circlepath") {
                UIPasteboard.general.string = oldText
            }
            Button("Copy as Diff", systemImage: "text.badge.plus") {
                UIPasteboard.general.string = DiffEngine.formatUnified(diffLines)
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenCodeView(content: .diff(
                oldText: oldText, newText: newText, filePath: filePath
            ))
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func diffHeader(changeStats: (added: Int, removed: Int)) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.caption)
                .foregroundStyle(theme.accent.cyan)

            if let path = filePath {
                Text(path.shortenedPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(theme.text.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // +N / -N badges
            if changeStats.added > 0 {
                Text("+\(changeStats.added)")
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(theme.diff.addedAccent)
            }
            if changeStats.removed > 0 {
                Text("-\(changeStats.removed)")
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(theme.diff.removedAccent)
            }

            Button { showFullScreen = true } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2)
                    .foregroundStyle(theme.text.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.bg.highlight)
    }

    // MARK: - Diff Row

    @ViewBuilder
    private func diffRow(_ line: DiffLine) -> some View {
        let lang = language

        HStack(alignment: .top, spacing: 0) {
            // Left accent bar
            Rectangle()
                .fill(accentColor(for: line.kind))
                .frame(width: 3)

            // Gutter prefix (+, -, space)
            Text(line.kind.prefix)
                .font(.system(size: theme.code.fontSize, design: .monospaced).bold())
                .foregroundStyle(prefixColor(for: line.kind))
                .frame(width: 16, alignment: .center)

            // Code text
            ScrollView(.horizontal, showsIndicators: false) {
                // Keep changed lines high-contrast and deterministic.
                // Syntax token colors can reduce readability on tinted add/remove
                // backgrounds (especially comment-heavy edits), so only context
                // lines use token-level highlighting.
                if lang != .unknown, line.kind == .context {
                    Text(SyntaxHighlighter.highlightLine(line.text, language: lang))
                        .font(.system(size: theme.code.fontSize, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text(line.text)
                        .font(.system(size: theme.code.fontSize, design: .monospaced))
                        .foregroundStyle(textColor(for: line.kind))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.trailing, 8)
        }
        .padding(.vertical, 1)
        .background(rowBackground(for: line.kind))
    }

    // MARK: - Colors

    private func accentColor(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return theme.diff.addedAccent
        case .removed: return theme.diff.removedAccent
        case .context: return .clear
        }
    }

    private func prefixColor(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return theme.diff.addedAccent
        case .removed: return theme.diff.removedAccent
        case .context: return theme.text.tertiary
        }
    }

    private func textColor(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return theme.text.primary
        case .removed: return theme.text.primary
        case .context: return theme.diff.contextFg
        }
    }

    private func rowBackground(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return theme.diff.addedBg
        case .removed: return theme.diff.removedBg
        case .context: return .clear
        }
    }
}

// DiffLine and DiffEngine live in Core/Models/DiffEngine.swift
