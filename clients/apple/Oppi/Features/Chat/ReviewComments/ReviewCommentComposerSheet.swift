import SwiftUI

struct ReviewCommentComposerSheet: View {
    let selectedText: String
    let source: SelectedTextSourceContext
    var voiceInputManager: VoiceInputManager?
    let onCancel: () -> Void
    let onSave: (String) async -> Bool

    @State private var bodyText = ""
    @State private var textBeforeRecording: String?
    @State private var isSaving = false

    private var canSave: Bool {
        !isSaving && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Reference")
                        .font(.headline)
                        .foregroundStyle(.themeFg)

                    referenceCard

                    Text("Comment")
                        .font(.headline)
                        .foregroundStyle(.themeFg)

                    ReviewCommentTextInput(
                        text: $bodyText,
                        textBeforeRecording: $textBeforeRecording,
                        placeholder: "Comment…",
                        isDisabled: isSaving,
                        voiceInputManager: voiceInputManager
                    )
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 22)
            }
            .scrollContentBackground(.hidden)
            .background(Color.themeBgDark.ignoresSafeArea())
            .navigationTitle("Review Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .disabled(isSaving)
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

    private var referenceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            referenceRow(title: source.filePath == nil ? "Source" : "File", value: referenceLocation)

            if let lineRange = source.lineRange {
                Divider().overlay(Color.themeComment.opacity(0.16))
                referenceRow(title: "Lines", value: "\(lineRange.lowerBound)-\(lineRange.upperBound)")
            }

            if source.surface.prefersCodeBlockInsertion || source.languageHint != nil {
                Divider().overlay(Color.themeComment.opacity(0.16))
                NativeCodeBodyView(
                    content: selectedText,
                    language: source.languageHint,
                    startLine: source.lineRange?.lowerBound ?? 1,
                    maxHeight: 180,
                    selectedTextSourceContext: nil
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.themeMdCodeBlockBorder.opacity(0.55), lineWidth: 1)
                }
            } else {
                Divider().overlay(Color.themeComment.opacity(0.16))
                Text(selectedText)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.themeBgHighlight.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(14)
        .background(Color.themeBg.opacity(0.92), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.themeComment.opacity(0.16), lineWidth: 1)
        }
    }

    private var referenceLocation: String {
        if let filePath = source.filePath {
            return filePath
        }
        if let sourceLabel = source.sourceLabel {
            return sourceLabel
        }
        return source.surface.reviewCommentLabel
    }

    private func referenceRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeComment)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.themeFg)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
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

private extension SelectedTextSurfaceKind {
    var reviewCommentLabel: String {
        switch self {
        case .assistantProse: "Assistant message"
        case .userMessage: "User message"
        case .assistantCodeBlock: "Code block"
        case .assistantTable: "Table"
        case .thinking: "Thinking"
        case .toolCommand: "Tool command"
        case .toolOutput, .toolExpandedText: "Tool output"
        case .fullScreenCode: "Code"
        case .fullScreenDiff: "Diff"
        case .fullScreenSource: "Source"
        case .fullScreenTerminal: "Terminal"
        case .fullScreenMarkdown: "Markdown"
        case .fullScreenThinking: "Thinking"
        }
    }
}
