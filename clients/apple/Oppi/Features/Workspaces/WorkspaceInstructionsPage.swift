import SwiftUI

/// Workspace instructions editor. The text is a draft: Save writes it, back discards it.
struct WorkspaceInstructionsPage: View {
    let model: WorkspaceSettingsModel

    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var isSaving = false
    @State private var error: String?
    /// A save that finishes after Back must not pop whatever is on top now.
    @State private var isVisible = true

    init(model: WorkspaceSettingsModel) {
        self.model = model
        _text = State(initialValue: model.workspace.systemPrompt ?? "")
    }

    private var isDirty: Bool {
        text != (model.workspace.systemPrompt ?? "")
    }

    private var clearAction: some View {
        Button("Clear", systemImage: "trash", role: .destructive) {
            text = ""
        }
        .disabled(text.isEmpty)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Added after Pi\u{2019}s base prompt for every session in this workspace.")
                .font(.caption)
                .foregroundStyle(.themeComment)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.themeFg)
                .tint(.themeBlue)
                .autocorrectionDisabled(false)
                .textInputAutocapitalization(.sentences)
                .writingToolsBehavior(.complete)
                .writingToolsAffordanceVisibility(.visible)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .themedTextInputCard(strokeOpacity: 0.25)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityIdentifier("workspace.edit.instructions.editor")

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.themeRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("workspace.edit.instructions.error")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .themedScrollSurface()
        .navigationTitle("Instructions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(role: .confirm) {
                    Task { await save() }
                }
                .disabled(!isDirty || isSaving)
                .accessibilityLabel("Save")
                .accessibilityIdentifier("workspace.edit.instructions.save")
            }
            if #available(iOS 27.0, *) {
                ToolbarOverflowMenu { clearAction }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        clearAction
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()

                Text("\(text.count) chars")
                    .font(.caption.monospaced())
                    .foregroundStyle(.themeComment)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.themeSurfaceFill(.opaqueCard).ignoresSafeArea(edges: .bottom))
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        switch await model.saveInstructions(text) {
        case .saved:
            if isVisible { dismiss() }
            isSaving = false
        case .failed(let message):
            error = message
            isSaving = false
        case .superseded:
            isSaving = false
        }
    }
}
