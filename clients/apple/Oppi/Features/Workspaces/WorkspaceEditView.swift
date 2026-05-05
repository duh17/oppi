import SwiftUI

/// Edit an existing workspace's configuration.
struct WorkspaceEditView: View {
    let workspace: Workspace
    private let previewAvailableExtensions: [ExtensionInfo]?
    private let previewAvailableModels: [ModelInfo]?

    init(
        workspace: Workspace,
        previewAvailableExtensions: [ExtensionInfo]? = nil,
        previewAvailableModels: [ModelInfo]? = nil
    ) {
        self.workspace = workspace
        self.previewAvailableExtensions = previewAvailableExtensions
        self.previewAvailableModels = previewAvailableModels
    }

    @Environment(\.apiClient) private var apiClient
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var icon: String = ""
    @State private var selectedSkills: Set<String> = []
    @State private var hostMount: String = ""
    @State private var systemPrompt: String = ""
    @State private var gitStatusEnabled: Bool = true
    @State private var extensionNames: String = ""
    @State private var availableExtensions: [ExtensionInfo] = []
    @State private var isLoadingExtensions = false
    @State private var extensionsError: String?
    @State private var isSaving = false
    @State private var error: String?
    @State private var availableModels: [ModelInfo] = []
    @State private var selectedSkillDetail: SkillDetailDestination?
    @State private var isShowingSystemPromptEditor = false
    @State private var runtime: WorkspaceRuntime?
    @State private var allowedHostsText: String = ""
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

    private var selectedExtensionSet: Set<String> {
        Set(parseUniqueNames(extensionNames))
    }

    private var availableExtensionNameSet: Set<String> {
        Set(availableExtensions.map(\.name))
    }

    private var oppiExtensions: [ExtensionInfo] {
        availableExtensions.filter(\.isOppi)
    }

    private var piExtensions: [ExtensionInfo] {
        availableExtensions.filter { !$0.isOppi }
    }

    private var systemPromptEditorSummary: String {
        if systemPrompt.isEmpty {
            return "No custom prompt"
        }

        let lineCount = systemPrompt.split(separator: "\n", omittingEmptySubsequences: false).count
        return "\(lineCount)L • \(systemPrompt.count)C"
    }

    private var systemPromptPreviewText: String {
        if systemPrompt.isEmpty {
            return "No workspace prompt yet. Pi’s base prompt will be used as-is."
        }

        return systemPrompt
    }

