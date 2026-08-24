import SwiftUI

struct ReviewCommentStashSheet: View {
    let comments: [ReviewComment]
    let focusedCommentId: String?
    let onEdit: (ReviewComment, String) -> Bool
    let onDelete: (ReviewComment) -> Void
    let onClose: () -> Void

    @State private var editingComment: ReviewComment?

    private var sortedComments: [ReviewComment] {
        comments.sorted { left, right in
            if left.id == focusedCommentId { return true }
            if right.id == focusedCommentId { return false }
            return left.createdAt < right.createdAt
        }
    }

    var body: some View {
        let editingCommentBinding = $editingComment

        NavigationStack {
            Group {
                if let editingComment {
                    ReviewCommentEditorView(
                        comment: editingComment,
                        onSave: { body in
                            guard onEdit(editingComment, body) else { return false }
                            editingCommentBinding.wrappedValue = nil
                            return true
                        },
                        onCancel: { editingCommentBinding.wrappedValue = nil }
                    )
                } else if sortedComments.isEmpty {
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
                            onEdit: { editingComment = comment },
                            onDelete: { onDelete(comment) }
                        )
                        .listRowBackground(rowBackground(isFocused: comment.id == focusedCommentId))
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                editingComment = comment
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.themeBlue)
                        }
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
            .navigationTitle(editingComment == nil ? "Staged Comments" : "Edit Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if editingComment == nil {
                        Button("Done", action: onClose)
                    } else {
                        Button("Cancel") { editingComment = nil }
                    }
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
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeCyan)

                Text(comment.stashLocationText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if isFocused {
                    Image(systemName: "scope")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeCyan)
                }

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.caption.weight(.semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.themeBlue)
                .accessibilityLabel("Edit review comment")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.themeRed)
                .accessibilityLabel("Remove review comment")
            }

            if let selectedText = comment.stashSelectedText {
                Text(selectedText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.themeFgDim)
                    .lineLimit(3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.themeBgHighlight.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Button(action: onEdit) {
                Text(comment.body)
                    .font(.body)
                    .foregroundStyle(.themeFg)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit review comment")
        }
        .padding(.vertical, 8)
    }
}

private struct ReviewCommentEditorView: View {
    let comment: ReviewComment
    let onSave: (String) -> Bool
    let onCancel: () -> Void

    @State private var bodyText: String
    @State private var errorMessage: String?
    @FocusState private var isEditorFocused: Bool

    init(
        comment: ReviewComment,
        onSave: @escaping (String) -> Bool,
        onCancel: @escaping () -> Void
    ) {
        self.comment = comment
        self.onSave = onSave
        self.onCancel = onCancel
        _bodyText = State(initialValue: comment.body)
    }

    private var trimmedBody: String {
        bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var saveDisabled: Bool {
        trimmedBody.isEmpty || trimmedBody == comment.body
    }

    var body: some View {
        Form {
            Section("Location") {
                Text(comment.stashLocationText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.themeComment)
            }

            if let selectedText = comment.stashSelectedText {
                Section("Selected Text") {
                    Text(selectedText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.themeFgDim)
                        .textSelection(.enabled)
                }
            }

            Section("Comment") {
                TextEditor(text: $bodyText)
                    .font(.body)
                    .frame(minHeight: 180, alignment: .topLeading)
                    .focused($isEditorFocused)
                    .accessibilityLabel("Review comment text")

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.themeRed)
                }
            }
        }
        .navigationTitle("Edit Comment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(saveDisabled)
            }
        }
        .onAppear {
            isEditorFocused = true
        }
    }

    private func save() {
        guard !trimmedBody.isEmpty else {
            errorMessage = "Review comment body is required."
            return
        }
        guard trimmedBody != comment.body else {
            onCancel()
            return
        }
        if onSave(trimmedBody) {
            onCancel()
        } else {
            errorMessage = "Could not save the review comment."
        }
    }
}

private extension ReviewComment {
    var stashSelectedText: String? {
        guard let text = reference.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    var stashLocationText: String {
        if let path = reference.displayPath, !path.isEmpty {
            var text = path
            if let startLine = reference.startLine {
                text += ":\(startLine)"
                if let endLine = reference.endLine, endLine != startLine {
                    text += "-\(endLine)"
                }
            }
            return text
        }
        if let label = reference.label, !label.isEmpty {
            return label
        }
        return stashSourceText
    }

    var stashSourceText: String {
        switch reference.source {
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
