import SwiftUI

struct ReviewCommentComposerSheet: View {
    let selectedText: String
    let source: SelectedTextSourceContext
    var voiceInputManager: VoiceInputManager?
    var quickComments: [PiQuickAction] = []
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
                }
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(Color.themeBgDark.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                commentComposerDock
            }
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

    private var commentComposerDock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Comment")
                    .font(.headline)
                    .foregroundStyle(.themeFg)

                Spacer()

                if !quickComments.isEmpty {
                    Text("Quick comments")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeComment)
                }
            }

            if !quickComments.isEmpty {
                quickCommentStrip
            }

            ReviewCommentTextInput(
                text: $bodyText,
                textBeforeRecording: $textBeforeRecording,
                placeholder: "Comment…",
                isDisabled: isSaving,
                voiceInputManager: voiceInputManager
            )
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color.themeBgDark.opacity(0.98))
        .overlay(alignment: .top) {
            Divider().overlay(Color.themeComment.opacity(0.14))
        }
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

    private var quickCommentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickComments) { action in
                    Button {
                        applyQuickComment(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.themeFg)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(Color.themeBgHighlight.opacity(0.85), in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(Color.themeComment.opacity(0.18), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
                }
            }
            .padding(.vertical, 1)
        }
        .accessibilityLabel("Quick comments")
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

    private func applyQuickComment(_ action: PiQuickAction) {
        let text = action.quickCommentText
        guard !text.isEmpty else { return }

        let trimmedBody = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBody.isEmpty {
            bodyText = text
        } else if bodyText.hasSuffix("\n") {
            bodyText += text
        } else {
            bodyText += "\n" + text
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
