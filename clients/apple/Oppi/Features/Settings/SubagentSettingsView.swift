import SwiftUI

struct SubagentSettingsView: View {
    @Environment(\.apiClient) private var apiClient

    @State private var config: SubagentConfig = .fallback
    @State private var models: [ModelInfo] = []
    @State private var approvedModels: Set<String> = []
    @State private var defaultModel: String = ""
    @State private var defaultThinkingRaw: String = ""
    @State private var profiles: [EditableSubagentProfile] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var profileDraft: EditableSubagentProfile?

    var body: some View {
        List {
            Section {
                Text("These profiles define how spawned child agents behave. This is the first app-facing slice of the broader agent identity system.")
                    .font(.footnote)
                    .foregroundStyle(.themeComment)
            } header: {
                Text("Subagent Identity")
            }

            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else {
                Section {
                    NavigationLink {
                        SubagentApprovedModelsView(
                            models: groupedModels,
                            approvedModels: $approvedModels
                        )
                    } label: {
                        LabeledContent("Approved Models") {
                            Text(approvedModelsSummary)
                                .foregroundStyle(.themeComment)
                        }
                    }

                    Picker("Default Model", selection: $defaultModel) {
                        Text("None").tag("")
                        ForEach(selectableModels, id: \.self) { modelID in
                            Text(modelLabel(for: modelID)).tag(modelID)
                        }
                    }

                    Picker("Default Thinking", selection: $defaultThinkingRaw) {
                        Text("None").tag("")
                        ForEach(thinkingOptions, id: \.self) { level in
                            Text(level.rawValue.capitalized).tag(level.rawValue)
                        }
                    }
                } header: {
                    Text("Model Policy")
                } footer: {
                    Text("Prefer openai-codex variants here when you want subagents to stay on the Codex lane by default.")
                }

                Section {
                    if profiles.isEmpty {
                        Text("No subagent profiles yet")
                            .foregroundStyle(.themeComment)
                    } else {
                        ForEach(profiles) { profile in
                            Button {
                                profileDraft = profile
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.key)
                                        .foregroundStyle(.themeFg)
                                    Text(profile.summary)
                                        .font(.caption)
                                        .foregroundStyle(.themeComment)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: deleteProfiles)
                    }

                    Button {
                        profileDraft = EditableSubagentProfile()
                    } label: {
                        Label("Add Profile", systemImage: "plus")
                    }
                } header: {
                    Text("Profiles")
                } footer: {
                    Text("Use profiles like discovery, coding, review, or web-research to stamp model, thinking, and prompt guidelines onto spawned agents.")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.themeRed)
                }
            }
        }
        .themedListSurface()
        .navigationTitle("Subagents")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(isLoading || isSaving)
            }
        }
        .task {
            await load()
        }
        .sheet(item: $profileDraft) { draft in
            NavigationStack {
                SubagentProfileEditorView(
                    draft: draft,
                    selectableModels: selectableModels,
                    modelLabel: modelLabel(for:),
                    onCancel: { profileDraft = nil },
                    onSave: { updated in
                        upsertProfile(updated)
                        profileDraft = nil
                    }
                )
            }
        }
    }

    private var groupedModels: [SubagentModelGroup] {
        let byProvider = Dictionary(grouping: models, by: \.provider)
        return byProvider
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { provider, items in
                SubagentModelGroup(
                    provider: provider,
                    models: items
                        .map { SubagentModelEntry(fullId: fullModelID(for: $0), name: $0.name) }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                )
            }
    }

    private var selectableModels: [String] {
        var preferred = approvedModels.isEmpty ? Set(models.map(fullModelID(for:))) : approvedModels
        if !defaultModel.isEmpty {
            preferred.insert(defaultModel)
        }
        for profile in profiles where !profile.model.isEmpty {
            preferred.insert(profile.model)
        }
        return Array(preferred).sorted { modelLabel(for: $0).localizedCaseInsensitiveCompare(modelLabel(for: $1)) == .orderedAscending }
    }

    private var approvedModelsSummary: String {
        if approvedModels.isEmpty { return "Any available model" }
        if approvedModels.count == 1 { return approvedModels.first ?? "1 model" }
        return "\(approvedModels.count) models"
    }

    private var thinkingOptions: [ThinkingLevel] {
        [.off, .minimal, .low, .medium, .high, .xhigh]
    }

    private func fullModelID(for model: ModelInfo) -> String {
        model.id.hasPrefix("\(model.provider)/") ? model.id : "\(model.provider)/\(model.id)"
    }

    private func modelLabel(for modelID: String) -> String {
        models.first(where: { fullModelID(for: $0) == modelID })?.name ?? modelID
    }

    private func load() async {
        guard let api = apiClient else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        do {
            async let configTask = api.getSubagentConfig()
            async let modelsTask = api.listModels()
            let (loadedConfig, loadedModels) = try await (configTask, modelsTask)
            config = loadedConfig
            models = loadedModels
            approvedModels = Set(loadedConfig.modelPolicy?.approvedModels ?? [])
            defaultModel = loadedConfig.modelPolicy?.defaultModel ?? ""
            defaultThinkingRaw = loadedConfig.modelPolicy?.defaultThinking?.rawValue ?? ""
            profiles = (loadedConfig.modelPolicy?.profiles ?? [:])
                .map { key, profile in
                    EditableSubagentProfile(
                        key: key,
                        description: profile.description ?? "",
                        model: profile.model ?? "",
                        thinkingRaw: profile.thinking?.rawValue ?? "",
                        guidelinesText: (profile.guidelines ?? []).joined(separator: "\n")
                    )
                }
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        } catch {
            errorMessage = "Failed to load subagent settings: \(error.localizedDescription)"
        }
    }

    private func save() async {
        guard let api = apiClient else { return }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil

        var next = config
        let profileEntries: [(String, SubagentModelProfile)] = profiles.compactMap { draft in
            guard let profile = draft.toProfile() else { return nil }
            return (draft.key, profile)
        }
        let profileMap = Dictionary(uniqueKeysWithValues: profileEntries)
        next.modelPolicy = SubagentModelPolicy(
            approvedModels: approvedModels.isEmpty ? nil : Array(approvedModels).sorted(),
            defaultModel: defaultModel.isEmpty ? nil : defaultModel,
            defaultThinking: defaultThinkingRaw.isEmpty ? nil : ThinkingLevel(rawValue: defaultThinkingRaw),
            profiles: profileMap.isEmpty ? nil : profileMap
        )

        do {
            let saved = try await api.setSubagentConfig(next)
            config = saved
            approvedModels = Set(saved.modelPolicy?.approvedModels ?? [])
            defaultModel = saved.modelPolicy?.defaultModel ?? ""
            defaultThinkingRaw = saved.modelPolicy?.defaultThinking?.rawValue ?? ""
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save subagent settings: \(error.localizedDescription)"
        }
    }

    private func upsertProfile(_ updated: EditableSubagentProfile) {
        guard !updated.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let index = profiles.firstIndex(where: { $0.id == updated.id }) {
            profiles[index] = updated
        } else if let index = profiles.firstIndex(where: { $0.key.caseInsensitiveCompare(updated.key) == .orderedSame }) {
            profiles[index] = updated
        } else {
            profiles.append(updated)
        }
        profiles.sort { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    private func deleteProfiles(at offsets: IndexSet) {
        profiles.remove(atOffsets: offsets)
    }
}

private struct SubagentModelGroup: Identifiable {
    let provider: String
    let models: [SubagentModelEntry]
    var id: String { provider }
}

private struct SubagentModelEntry: Identifiable {
    let fullId: String
    let name: String
    var id: String { fullId }
}

private struct EditableSubagentProfile: Identifiable, Equatable {
    var id = UUID()
    var key: String = ""
    var description: String = ""
    var model: String = ""
    var thinkingRaw: String = ""
    var guidelinesText: String = ""

    var summary: String {
        let pieces = [
            model.isEmpty ? nil : model,
            thinkingRaw.isEmpty ? nil : thinkingRaw,
            description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description,
        ].compactMap { $0 }
        return pieces.joined(separator: " • ")
    }

    func toProfile() -> SubagentModelProfile? {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        let guidelines = guidelinesText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return SubagentModelProfile(
            description: description.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            thinking: thinkingRaw.isEmpty ? nil : ThinkingLevel(rawValue: thinkingRaw),
            guidelines: guidelines.isEmpty ? nil : guidelines
        )
    }
}

private struct SubagentApprovedModelsView: View {
    let models: [SubagentModelGroup]
    @Binding var approvedModels: Set<String>

    var body: some View {
        List {
            Section {
                Button("Allow Any Available Model") {
                    approvedModels.removeAll()
                }
            }

            ForEach(models) { group in
                Section(header: Text(group.provider)) {
                    ForEach(group.models) { model in
                        Toggle(isOn: binding(for: model.fullId)) {
                            Text(model.name)
                        }
                    }
                }
            }
        }
        .themedListSurface()
        .navigationTitle("Approved Models")
    }

    private func binding(for modelID: String) -> Binding<Bool> {
        Binding(
            get: { approvedModels.contains(modelID) },
            set: { isEnabled in
                if isEnabled {
                    approvedModels.insert(modelID)
                } else {
                    approvedModels.remove(modelID)
                }
            }
        )
    }
}

private struct SubagentProfileEditorView: View {
    @State var draft: EditableSubagentProfile
    let selectableModels: [String]
    let modelLabel: (String) -> String
    let onCancel: () -> Void
    let onSave: (EditableSubagentProfile) -> Void

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Profile key", text: $draft.key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Description", text: $draft.description, axis: .vertical)
                    .lineLimit(2 ... 4)
            }

            Section("Defaults") {
                Picker("Model", selection: $draft.model) {
                    Text("None").tag("")
                    ForEach(selectableModels, id: \.self) { modelID in
                        Text(modelLabel(modelID)).tag(modelID)
                    }
                }

                Picker("Thinking", selection: $draft.thinkingRaw) {
                    Text("None").tag("")
                    ForEach([ThinkingLevel.off, .minimal, .low, .medium, .high, .xhigh], id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(level.rawValue)
                    }
                }
            }

            Section("Guidelines") {
                TextEditor(text: $draft.guidelinesText)
                    .frame(minHeight: 120)
                    .font(.system(.body, design: .monospaced))
                Text("One guideline per line. These are injected ahead of the child task prompt.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
        }
        .navigationTitle(draft.key.isEmpty ? "New Profile" : draft.key)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    onSave(draft)
                }
                .disabled(draft.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
