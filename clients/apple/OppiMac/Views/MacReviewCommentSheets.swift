import SwiftUI

struct MacReviewCommentComposerSheet: View {
    let draft: MacReviewCommentDraft
    let onSave: (String) -> String?
    let onCancel: () -> Void

    @State private var bodyText = ""
    @State private var errorMessage: String?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Review Comment")
                .font(.headline)
            Text(whereLabel)
                .font(.caption)
                .foregroundStyle(theme.text.secondary)
                .textSelection(.enabled)

            GroupBox("Selected text") {
                ScrollView {
                    Text(draft.selectedText)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 72, maxHeight: 160)
            }

            TextEditor(text: $bodyText)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(theme.text.tertiary.opacity(0.35), lineWidth: 1)
                )
                .accessibilityIdentifier("mac.reviewComment.composer.body")

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(theme.accent.red)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let error = onSave(bodyText) {
                        errorMessage = error
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("mac.reviewComment.composer.save")
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 360)
    }

    private var whereLabel: String {
        if let path = draft.path, !path.isEmpty {
            if let start = draft.startLine {
                if let end = draft.endLine, end != start {
                    return "\(path):\(start)-\(end)"
                }
                return "\(path):\(start)"
            }
            return path
        }
        return draft.label ?? "Selected text"
    }
}

struct MacReviewCommentStashSheet: View {
    let comments: [ReviewComment]
    let onEdit: (ReviewComment, String) -> String?
    let onDelete: (ReviewComment) -> Void
    let onClose: () -> Void

    @State private var editing: ReviewComment?
    @State private var editBody = ""
    @State private var errorMessage: String?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(editing == nil ? "Staged Comments" : "Edit Comment")
                    .font(.headline)
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }

            if let editing {
                editor(for: editing)
            } else if comments.isEmpty {
                ContentUnavailableView(
                    "No Staged Review Comments",
                    systemImage: "text.bubble",
                    description: Text("Select text in the document column or timeline, then choose Add Review Comment.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(comments) { comment in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title(for: comment.reference))
                            .font(.caption)
                            .foregroundStyle(theme.text.secondary)
                        if let selected = comment.reference.selectedText, !selected.isEmpty {
                            Text(selected)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(4)
                                .textSelection(.enabled)
                        }
                        Text(comment.body)
                            .font(.body)
                            .textSelection(.enabled)
                        HStack {
                            Button("Edit") {
                                self.editing = comment
                                editBody = comment.body
                                errorMessage = nil
                            }
                            .accessibilityLabel("Edit review comment")
                            Button("Remove", role: .destructive) {
                                onDelete(comment)
                            }
                            .accessibilityLabel("Remove review comment")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(theme.accent.red)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder
    private func editor(for comment: ReviewComment) -> some View {
        TextEditor(text: $editBody)
            .font(.body)
            .frame(minHeight: 160)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(theme.text.tertiary.opacity(0.35), lineWidth: 1)
            )
        HStack {
            Spacer()
            Button("Cancel") {
                editing = nil
                errorMessage = nil
            }
            Button("Save") {
                if let error = onEdit(comment, editBody) {
                    errorMessage = error
                } else {
                    editing = nil
                    errorMessage = nil
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(editBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func title(for reference: ReviewCommentReference) -> String {
        if let path = reference.displayPath ?? reference.path, !path.isEmpty {
            if let start = reference.startLine {
                if let end = reference.endLine, end != start {
                    return "\(path):\(start)-\(end)"
                }
                return "\(path):\(start)"
            }
            return path
        }
        return reference.label ?? "Selected text"
    }
}
