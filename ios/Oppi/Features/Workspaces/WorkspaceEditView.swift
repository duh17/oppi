import SwiftUI

/// Edit an existing workspace's configuration.
struct WorkspaceEditView: View {
    let workspace: Workspace

    @Environment(\.apiClient) private var apiClient
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var icon: String = ""
    @State private var selectedSkills: Set<String> = []
    @State private var hostMount: String = ""
    @State private var systemPrompt: String = ""
    @State private var systemPromptMode: WorkspaceSystemPromptMode = .append
    @State private var gitStatusEnabled: Bool = true
    @State private var extensionNames: String = ""
    @State private var availableExtensions: [ExtensionInfo] = []
    @State private var isLoadingExtensions = false
    @State private var extensionsError: String?
    @State private var defaultModel: String = ""
    @State private var isSaving = false
    @State private var error: String?
    @State private var availableModels: [ModelInfo] = []
    @State private var selectedSkillDetail: SkillDetailDestination?
    @State private var loadedWorkspaceID: String?

    private var activeServerId: String? {
        workspaceStore.activeServerId
    }

    private var skills: [SkillInfo] {
        guard let activeServerId,
              let scoped = workspaceStore.skillsByServer[activeServerId] else {
            return []
        }
        return scoped
    }

    private var enabledSkills: [SkillInfo] {
        skills.filter { selectedSkills.contains($0.name) }
    }

    private var disabledSkills: [SkillInfo] {
        skills.filter { !selectedSkills.contains($0.name) }
    }

    private var workspaceForEditing: Workspace {
        guard let activeServerId,
              let scoped = workspaceStore.workspacesByServer[activeServerId]?
                .first(where: { $0.id == workspace.id }) else {
            return workspace
        }

        return scoped
    }

    private var discoveredExtensions: Set<String> {
        Set(availableExtensions.map(\.name))
    }

    private var selectedExtensionNames: [String] {
        parseUniqueNames(extensionNames)
    }

    private var selectedExtensionSet: Set<String> {
        Set(selectedExtensionNames)
    }

    private var manualExtensionNames: [String] {
        selectedExtensionNames.filter { !discoveredExtensions.contains($0) }
    }

    private var systemPromptEditorSummary: String {
        if systemPrompt.isEmpty {
            return systemPromptMode == .append ? "No custom prompt" : "Using Pi base prompt"
        }

        let lineCount = systemPrompt.split(separator: "\n", omittingEmptySubsequences: false).count
        return "\(lineCount)L • \(systemPrompt.count)C"
    }

    private var systemPromptPreviewText: String {
        if systemPrompt.isEmpty {
            return systemPromptMode.emptyStateText
        }

        return systemPrompt
    }

