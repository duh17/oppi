import SwiftUI

struct ReviewCommentStashSheet: View {
    let comments: [ReviewComment]
    let focusedCommentId: String?
    let onEdit: (ReviewComment, String) -> Bool
    let onDelete: (ReviewComment) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ReviewCommentStashContent(
                comments: comments,
                focusedCommentId: focusedCommentId,
                onEdit: onEdit,
                onDelete: onDelete,
                onClose: onClose
            )
        }
    }
}

enum ReviewCommentStashChrome {
    case sheet
    case drawer
}

struct ReviewCommentStashContent: View {
    let comments: [ReviewComment]
    let focusedCommentId: String?
    let onEdit: (ReviewComment, String) -> Bool
    let onDelete: (ReviewComment) -> Void
    var onClose: (() -> Void)? = nil
    var chrome: ReviewCommentStashChrome = .sheet

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
                commentsList
            }
        }
        .modifier(ReviewCommentStashSheetChromeModifier(
            chrome: chrome,
            title: editingComment == nil
                ? ReviewCommentStripChrome.stashTitle(count: comments.count)
                : "Edit Comment",
            showsEditorCancel: editingComment != nil,
            onCancelEditor: { editingComment = nil },
            onClose: onClose
        ))
    }

    @ViewBuilder
    private var commentsStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sortedComments) { comment in
                ReviewCommentStashRow(
                    comment: comment,
                    comments: comments,
                    isFocused: comment.id == focusedCommentId,
                    onEdit: { editingComment = comment },
                    onDelete: { onDelete(comment) }
                )
                .padding(.horizontal, chrome == .drawer ? 0 : 16)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    comment.id == focusedCommentId
                        ? Color.themeCyan.opacity(0.12)
                        : Color.clear
                )
                if comment.id != sortedComments.last?.id {
                    Divider()
                        .padding(.leading, chrome == .drawer ? 0 : 16)
                }
            }
        }
    }

    @ViewBuilder
    private var commentsList: some View {
        switch chrome {
        case .sheet:
            ScrollView {
                commentsStack
                    .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        case .drawer:
            commentsStack
        }
    }
}

private struct ReviewCommentStashSheetChromeModifier: ViewModifier {
    let chrome: ReviewCommentStashChrome
    let title: String
    let showsEditorCancel: Bool
    let onCancelEditor: () -> Void
    let onClose: (() -> Void)?

    @Environment(\.theme) private var theme
    @Environment(\.themeID) private var themeID

    func body(content: Content) -> some View {
        switch chrome {
        case .drawer:
            content
        case .sheet:
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .background(theme.bg.primary)
                .toolbarBackground(theme.bg.primary, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(themeID.preferredColorScheme, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if showsEditorCancel {
                            Button("Cancel", action: onCancelEditor)
                        } else if let onClose {
                            Button("Done", action: onClose)
                        }
                    }
                }
        }
    }
}

private struct ReviewCommentStashRow: View {
    let comment: ReviewComment
    let comments: [ReviewComment]
    let isFocused: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeCyan)

                Text(ReviewCommentStashLocation.compactText(for: comment, among: comments))
                    .font(.caption.monospaced())
                    .foregroundStyle(.themeComment)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(ReviewCommentStashLocation.completeText(for: comment))

                if isFocused {
                    Image(systemName: "scope")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeCyan)
                }

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.caption.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.themeBlue)
                .accessibilityLabel("Edit review comment")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
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
                Text(ReviewCommentStashLocation.completeText(for: comment))
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

            Section {
                Button("Save", action: save)
                    .disabled(saveDisabled)
                Button("Cancel", role: .cancel, action: onCancel)
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
}
