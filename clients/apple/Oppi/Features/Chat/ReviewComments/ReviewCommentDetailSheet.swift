import SwiftUI

struct ReviewCommentDetailSheet: View {
    let comment: ReviewComment
    var voiceInputManager: VoiceInputManager?
    let onClose: () -> Void
    let onShowAll: () -> Void
    let onUpdateBody: (ReviewComment, String) async -> Bool
    let onDelete: (ReviewComment) -> Void
    let onResolve: (ReviewComment) -> Void

    @State private var isEditing = false
    @State private var draftBody: String
    @State private var textBeforeRecording: String?
    @State private var isSaving = false

    init(
        comment: ReviewComment,
        voiceInputManager: VoiceInputManager? = nil,
        onClose: @escaping () -> Void,
        onShowAll: @escaping () -> Void,
        onUpdateBody: @escaping (ReviewComment, String) async -> Bool,
        onDelete: @escaping (ReviewComment) -> Void,
        onResolve: @escaping (ReviewComment) -> Void
    ) {
        self.comment = comment
        self.voiceInputManager = voiceInputManager
        self.onClose = onClose
        self.onShowAll = onShowAll
        self.onUpdateBody = onUpdateBody
        self.onDelete = onDelete
        self.onResolve = onResolve
        _draftBody = State(initialValue: comment.body)
    }

    private var canResolve: Bool {
        comment.status == .sent || comment.status == .open
    }

    private var canSave: Bool {
        !isSaving && !draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if isEditing {
                    Section("Edit comment") {
                        ReviewCommentTextInput(
                            text: $draftBody,
                            textBeforeRecording: $textBeforeRecording,
                            placeholder: "Comment…",
                            isDisabled: isSaving,
                            voiceInputManager: voiceInputManager
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section("Comment") {
                        Text(comment.body)
                            .foregroundStyle(.themeFg)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }

                if let selectedText = comment.reference.selectedText,
                   !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Highlighted text") {
                        Text(selectedText)
                            .font(.caption.monospaced())
                            .foregroundStyle(.themeComment)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    if isEditing {
                        Button(isSaving ? "Saving…" : "Save") {
                            save()
                        }
                        .disabled(!canSave)

                        Button("Cancel", role: .cancel) {
                            draftBody = comment.body
                            isEditing = false
                        }
                        .disabled(isSaving)
                    } else {
                        Button("Edit") {
                            draftBody = comment.body
                            isEditing = true
                        }

                        Button("All Review Comments", action: onShowAll)

                        if canResolve {
                            Button("Resolve") {
                                onResolve(comment)
                                onClose()
                            }
                        }
                        Button("Delete", role: .destructive) {
                            onDelete(comment)
                            onClose()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.themeBgDark)
            .navigationTitle("Review Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        let body = draftBody.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let didSave = await onUpdateBody(comment, body)
            if didSave {
                isEditing = false
                isSaving = false
                onClose()
            } else {
                isSaving = false
            }
        }
    }
}
