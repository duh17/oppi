import SwiftUI

/// Edit an existing workspace's configuration.
struct WorkspaceEditView: View {
    let workspace: Workspace

    @Environment(ServerConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var icon: String = ""
    @State private var selectedSkills: Set<String> = []
    @State private var runtime: String = "container"
    @State private var policyPreset: String = "container"
    @State private var hostMount: String = ""
    @State private var systemPrompt: String = ""
    @State private var memoryEnabled: Bool = false
    @State private var memoryNamespace: String = ""
    @State private var defaultModel: String = ""
    @State private var isSaving = false
    @State private var error: String?
    @State private var availableModels: [ModelInfo] = []

    private var skills: [SkillInfo] {
        connection.workspaceStore.skills
    }

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                TextField("Description", text: $description)
                TextField("Icon (SF Symbol or emoji)", text: $icon)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Section("Skills") {
                if skills.isEmpty {
                    Text("Loading skills…")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(skills) { skill in
                        SkillToggleRow(
                            skill: skill,
                            isSelected: selectedSkills.contains(skill.name),
                            onToggle: { selected in
                                if selected {
                                    selectedSkills.insert(skill.name)
                                } else {
                                    selectedSkills.remove(skill.name)
                                }
                            }
                        )
                    }
                }
            }

            Section("Runtime") {
                Picker("Runtime", selection: $runtime) {
                    Text("Container").tag("container")
                    Text("Host").tag("host")
                }
                .pickerStyle(.segmented)

                Text(runtime == "container"
                     ? "Container runtime: isolated environment."
                     : "Host runtime: direct process on macOS host.")
                    .font(.caption)
                    .foregroundStyle(runtime == "container" ? .tokyoGreen : .tokyoOrange)
            }

            Section("Policy") {
                Picker("Preset", selection: $policyPreset) {
                    Text("Container").tag("container")
                    Text("Host").tag("host")
                }
                .pickerStyle(.segmented)
            }

            Section(runtime == "container" ? "Workspace Mount" : "Host Working Directory") {
                TextField("~/workspace/project", text: $hostMount)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))

                if !hostMount.isEmpty {
                    Text(runtime == "container"
                         ? "Host directory mounted as /work in container"
                         : "Host process current directory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Memory") {
                Toggle("Enable memory", isOn: $memoryEnabled)

                if memoryEnabled {
                    TextField("Namespace", text: $memoryNamespace)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Text("Same namespace across workspaces shares memory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Default Model") {
                TextField("Model identifier", text: $defaultModel)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                ForEach(availableModels) { model in
                    Button {
                        defaultModel = model.id
                    } label: {
                        HStack {
                            Text(model.name)
                            Spacer()
                            if defaultModel == model.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }

            Section("System Prompt") {
                TextEditor(text: $systemPrompt)
                    .frame(minHeight: 100)
                    .font(.system(.body, design: .monospaced))

                Text("Appended to the base agent prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Edit Workspace")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(name.isEmpty || isSaving)
            }
        }
        .navigationDestination(for: SkillDetailDestination.self) { dest in
            SkillDetailView(skillName: dest.skillName)
        }
        .navigationDestination(for: SkillFileDestination.self) { dest in
            SkillFileView(skillName: dest.skillName, filePath: dest.filePath)
        }
        .onAppear { loadFromWorkspace() }
        .task { await loadModels() }
    }

    private func loadFromWorkspace() {
        name = workspace.name
        description = workspace.description ?? ""
        icon = workspace.icon ?? ""
        selectedSkills = Set(workspace.skills)
        runtime = workspace.runtime
        policyPreset = workspace.policyPreset
        hostMount = workspace.hostMount ?? ""
        systemPrompt = workspace.systemPrompt ?? ""
        memoryEnabled = workspace.memoryEnabled ?? false
        memoryNamespace = workspace.memoryNamespace ?? ""
        defaultModel = workspace.defaultModel ?? ""
    }

    private func loadModels() async {
        guard let api = connection.apiClient else { return }
        do {
            availableModels = try await api.listModels()
        } catch {
            // Fall back to manual entry
        }
    }

    private func save() async {
        guard let api = connection.apiClient else { return }
        isSaving = true
        error = nil

        let request = UpdateWorkspaceRequest(
            name: name,
            description: description.isEmpty ? nil : description,
            icon: icon.isEmpty ? nil : icon,
            skills: Array(selectedSkills),
            runtime: runtime,
            policyPreset: policyPreset,
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            hostMount: hostMount.isEmpty ? nil : hostMount,
            memoryEnabled: memoryEnabled,
            memoryNamespace: memoryNamespace.isEmpty ? nil : memoryNamespace,
            defaultModel: defaultModel.isEmpty ? nil : defaultModel
        )

        do {
            let updated = try await api.updateWorkspace(id: workspace.id, request)
            connection.workspaceStore.upsert(updated)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isSaving = false
        }
    }
}

// MARK: - Skill Toggle Row

private struct SkillToggleRow: View {
    let skill: SkillInfo
    let isSelected: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack {
            Button {
                onToggle(!isSelected)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(skill.name)
                                .font(.body)

                            if !skill.containerSafe {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        Text(skill.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? .tokyoBlue : .secondary)
                        .imageScale(.large)
                }
            }
            .foregroundStyle(.primary)

            NavigationLink(value: SkillDetailDestination(skillName: skill.name)) {
                EmptyView()
            }
            .frame(width: 20)
        }
    }
}