    var body: some View {
        Form {
            Section("System Prompt") {
                Picker("Behavior", selection: $systemPromptMode) {
                    Text("Append").tag(WorkspaceSystemPromptMode.append)
                    Text("Replace").tag(WorkspaceSystemPromptMode.replace)
                }
                .pickerStyle(.segmented)

                NavigationLink {
                    WorkspaceSystemPromptEditorView(
                        workspaceId: workspace.id,
                        systemPrompt: $systemPrompt,
                        mode: systemPromptMode
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(systemPromptMode.editorLinkTitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.themeFg)

                            Spacer(minLength: 8)

                            Text(systemPromptEditorSummary)
                                .font(.caption.monospaced())
                                .foregroundStyle(.themeComment)
                        }

                        Text(systemPromptPreviewText)
                            .font(.caption.monospaced())
                            .foregroundStyle(systemPrompt.isEmpty ? .themeComment : .themeFg)
                            .lineLimit(6)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.vertical, 2)
                }
                .foregroundStyle(.themeFg)

                Text(systemPromptMode.detailText)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }

            Section("Identity") {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                TextField("Description", text: $description)
                TextField("Icon (SF Symbol or emoji)", text: $icon)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            if skills.isEmpty {
                Section("Skills") {
                    Text("Loading skills…")
                        .foregroundStyle(.themeComment)
                }
            } else {
                Section("Enabled Skills") {
                    if enabledSkills.isEmpty {
                        Text("No skills enabled")
                            .foregroundStyle(.themeComment)
                    } else {
                        ForEach(enabledSkills) { skill in
                            skillRow(skill)
                        }
                    }
                }

                Section("Disabled Skills") {
                    if disabledSkills.isEmpty {
                        Text("All skills enabled")
                            .foregroundStyle(.themeComment)
                    } else {
                        ForEach(disabledSkills) { skill in
                            skillRow(skill)
                        }
                    }
                }
            }

            Section("Host Working Directory") {
                TextField("~/workspace/project", text: $hostMount)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))

                if !hostMount.isEmpty {
                    Text("Host process current directory")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
            }

            Section("Git Status") {
                Toggle("Show git status bar", isOn: $gitStatusEnabled)

                Text("Shows branch, dirty files, and change stats in chat view")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }

            Section("Extensions") {
                Text("Named extensions from ~/.pi/agent/extensions.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)

                if isLoadingExtensions && availableExtensions.isEmpty {
                    Text("Loading available extensions…")
                        .foregroundStyle(.themeComment)
                } else if availableExtensions.isEmpty {
                    Text("No discoverable extensions found.")
                        .foregroundStyle(.themeComment)
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
                                        .foregroundStyle(.themeComment)
                                }

                                Spacer()

                                Image(systemName: selectedExtensionSet.contains(ext.name) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedExtensionSet.contains(ext.name) ? .themeBlue : .themeComment)
                                    .imageScale(.large)
                            }
                        }
                        .foregroundStyle(.themeFg)
                    }
                }

                if !manualExtensionNames.isEmpty {
                    Text("Manual: \(manualExtensionNames.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                }

                TextField("Selected names (comma separated)", text: $extensionNames)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))

                if let extensionsError {
                    Text("Extensions API: \(extensionsError)")
                        .font(.caption2)
                        .foregroundStyle(.themeOrange)
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
                    .foregroundStyle(.themeFg)
                }
            }

            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.themeRed)
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
        .navigationDestination(item: $selectedSkillDetail) { dest in
            SkillDetailView(skillName: dest.skillName)
        }
        .navigationDestination(for: SkillFileDestination.self) { dest in
            SkillFileView(skillName: dest.skillName, filePath: dest.filePath)
        }
        .onAppear {
            guard loadedWorkspaceID != workspace.id else { return }
            loadFromWorkspace()
            loadedWorkspaceID = workspace.id
        }
        .task {
            await loadModels()
            await loadExtensions()
        }
    }

    @ViewBuilder
    private func skillRow(_ skill: SkillInfo) -> some View {
        SkillToggleRow(
            skill: skill,
            isSelected: selectedSkills.contains(skill.name),
            onToggle: { selected in
                if selected {
                    selectedSkills.insert(skill.name)
                } else {
                    selectedSkills.remove(skill.name)
                }
            },
            onShowDetail: {
                selectedSkillDetail = SkillDetailDestination(skillName: skill.name)
            }
        )
    }

    private func parseUniqueNames(_ raw: String) -> [String] {
        var seen = Set<String>()

        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { value in
                if seen.contains(value) {
                    return false
                }

                seen.insert(value)
                return true
            }
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

    private func validSelectedSkillNames() -> [String] {
        let knownSkillNames = Set(skills.map(\.name))
        return Array(selectedSkills.intersection(knownSkillNames))
    }

    private func nullableJSONString(_ value: String) -> JSONValue {
        value.isEmpty ? .null : .string(value)
    }

    private func loadFromWorkspace() {
        let source = workspaceForEditing

        name = source.name
        description = source.description ?? ""
        icon = source.icon ?? ""
        selectedSkills = Set(source.skills)
        hostMount = source.hostMount ?? ""
        systemPrompt = source.systemPrompt ?? ""
        systemPromptMode = source.systemPromptMode
        gitStatusEnabled = source.gitStatusEnabled ?? true
        setSelectedExtensionNames(source.extensions ?? [])
        defaultModel = source.defaultModel ?? ""
    }

    private func loadModels() async {
        guard let api = apiClient else { return }
        do {
            availableModels = try await api.listModels()
        } catch {
            // Fall back to manual entry
        }
    }

    private func loadExtensions() async {
        guard let api = apiClient else { return }

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
        guard let api = apiClient else { return }

        isSaving = true
        error = nil

        let request = UpdateWorkspaceRequest(
            name: name,
            description: nullableJSONString(description),
            icon: nullableJSONString(icon),
            skills: validSelectedSkillNames(),
            systemPrompt: nullableJSONString(systemPrompt),
            systemPromptMode: systemPromptMode,
            hostMount: nullableJSONString(hostMount),
            gitStatusEnabled: gitStatusEnabled,
            extensions: selectedExtensionNames,
            defaultModel: nullableJSONString(defaultModel)
        )

        do {
            let updated = try await api.updateWorkspace(id: workspace.id, request)
            if let activeServerId {
                workspaceStore.upsert(updated, serverId: activeServerId)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isSaving = false
        }
    }
}

// MARK: - System Prompt Editor

private struct WorkspaceSystemPromptEditorView: View {
    let workspaceId: String
    @Binding var systemPrompt: String
    let mode: WorkspaceSystemPromptMode

    @Environment(\.apiClient) private var apiClient

    @State private var isLoadingBasePrompt = false
    @State private var basePromptError: String?
    @State private var loadedBasePromptCandidate: String?
    @State private var confirmReplacingPrompt = false

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(mode.editorCalloutTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)

                Text(mode.detailText)
                    .font(.caption)
                    .foregroundStyle(.themeComment)

                if mode == .replace {
                    Button {
                        Task { await loadBasePrompt() }
                    } label: {
                        HStack(spacing: 8) {
                            if isLoadingBasePrompt {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.down.doc")
                            }
                            Text(isLoadingBasePrompt ? "Loading Pi base prompt…" : "Load Pi base prompt")
                        }
                        .font(.caption.weight(.semibold))
                    }
                    .disabled(isLoadingBasePrompt)
                }

                if let basePromptError {
                    Text(basePromptError)
                        .font(.caption)
                        .foregroundStyle(.themeRed)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            TextEditor(text: $systemPrompt)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.themeFg)
                .tint(.themeBlue)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.themeBgDark)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.themeComment.opacity(0.25), lineWidth: 1)
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.themeBg.ignoresSafeArea())
        .navigationTitle(mode.editorTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if mode == .replace {
                        Button(isLoadingBasePrompt ? "Loading Pi Base Prompt…" : "Load Pi Base Prompt") {
                            Task { await loadBasePrompt() }
                        }
                        .disabled(isLoadingBasePrompt)
                    }

                    Button("Clear", role: .destructive) {
                        systemPrompt = ""
                    }
                    .disabled(systemPrompt.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(mode == .append ? "Appended prompt" : "Replacement prompt")
                    .font(.caption)
                    .foregroundStyle(.themeComment)

                Spacer()

                Text("\(systemPrompt.count) chars")
                    .font(.caption.monospaced())
                    .foregroundStyle(.themeComment)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
        .alert("Replace with Pi base prompt?", isPresented: $confirmReplacingPrompt) {
            Button("Cancel", role: .cancel) {
                loadedBasePromptCandidate = nil
            }
            Button("Replace", role: .destructive) {
                systemPrompt = loadedBasePromptCandidate ?? systemPrompt
                loadedBasePromptCandidate = nil
            }
        } message: {
            Text("This will replace the current prompt text in the editor.")
        }
    }

    private func loadBasePrompt() async {
        guard let api = apiClient else {
            basePromptError = "Server is offline — reconnecting in background"
            return
        }

        isLoadingBasePrompt = true
        basePromptError = nil
        defer { isLoadingBasePrompt = false }

        do {
            let basePrompt = try await api.getWorkspaceBaseSystemPrompt(id: workspaceId)
            if systemPrompt.isEmpty {
                systemPrompt = basePrompt
            } else {
                loadedBasePromptCandidate = basePrompt
                confirmReplacingPrompt = true
            }
        } catch {
            basePromptError = error.localizedDescription
        }
    }
}

