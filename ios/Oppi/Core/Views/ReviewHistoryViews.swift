import SwiftUI

struct ReviewHistoryEntryRow: View {
    let entry: WorkspaceReviewHistoryEntry
    let ordinal: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.kind.icon)
                .font(.caption)
                .foregroundStyle(entry.kind == .edit ? .themeCyan : .themeBlue)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(entry.kind.label) #\(ordinal)")
                    .font(.subheadline)
                    .foregroundStyle(.themeFg)

                HStack(spacing: 8) {
                    if entry.addedLines > 0 {
                        Text("+\(entry.addedLines)")
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(.themeDiffAdded)
                    }
                    if entry.removedLines > 0 {
                        Text("-\(entry.removedLines)")
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(.themeDiffRemoved)
                    }
                    if entry.addedLines == 0 && entry.removedLines == 0 {
                        Text("modified")
                            .font(.caption2)
                            .foregroundStyle(.themeComment)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct ReviewHistoryOverallDiffView: View {
    let filePath: String
    let overallDiff: ReviewHistoryOverallDiff

    private var precomputedLines: [DiffLine] {
        overallDiff.diffLines.map { line in
            let kind: DiffLine.Kind
            switch line.kind {
            case .context: kind = .context
            case .added: kind = .added
            case .removed: kind = .removed
            }
            return DiffLine(kind: kind, text: line.text)
        }
    }

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Path") {
                    ReviewPathSummaryLabel(path: filePath)
                }
                LabeledContent("Range") {
                    Text("Revision 1 → Revision \(overallDiff.revisionCount)")
                        .foregroundStyle(.themeFg)
                }
            }

            Section("Overall Diff") {
                AsyncDiffView(
                    oldText: overallDiff.baselineText,
                    newText: overallDiff.currentText,
                    filePath: filePath,
                    showHeader: true,
                    precomputedLines: precomputedLines
                )
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.themeBgDark)
        .allowsFullScreenExpansion(false)
        .navigationTitle("Overall Diff")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ReviewHistoryEntryDetailView: View {
    let entry: WorkspaceReviewHistoryEntry
    let filePath: String

    var body: some View {
        List {
            Section("Change") {
                LabeledContent("Action") {
                    Text(entry.kind.detailActionLabel)
                        .foregroundStyle(.themeFg)
                }
                LabeledContent("Path") {
                    ReviewPathSummaryLabel(path: filePath)
                }
                if entry.addedLines > 0 || entry.removedLines > 0 {
                    HStack(spacing: 10) {
                        if entry.addedLines > 0 {
                            Text("+\(entry.addedLines)")
                                .font(.caption.monospaced().bold())
                                .foregroundStyle(.themeDiffAdded)
                        }
                        if entry.removedLines > 0 {
                            Text("-\(entry.removedLines)")
                                .font(.caption.monospaced().bold())
                                .foregroundStyle(.themeDiffRemoved)
                        }
                    }
                }
            }

            Section(entry.kind == .edit ? "Diff" : "Content") {
                contentView
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.themeBgDark)
        .allowsFullScreenExpansion(false)
        .navigationTitle(entry.kind == .edit ? "Change Detail" : "Write Detail")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var contentView: some View {
        switch entry.kind {
        case .edit:
            if let oldText = entry.oldText, let newText = entry.newText {
                AsyncDiffView(
                    oldText: oldText,
                    newText: newText,
                    filePath: filePath,
                    showHeader: true
                )
            } else {
                Text("Diff unavailable for this change.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }

        case .write:
            if let content = entry.writeContent {
                FileContentView(
                    content: content,
                    filePath: filePath,
                    presentation: .document
                )
            } else {
                Text("Write content unavailable for this change.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
        }
    }
}

private struct ReviewPathSummaryLabel: View {
    let path: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(path.lastPathComponentForDisplay)
                .font(.subheadline)
                .foregroundStyle(.themeFg)

            if let parentPath = path.parentPathForDisplay {
                Text(parentPath)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .multilineTextAlignment(.trailing)
    }
}
