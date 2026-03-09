import SwiftUI

/// Renders a unified diff between two text blocks using the shared performant diff view.
struct DiffContentView: View {
    let oldText: String
    let newText: String
    let filePath: String?
    let showHeader: Bool
    private let diffLines: [DiffLine]

    @Environment(\.theme) private var theme
    @Environment(\.allowsFullScreenExpansion) private var allowsFullScreenExpansion
    @State private var showFullScreen = false

    init(
        oldText: String,
        newText: String,
        filePath: String? = nil,
        showHeader: Bool = true,
        precomputedLines: [DiffLine]? = nil
    ) {
        self.oldText = oldText
        self.newText = newText
        self.filePath = filePath
        self.showHeader = showHeader
        self.diffLines = precomputedLines ?? DiffEngine.compute(old: oldText, new: newText)
    }

    private var renderedDiff: WorkspaceReviewDiffResponse {
        WorkspaceReviewDiffResponse.local(
            path: filePath ?? "diff.txt",
            baselineText: oldText,
            currentText: newText,
            precomputedLines: diffLines
        )
    }

    private var hasFullScreenAffordance: Bool {
        allowsFullScreenExpansion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeader {
                diffHeader(changeStats: DiffEngine.stats(diffLines))
            }

            UnifiedDiffView(
                hunks: renderedDiff.hunks,
                filePath: filePath ?? "diff.txt",
                emptyDescription: "This diff has no textual changes to show."
            )
            .frame(maxHeight: 500)
        }
        .background(theme.bg.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.text.tertiary.opacity(0.35), lineWidth: 1)
        )
        .contextMenu {
            if hasFullScreenAffordance {
                Button("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                    showFullScreen = true
                }
            }
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = newText
            }
            Button("Copy Old Text", systemImage: "clock.arrow.circlepath") {
                UIPasteboard.general.string = oldText
            }
            Button("Copy as Diff", systemImage: "text.badge.plus") {
                UIPasteboard.general.string = DiffEngine.formatUnified(diffLines)
            }
        }
        .sheet(isPresented: $showFullScreen) {
            FullScreenCodeView(content: .diff(
                oldText: oldText,
                newText: newText,
                filePath: filePath,
                precomputedLines: diffLines
            ))
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

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

            if hasFullScreenAffordance {
                Button { showFullScreen = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                        .foregroundStyle(theme.text.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.bg.highlight)
    }
}
