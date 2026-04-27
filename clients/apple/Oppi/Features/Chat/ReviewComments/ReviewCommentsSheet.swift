import SwiftUI

struct ReviewCommentsSheet: View {
    let comments: [ReviewComment]
    var voiceInputManager: VoiceInputManager?
    let onRefresh: () -> Void
    let onClose: () -> Void
    let onUpdateBody: (ReviewComment, String) async -> Bool
    let onDelete: (ReviewComment) -> Void
    let onResolve: (ReviewComment) -> Void

    @State private var editingComment: ReviewComment?

    private var stagedComments: [ReviewComment] {
        comments.filter { $0.status == .staged }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private var sentOrOpenComments: [ReviewComment] {
        comments.filter { $0.status == .sent || $0.status == .open }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var resolvedComments: [ReviewComment] {
        comments.filter { $0.status == .resolved }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack {
            List {
                if comments.isEmpty {
                    ContentUnavailableView(
                        "No Review Comments",
                        systemImage: "text.bubble"
                    )
                    .listRowBackground(Color.clear)
                }

                if !stagedComments.isEmpty {
                    Section("Staged for next send") {
                        ForEach(stagedComments) { comment in
                            ReviewCommentRow(
                                comment: comment,
                                primaryActionTitle: "Edit",
                                onPrimaryAction: { editingComment = comment },
                                onDelete: { onDelete(comment) },
                                onResolve: nil
                            )
                        }
                    }
                }

                if !sentOrOpenComments.isEmpty {
                    Section("Sent") {
                        ForEach(sentOrOpenComments) { comment in
                            ReviewCommentRow(
                                comment: comment,
                                primaryActionTitle: "Edit",
                                onPrimaryAction: { editingComment = comment },
                                onDelete: { onDelete(comment) },
                                onResolve: { onResolve(comment) }
                            )
                        }
                    }
                }

                if !resolvedComments.isEmpty {
                    Section("Resolved") {
                        ForEach(resolvedComments) { comment in
                            ReviewCommentRow(
                                comment: comment,
                                primaryActionTitle: "Edit",
                                onPrimaryAction: { editingComment = comment },
                                onDelete: { onDelete(comment) },
                                onResolve: nil
                            )
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.themeBgDark)
            .navigationTitle("Review Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh review comments")
                }
            }
            .sheet(item: $editingComment) { comment in
                ReviewCommentEditSheet(
                    comment: comment,
                    voiceInputManager: voiceInputManager,
                    onCancel: { editingComment = nil },
                    onSave: { body in
                        let didSave = await onUpdateBody(comment, body)
                        if didSave {
                            editingComment = nil
                        }
                        return didSave
                    }
                )
            }
        }
    }
}

private struct ReviewCommentRow: View {
    let comment: ReviewComment
    let primaryActionTitle: String
    let onPrimaryAction: () -> Void
    let onDelete: () -> Void
    let onResolve: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(referenceTitle(comment.reference))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(comment.status.rawValue.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }

            Text(comment.body)
                .font(.body)
                .foregroundStyle(.themeFg)
                .fixedSize(horizontal: false, vertical: true)

            if let selectedText = comment.reference.selectedText,
               !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(selectedText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.themeComment)
                    .lineLimit(4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.themeBgHighlight, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 12) {
                Button(primaryActionTitle, action: onPrimaryAction)
                    .font(.caption.weight(.semibold))
                if let onResolve {
                    Button("Resolve", action: onResolve)
                        .font(.caption.weight(.semibold))
                }
                Spacer()
                Button("Delete", role: .destructive, action: onDelete)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.themeBg.opacity(0.9))
    }

    private var statusColor: Color {
        switch comment.status {
        case .staged: .themePurple
        case .sent, .open: .themeOrange
        case .resolved: .themeGreen
        case .dismissed: .themeComment
        }
    }

    private func referenceTitle(_ reference: ReviewCommentReference) -> String {
        if let path = reference.path, !path.isEmpty {
            var title = path.lastPathComponentForDisplay
            if let start = reference.startLine {
                if let end = reference.endLine, end != start {
                    title += ":\(start)-\(end)"
                } else {
                    title += ":\(start)"
                }
            }
            return title
        }

        if let label = reference.label, !label.isEmpty {
            return label
        }

        return reference.source.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct ReviewCommentEditSheet: View {
    let comment: ReviewComment
    let onCancel: () -> Void
    var voiceInputManager: VoiceInputManager?
    let onSave: (String) async -> Bool

    @State private var bodyText: String
    @State private var textBeforeRecording: String?
    @State private var isSaving = false

    init(
        comment: ReviewComment,
        voiceInputManager: VoiceInputManager? = nil,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) async -> Bool
    ) {
        self.comment = comment
        self.voiceInputManager = voiceInputManager
        self.onCancel = onCancel
        self.onSave = onSave
        _bodyText = State(initialValue: comment.body)
    }

    private var canSave: Bool {
        !isSaving && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Comment") {
                    ReviewCommentTextInput(
                        text: $bodyText,
                        textBeforeRecording: $textBeforeRecording,
                        placeholder: "Comment…",
                        isDisabled: isSaving,
                        voiceInputManager: voiceInputManager
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Edit Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        let body = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let didSave = await onSave(body)
            if !didSave {
                isSaving = false
            }
        }
    }
}