    var body: some View {
        List {
            Section("System Prompt") {
                Button {
                    isShowingSystemPromptEditor = true
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("Edit workspace prompt")
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

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.themeComment)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("Add workspace-specific instructions after Pi’s base prompt.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
            .selectionDisabled()

            Section("Identity") {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                TextField("Description", text: $description)
                TextField("Icon (SF Symbol or emoji)", text: $icon)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .selectionDisabled()

            extensionsSection

            if skills.isEmpty {
                Section("Skills") {
                    Text("Loading skills…")
                        .foregroundStyle(.themeComment)
                }
                .selectionDisabled()
            } else {
                Section("Enabled Skills") {
                    if enabledSkills.isEmpty {
                        Text("No skills enabled")
                            .foregroundStyle(.themeComment)
                            .selectionDisabled()
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
                            .selectionDisabled()
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
            .selectionDisabled()

            Section("Git Status") {
                Toggle("Show git status bar", isOn: $gitStatusEnabled)

                Text("Shows branch, dirty files, and change stats in chat view")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
            .selectionDisabled()

            if runtime == .sandbox {
                Section {
                    Text("This workspace runs in a sandboxed micro-VM.")
                        .font(.caption)
                        .foregroundStyle(.themeComment)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Allowed Hosts")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.themeComment)
                        TextEditor(text: $allowedHostsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 80)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .scrollContentBackground(.hidden)
                            .themedTextInputCard()
                        Text("One host pattern per line. Use * to allow all.")
                            .font(.caption2)
                            .foregroundStyle(.themeComment)
                    }
                } header: {
                    Text("Sandbox")
                }
                .selectionDisabled()
            }

            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.themeRed)
                        .font(.caption)
                }
                .selectionDisabled()
            }
        }
        .listStyle(.insetGrouped)
        .themedListSurface()
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
        .navigationDestination(isPresented: $isShowingSystemPromptEditor) {
            WorkspaceSystemPromptEditorView(systemPrompt: $systemPrompt)
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
    private var extensionsSection: some View {
        if isLoadingExtensions && availableExtensions.isEmpty {
            Section("Extensions") {
                Text("Loading extensions\u{2026}")
                    .foregroundStyle(.themeComment)
            }
            .selectionDisabled()
        } else {
            if !oppiExtensions.isEmpty {
                Section("Oppi Extensions") {
                    ForEach(oppiExtensions) { ext in
                        extensionRow(ext)
                    }
                }
            }

            Section {
                if piExtensions.isEmpty {
                    Text("No pi extensions found.")
                        .foregroundStyle(.themeComment)
                        .selectionDisabled()
                } else {
                    ForEach(piExtensions) { ext in
                        extensionRow(ext)
                    }
                }

                if let extensionsError {
                    Text(extensionsError)
                        .font(.caption2)
                        .foregroundStyle(.themeOrange)
                        .selectionDisabled()
                }
            } header: {
                Text("Pi Extensions")
            } footer: {
                Text("From pi extension dirs and installed packages\(hostMount.isEmpty ? "" : " (including project .pi/extensions)")")
            }
        }
    }

    @ViewBuilder
    private func extensionRow(_ ext: ExtensionInfo) -> some View {
        ExtensionSelectionRow(
            extensionInfo: ext,
            isSelected: selectedExtensionSet.contains(ext.name),
            onToggle: {
                toggleExtension(ext.name)
            }
        )
    }

    @ViewBuilder
    private func skillRow(_ skill: SkillInfo) -> some View {
        SkillSelectionRow(
            skill: skill,
            isSelected: selectedSkills.contains(skill.name),
            onToggle: {
                toggleSkill(skill.name)
            },
            onShowDetail: {
                selectedSkillDetail = SkillDetailDestination(skillName: skill.name)
            }
        )
    }

    private func toggleSkill(_ skillName: String) {
        if selectedSkills.contains(skillName) {
            selectedSkills.remove(skillName)
        } else {
            selectedSkills.insert(skillName)
        }
    }

    private func toggleExtension(_ name: String) {
        let currentExtensionNames = parseUniqueNames(extensionNames)
        let hiddenExtensionNames = currentExtensionNames.filter { !availableExtensionNameSet.contains($0) }
        var visibleExtensionNames = Set(currentExtensionNames.filter { availableExtensionNameSet.contains($0) })

        if visibleExtensionNames.contains(name) {
            visibleExtensionNames.remove(name)
        } else {
            visibleExtensionNames.insert(name)
        }

        let orderedVisibleExtensionNames = availableExtensions
            .map(\.name)
            .filter(visibleExtensionNames.contains)
        setSelectedExtensionNames(orderedVisibleExtensionNames + hiddenExtensionNames)
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
        gitStatusEnabled = source.gitStatusEnabled ?? true
        setSelectedExtensionNames(source.extensions ?? [])
        runtime = source.runtime
        allowedHostsText = source.sandboxConfig?.allowedHosts?.joined(separator: "\n") ?? "*"
    }

    private func loadModels() async {
        guard let api = apiClient else {
            if let previewAvailableModels {
                availableModels = previewAvailableModels
            }
            return
        }

        do {
            availableModels = try await api.listModels()
        } catch {
            // Fall back to manual entry
        }
    }

    private func loadExtensions() async {
        guard let api = apiClient else {
            if let previewAvailableExtensions {
                availableExtensions = previewAvailableExtensions
            }
            return
        }

        isLoadingExtensions = true
        extensionsError = nil
        defer { isLoadingExtensions = false }

        do {
            let cwd = hostMount.trimmingCharacters(in: .whitespacesAndNewlines)
            availableExtensions = try await api.listExtensions(cwd: cwd.isEmpty ? nil : cwd)
        } catch {
            extensionsError = error.localizedDescription
        }
    }

    private func save() async {
        guard let api = apiClient else { return }

        isSaving = true
        error = nil

        let sandboxConfigValue: JSONValue? = runtime == .sandbox ? {
            let hosts = allowedHostsText
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return .object(["allowedHosts": .array(hosts.map { .string($0) })])
        }() : nil

        let request = UpdateWorkspaceRequest(
            name: name,
            description: nullableJSONString(description),
            icon: nullableJSONString(icon),
            skills: validSelectedSkillNames(),
            systemPrompt: nullableJSONString(systemPrompt),
            systemPromptMode: .append,
            hostMount: nullableJSONString(hostMount),
            gitStatusEnabled: gitStatusEnabled,
            extensions: parseUniqueNames(extensionNames),
            sandboxConfig: sandboxConfigValue
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
    @Binding var systemPrompt: String

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Workspace instructions")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)

                Text("Add workspace-specific instructions after Pi’s base prompt.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
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
                .themedTextInputCard(strokeOpacity: 0.25)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.themeBg.ignoresSafeArea())
        .navigationTitle("Workspace Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
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
                Text("Appended prompt")
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
    }
}

// MARK: - Selection Rows

private struct ExtensionSelectionRow: View {
    let extensionInfo: ExtensionInfo
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(extensionInfo.name)
                    .font(.body)
                    .foregroundStyle(.themeFg)

                Text(extensionInfo.subtitle)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.themeComment)
            }

            Spacer(minLength: 12)

            WorkspaceSelectionButton(
                isSelected: isSelected,
                accessibilityLabel: isSelected
                    ? "Disable \(extensionInfo.name) extension"
                    : "Enable \(extensionInfo.name) extension",
                action: onToggle
            )
        }
    }
}

private struct SkillSelectionRow: View {
    let skill: SkillInfo
    let isSelected: Bool
    let onToggle: () -> Void
    let onShowDetail: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.body)
                    .foregroundStyle(.themeFg)

                Text(skill.description)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            WorkspaceSelectionButton(
                isSelected: isSelected,
                accessibilityLabel: isSelected
                    ? "Disable \(skill.name) skill"
                    : "Enable \(skill.name) skill",
                action: onToggle
            )

            Button(action: onShowDetail) {
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundStyle(.themeComment)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(skill.name) details")
        }
    }
}

