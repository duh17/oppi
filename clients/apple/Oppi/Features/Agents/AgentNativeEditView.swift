import SwiftUI

struct AgentNativeEditView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss

    let agent: StoredAgentDefinition
    let onSaved: (StoredAgentDefinition) -> Void

    @State private var name: String
    @State private var description: String
    @State private var usesCustomInstructions: Bool
    @State private var instructionMode: AgentInstructionMode
    @State private var instructionText: String
    @State private var model: String
    @State private var thinkingLevel: ThinkingLevel?
    @State private var isShowingModelPicker = false
    @State private var isSaving = false
    @State private var error: String?

    init(agent: StoredAgentDefinition, onSaved: @escaping (StoredAgentDefinition) -> Void) {
        self.agent = agent
        self.onSaved = onSaved
        let definition = agent.definition
        _name = State(initialValue: definition.name)
        _description = State(initialValue: definition.description ?? "")
        _usesCustomInstructions = State(initialValue: definition.instructions != nil)
        _instructionMode = State(initialValue: definition.instructions?.mode ?? .append)
        _instructionText = State(initialValue: definition.instructions?.text ?? "")
        _model = State(initialValue: definition.sessionDefaults?.model ?? "")
        _thinkingLevel = State(initialValue: definition.sessionDefaults?.thinkingLevel)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!usesCustomInstructions
                || !instructionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("agent.nativeEdit.name")
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("agent.nativeEdit.description")
                }

                Section {
                    Toggle("Custom system prompt", isOn: $usesCustomInstructions)
                        .accessibilityIdentifier("agent.nativeEdit.customPrompt")

                    if usesCustomInstructions {
                        Picker("Behavior", selection: $instructionMode) {
                            Text("Append").tag(AgentInstructionMode.append)
                            Text("Replace").tag(AgentInstructionMode.replace)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("agent.nativeEdit.promptMode")

                        TextEditor(text: $instructionText)
                            .frame(minHeight: 180)
                            .accessibilityLabel("System prompt")
                            .accessibilityIdentifier("agent.nativeEdit.prompt")
                    }
                } header: {
                    Text("System Prompt")
                } footer: {
                    if usesCustomInstructions {
                        Text(instructionMode == .append
                            ? "Adds these instructions after the server's default system prompt."
                            : "Uses these instructions instead of the server's default system prompt.")
                    } else {
                        Text("Uses the server's default system prompt.")
                    }
                }

                Section("Pi Session Defaults") {
                    Button {
                        isShowingModelPicker = true
                    } label: {
                        LabeledContent("Model") {
                            Text(modelDisplayName)
                                .foregroundStyle(.themeFg)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("agent.nativeEdit.model")

                    if !model.isEmpty {
                        Button("Use Server Default Model") { model = "" }
                            .foregroundStyle(.themeBlue)
                    }

                    Picker("Thinking", selection: $thinkingLevel) {
                        Text("Default").tag(ThinkingLevel?.none)
                        ForEach(ThinkingLevel.allCases) { level in
                            Text(level.displayTitle).tag(Optional(level))
                        }
                    }
                    .accessibilityIdentifier("agent.nativeEdit.thinking")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.themeRed)
                    }
                }
            }
            .disabled(isSaving)
            .navigationTitle("Edit Agent")
            .navigationBarTitleDisplayMode(.inline)
            .themedListSurface()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("agent.nativeEdit.save")
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
        .sheet(isPresented: $isShowingModelPicker) {
            ModelPickerSheet(currentModel: model.managementNilIfBlank) { selected in
                model = ModelSwitchPolicy.fullModelID(for: selected)
                AppPreferences.RecentModels.record(model)
            }
        }
    }

    private var modelDisplayName: String {
        guard let model = model.managementNilIfBlank else { return "Server default" }
        return SessionFormatting.shortModelName(model) ?? model
    }

    @MainActor
    private func save() async {
        guard let apiClient else {
            error = "Server is offline"
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            let updated = try await apiClient.updateAgentNative(
                agentId: agent.id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description.managementNilIfBlank,
                instructions: usesCustomInstructions
                    ? AgentInstructions(mode: instructionMode, text: instructionText)
                    : nil,
                model: model.managementNilIfBlank,
                thinkingLevel: thinkingLevel
            )
            onSaved(updated)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension String {
    var managementNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