// MARK: - Skill Toggle Row

private struct SkillToggleRow: View {
    let skill: SkillInfo
    let isSelected: Bool
    let onToggle: (Bool) -> Void
    let onShowDetail: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onToggle(!isSelected)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name)
                            .font(.body)

                        Text(skill.description)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                            .lineLimit(2)
                    }

                    Spacer()

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? .themeBlue : .themeComment)
                        .imageScale(.large)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.themeFg)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onShowDetail) {
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

private extension WorkspaceSystemPromptMode {
    var editorTitle: String {
        switch self {
        case .append:
            return "Appended Prompt"
        case .replace:
            return "Base Prompt Override"
        }
    }

    var editorLinkTitle: String {
        switch self {
        case .append:
            return "Edit appended prompt"
        case .replace:
            return "Edit replacement prompt"
        }
    }

    var editorCalloutTitle: String {
        switch self {
        case .append:
            return "Workspace instructions"
        case .replace:
            return "Pi base prompt override"
        }
    }

    var detailText: String {
        switch self {
        case .append:
            return "Add workspace-specific instructions after Pi’s base prompt."
        case .replace:
            return "Replace Pi’s base prompt for new sessions in this workspace. AGENTS files, skills, and runtime context still apply."
        }
    }

    var emptyStateText: String {
        switch self {
        case .append:
            return "No workspace prompt yet. Pi’s base prompt will be used as-is."
        case .replace:
            return "No replacement prompt saved. Load Pi’s base prompt as a starting point, then edit it here."
        }
    }
}
