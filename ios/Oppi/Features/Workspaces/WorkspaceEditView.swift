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
    @State private var hostMount: String = ""
    @State private var systemPrompt: String = ""
    @State private var memoryEnabled: Bool = false
    @State private var memoryNamespace: String = ""
    @State private var extensionNames: String = ""
    @State private var availableExtensions: [ExtensionInfo] = []
    @State private var isLoadingExtensions = false
    @State private var extensionsError: String?
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
                    .foregroundStyle(runtime == "container" ? .themeGreen : .themeOrange)
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

            Section("Extensions") {
                Text("Named extensions from ~/.pi/agent/extensions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isLoadingExtensions && availableExtensions.isEmpty {
                        Text("Loading available extensions…")
                            .foregroundStyle(.secondary)
                    } else if availableExtensions.isEmpty {
                        Text("No discoverable extensions found.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(availableExtensions) { ext in
                            Button {
                                toggleExtension(ext.name)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ext.name)
                                            .font(.body)
                                        Text(ext.kind)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Image(systemName: selectedExtensionSet.contains(ext.name) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedExtensionSet.contains(ext.name) ? .themeBlue : .secondary)
                                        .imageScale(.large)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }

                    if !manualExtensionNames.isEmpty {
                        Text("Manual: \(manualExtensionNames.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    TextField("Selected names (comma separated)", text: $extensionNames)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))

                    if let extensionsError {
                        Text("Extensions API: \(extensionsError)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
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
                    .frame(minHeight: 120)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.themeFg)
                    .tint(.themeBlue)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.themeBgDark)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.themeComment.opacity(0.25), lineWidth: 1)
                    )

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
        .task {
            await loadModels()
            await loadExtensions()
        }
    }

    private func parseExtensionNames(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { value in
                if seen.contains(value) { return false }
                seen.insert(value)
                return true
            }
    }

    private var selectedExtensionNames: [String] {
        parseExtensionNames(extensionNames)
    }

    private var selectedExtensionSet: Set<String> {
        Set(selectedExtensionNames)
    }

    private func setSelectedExtensionNames(_ names: [String]) {
        extensionNames = names.joined(separator: ", ")
    }

    private func toggleExtension(_ name: String) {
        var names = selectedExtensionNames
        if let idx = names.firstIndex(of: name) {
            names.remove(at: idx)
        } else {
            names.append(name)
        }
        setSelectedExtensionNames(names)
    }

    private var discoveredExtensionsSet: Set<String> {
        Set(availableExtensions.map(\.name))
    }

    private var manualExtensionNames: [String] {
        selectedExtensionNames.filter { !discoveredExtensionsSet.contains($0) }
    }

    private func loadFromWorkspace() {
        name = workspace.name
        description = workspace.description ?? ""
        icon = workspace.icon ?? ""
        selectedSkills = Set(workspace.skills)
        runtime = workspace.runtime
        hostMount = workspace.hostMount ?? ""
        systemPrompt = workspace.systemPrompt ?? ""
        memoryEnabled = workspace.memoryEnabled ?? false
        memoryNamespace = workspace.memoryNamespace ?? ""
        extensionNames = (workspace.extensions ?? []).joined(separator: ", ")
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

    private func loadExtensions() async {
        guard let api = connection.apiClient else { return }
        isLoadingExtensions = true
        extensionsError = nil

        defer { isLoadingExtensions = false }

        do {
            availableExtensions = try await api.listExtensions()
        } catch {
            extensionsError = error.localizedDescription
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
            systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
            hostMount: hostMount.isEmpty ? nil : hostMount,
            memoryEnabled: memoryEnabled,
            memoryNamespace: memoryNamespace.isEmpty ? nil : memoryNamespace,
            extensions: parseExtensionNames(extensionNames),
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
                        .foregroundStyle(isSelected ? .themeBlue : .secondary)
                        .imageScale(.large)
                }
            }
            .foregroundStyle(.primary)

            NavigationLink(value: SkillDetailDestination(skillName: skill.name)) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.themeComment)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(skill.name) details")
        }
    }
}
