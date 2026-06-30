import SwiftUI

struct ReviewCommentStashSheet: View {
    let comments: [ReviewComment]
    let focusedCommentId: String?
    let onDelete: (ReviewComment) -> Void
    let onClose: () -> Void

    private var sortedComments: [ReviewComment] {
        comments.sorted { left, right in
            if left.id == focusedCommentId { return true }
            if right.id == focusedCommentId { return false }
            return left.createdAt < right.createdAt
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sortedComments.isEmpty {
                    ContentUnavailableView(
                        "No Staged Review Comments",
                        systemImage: "text.bubble",
                        description: Text("Comments you add from selected text will appear here before you send them.")
                    )
                } else {
                    List(sortedComments) { comment in
                        ReviewCommentStashRow(
                            comment: comment,
                            isFocused: comment.id == focusedCommentId,
                            onDelete: { onDelete(comment) }
                        )
                        .listRowBackground(rowBackground(isFocused: comment.id == focusedCommentId))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                onDelete(comment)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Staged Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }

    private func rowBackground(isFocused: Bool) -> Color {
        isFocused ? Color.themeCyan.opacity(0.12) : Color.clear
    }
}

private struct ReviewCommentStashRow: View {
    let comment: ReviewComment
    let isFocused: Bool
    let onDelete: () -> Void

    private var selectedText: String? {
        guard let text = comment.reference.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeCyan)

                Text(locationText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if isFocused {
                    Image(systemName: "scope")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeCyan)
                }

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.themeRed)
                .accessibilityLabel("Remove review comment")
            }

            if let selectedText {
                Text(selectedText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.themeFgDim)
                    .lineLimit(3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.themeBgHighlight.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Text(comment.body)
                .font(.body)
                .foregroundStyle(.themeFg)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    private var locationText: String {
        if let path = comment.reference.displayPath, !path.isEmpty {
            var text = path
            if let startLine = comment.reference.startLine {
                text += ":\(startLine)"
                if let endLine = comment.reference.endLine, endLine != startLine {
                    text += "-\(endLine)"
                }
            }
            return text
        }
        if let label = comment.reference.label, !label.isEmpty {
            return label
        }
        return sourceText
    }

    private var sourceText: String {
        switch comment.reference.source {
        case .gitDiff: return "Diff"
        case .file: return "File"
        case .timelineText: return "Timeline"
        case .toolOutput: return "Tool output"
        case .terminalOutput: return "Terminal"
        case .image: return "Image"
        case .unknown: return "Review comment"
        }
    }
}
