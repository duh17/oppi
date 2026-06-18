import SwiftUI

/// Edit an existing workspace's configuration.
struct WorkspaceEditView: View {
    let workspace: Workspace
    private let previewAvailableExtensions: [ExtensionInfo]?
    private let previewAvailableModels: [ModelInfo]?
    private let onSaved: (() -> Void)?

    init(
        workspace: Workspace,
        previewAvailableExtensions: [ExtensionInfo]? = nil,
        previewAvailableModels: [ModelInfo]? = nil,
        onSaved: (() -> Void)? = nil
    ) {
        self.workspace = workspace
        self.previewAvailableExtensions = previewAvailableExtensions
        self.previewAvailableModels = previewAvailableModels
        self.onSaved = onSaved
    }

    @Environment(\.apiClient) private var apiClient
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var icon: String = ""
    @State private var hostMount: String = ""
    @State private var systemPrompt: String = ""
    @State private var gitStatusEnabled: Bool = true
    @State private var hostMountStatus: HostPathStatus?
    @State private var hostMountValidationMessage: String?
    @State private var isCheckingHostMount = false
    @State private var isCreatingHostDirectory = false
    @State private var hostPathPendingCreation: String?
    @State private var availableExtensions: [ExtensionInfo] = []
    @State private var availableSkills: [SkillInfo] = []
    @State private var isLoadingExtensions = false
    @State private var isLoadingSkills = false
    @State private var extensionsError: String?
    @State private var skillsError: String?
    @State private var togglingResourceKeys: Set<String> = []
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
        if !availableSkills.isEmpty { return availableSkills }
        guard let activeServerId,
              let scoped = workspaceStore.skillsByServer[activeServerId] else {
            return []
        }
        return scoped
    }

    private var workspaceForEditing: Workspace {
        guard let activeServerId,
              let scoped = workspaceStore.workspacesByServer[activeServerId]?
                .first(where: { $0.id == workspace.id }) else {
            return workspace
        }

        return scoped
    }

    private var oppiExtensions: [ExtensionInfo] {
        availableExtensions.filter(\.isOppi)
    }

    private var piExtensions: [ExtensionInfo] {
        availableExtensions.filter { !$0.isOppi }
    }

    private var enabledSkills: [SkillInfo] {
        skills.filter(\.enabled)
    }

    private var disabledSkills: [SkillInfo] {
        skills.filter { !$0.enabled }
    }

    private var enabledPiExtensions: [ExtensionInfo] {
        piExtensions.filter(\.enabled)
    }

    private var disabledPiExtensions: [ExtensionInfo] {
        piExtensions.filter { !$0.enabled }
    }

    private var trimmedHostMount: String {
        hostMount.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        if name.isEmpty || isSaving { return false }
        if !trimmedHostMount.isEmpty {
            guard let hostMountStatus, hostMountStatus.path == trimmedHostMount else { return false }
            if !hostMountStatus.isValidWorkspaceDirectory { return false }
        }
        return true
    }

    private var hostMountLookupKey: String {
        "\(workspace.id)|\(trimmedHostMount)"
    }

    private var systemPromptEditorSummary: String {
        if systemPrompt.isEmpty {
            return "No instructions"
        }

        let lineCount = systemPrompt.split(separator: "\n", omittingEmptySubsequences: false).count
        return "\(lineCount)L • \(systemPrompt.count)C"
    }

    private var systemPromptPreviewText: String {
        if systemPrompt.isEmpty {
            return "No workspace instructions added. Pi’s base prompt will be used as-is."
        }

        return systemPrompt
    }

    var body: some View {
        List {
            Section("Details") {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("workspace.edit.name")
                TextField("Description", text: $description)
                    .accessibilityIdentifier("workspace.edit.description")
                TextField("Icon (SF Symbol or emoji)", text: $icon)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("workspace.edit.icon")
            }
            .selectionDisabled()

            Section("Workspace Folder") {
                TextField("~/workspace/project (must exist)", text: $hostMount)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("workspace.edit.hostMount")

                Text("Leave empty to use the server home folder. If the folder doesn’t exist, use Create this folder below; Oppi asks before creating one directory.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)

                hostMountValidationView
            }
            .selectionDisabled()

            Section("Workspace Changes") {
                Toggle("Show workspace changes in chat", isOn: $gitStatusEnabled)

                Text("Shows branch, changed files, and line stats above the chat.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
            .selectionDisabled()

            Section("Workspace Instructions") {
                Button {
                    isShowingSystemPromptEditor = true
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("Edit Instructions")
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

                Text("Added after Pi’s base prompt for every session in this workspace.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
            .selectionDisabled()

            Section {
                if isLoadingSkills && skills.isEmpty {
                    Text("Loading skills…")
                        .foregroundStyle(.themeComment)
                        .selectionDisabled()
                } else if skills.isEmpty {
                    Text("No Pi skills discovered for this folder yet.")
                        .foregroundStyle(.themeComment)
                        .selectionDisabled()
                } else {
                    ForEach(enabledSkills) { skill in
                        skillRow(skill)
                    }
                    ForEach(disabledSkills) { skill in
                        skillRow(skill)
                    }
                }

                if let skillsError {
                    Text(skillsError)
                        .font(.caption2)
                        .foregroundStyle(.themeOrange)
                        .selectionDisabled()
                }
            } header: {
                Text("Pi Skills")
            } footer: {
                Text("Toggles write Pi user/project settings for this folder. Use reload in an active session to apply changes immediately.")
            }

            extensionsSection

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
                        Text("One host pattern per line. Leave empty to deny all network. Use * to allow all, matching Gondolin’s default.")
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
        .iPadReadableContent(maxWidth: IPadReadableContentWidth.form)
        .themedListSurface()
        .navigationTitle("Edit Workspace")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(!canSave)
                .accessibilityIdentifier("workspace.edit.save")
            }
        }
        .navigationDestination(item: $selectedSkillDetail) { dest in
            SkillDetailView(skillName: dest.skillName, cwd: dest.cwd)
        }
        .navigationDestination(isPresented: $isShowingSystemPromptEditor) {
            WorkspaceSystemPromptEditorView(systemPrompt: $systemPrompt)
        }
        .navigationDestination(for: SkillFileDestination.self) { dest in
            SkillFileView(skillName: dest.skillName, filePath: dest.filePath, cwd: dest.cwd)
        }
        .onAppear {
            guard loadedWorkspaceID != workspace.id else { return }
            loadFromWorkspace()
            loadedWorkspaceID = workspace.id
        }
        .task(id: trimmedHostMount) {
            await loadSkills()
            await loadExtensions()
        }
        .task {
            await loadModels()
        }
        .task(id: hostMountLookupKey) {
            await validateHostMount()
        }
    }

    @ViewBuilder
    private var hostMountValidationView: some View {
        if !trimmedHostMount.isEmpty {
            if isCheckingHostMount {
                Label("Checking folder…", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            } else if let hostMountStatus, hostMountStatus.path == trimmedHostMount,
                      hostMountStatus.issue == "missing" {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Folder doesn’t exist", systemImage: "folder.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.themeComment)

                    if hostPathPendingCreation == trimmedHostMount {
                        Text("Create this one folder on the server? The parent folder must already exist.")
                            .font(.caption)
                            .foregroundStyle(.themeComment)

                        if isCreatingHostDirectory {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Creating folder…")
                                    .font(.caption)
                                    .foregroundStyle(.themeComment)
                            }
                        } else {
                            HStack(spacing: 8) {
                                Button {
                                    Task { await createHostDirectoryFromPendingPath() }
                                } label: {
                                    Label("Create Folder", systemImage: "plus")
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("workspace.edit.confirmCreateFolder")

                                Button("Cancel") {
                                    hostPathPendingCreation = nil
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("workspace.edit.cancelCreateFolder")
                            }
                            .controlSize(.small)
                        }
                    } else {
                        Button {
                            hostPathPendingCreation = trimmedHostMount
                        } label: {
                            Label("Create this folder", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("workspace.edit.createMissingFolder")
                        .disabled(isCreatingHostDirectory)
                    }
                }
            } else if let hostMountValidationMessage {
                Label(hostMountValidationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.themeRed)
            } else if let hostMountStatus, hostMountStatus.path == trimmedHostMount,
                      hostMountStatus.isValidWorkspaceDirectory {
                Label("Folder exists", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.themeGreen)
            }
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
                    ForEach(enabledPiExtensions) { ext in
                        extensionRow(ext)
                    }
                    ForEach(disabledPiExtensions) { ext in
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
                Text("Toggles write Pi user/project settings for this folder. Use reload in an active session to apply changes immediately.")
            }
        }
    }

    @ViewBuilder
    private func extensionRow(_ ext: ExtensionInfo) -> some View {
        ExtensionSettingsRow(
            extensionInfo: ext,
            isToggling: togglingResourceKeys.contains(resourceKey(type: "extensions", path: ext.path)),
            onToggle: { togglePiResource(type: "extensions", path: ext.path, enabled: !ext.enabled) }
        )
    }

    @ViewBuilder
    private func skillRow(_ skill: SkillInfo) -> some View {
        SkillSettingsRow(
            skill: skill,
            isToggling: togglingResourceKeys.contains(resourceKey(type: "skills", path: skill.path)),
            onToggle: { togglePiResource(type: "skills", path: skill.path, enabled: !skill.enabled) },
            onShowDetail: {
                selectedSkillDetail = SkillDetailDestination(skillName: skill.name, cwd: trimmedHostMount.isEmpty ? nil : trimmedHostMount)
            }
        )
    }

    private func resourceKey(type: String, path: String) -> String {
        "\(type)|\(path)"
    }

    private func togglePiResource(type: String, path: String, enabled: Bool) {
        let key = resourceKey(type: type, path: path)
        guard !togglingResourceKeys.contains(key) else { return }
        togglingResourceKeys.insert(key)
        skillsError = nil
        extensionsError = nil

        Task { @MainActor in
            defer { togglingResourceKeys.remove(key) }
            guard let api = apiClient else {
                if type == "skills" {
                    skillsError = "Server is offline"
                } else {
                    extensionsError = "Server is offline"
                }
                return
            }

            do {
                let cwd = trimmedHostMount.isEmpty ? nil : trimmedHostMount
                try await api.setPiResourceEnabled(type: type, path: path, cwd: cwd, enabled: enabled)
                if type == "skills" {
                    await loadSkills()
                } else {
                    await loadExtensions()
                }
            } catch {
                if type == "skills" {
                    skillsError = error.localizedDescription
                } else {
                    extensionsError = error.localizedDescription
                }
            }
        }
    }

    private func nullableJSONString(_ value: String) -> JSONValue {
        value.isEmpty ? .null : .string(value)
    }

    private func loadFromWorkspace() {
        let source = workspaceForEditing

        name = source.name
        description = source.description ?? ""
        icon = source.icon ?? ""
        hostMount = source.hostMount ?? ""
        hostMountStatus = nil
        hostMountValidationMessage = nil
        hostPathPendingCreation = nil
        isCheckingHostMount = false
        isCreatingHostDirectory = false
        systemPrompt = source.systemPrompt ?? ""
        gitStatusEnabled = source.gitStatusEnabled ?? true
        runtime = source.runtime
        allowedHostsText = source.sandboxConfig?.allowedHosts?.joined(separator: "\n") ?? "*"
    }

    @MainActor
    private func validateHostMount() async {
        let current = trimmedHostMount
        if let pending = hostPathPendingCreation, pending != current {
            hostPathPendingCreation = nil
        }
        guard !current.isEmpty else {
            hostMountStatus = nil
            hostMountValidationMessage = nil
            hostPathPendingCreation = nil
            isCheckingHostMount = false
            return
        }

        guard let api = apiClient else {
            hostMountStatus = nil
            hostMountValidationMessage = "Cannot check path while the server is offline"
            isCheckingHostMount = false
            return
        }

        isCheckingHostMount = true
        hostMountValidationMessage = nil
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard current == trimmedHostMount else { return }

        do {
            let status = try await api.getHostPathStatus(path: current)
            guard current == trimmedHostMount else { return }
            hostMountStatus = status
            hostMountValidationMessage = status.isValidWorkspaceDirectory
                ? nil
                : status.userMessage
        } catch {
            guard current == trimmedHostMount else { return }
            hostMountStatus = nil
            hostMountValidationMessage = "Could not check path: \(error.localizedDescription)"
        }

        if current == trimmedHostMount {
            isCheckingHostMount = false
        }
    }

    @MainActor
    private func createHostDirectoryFromPendingPath() async {
        guard let path = hostPathPendingCreation else { return }
        guard path == trimmedHostMount else {
            hostPathPendingCreation = nil
            return
        }
        guard let api = apiClient else {
            error = "Server is offline"
            hostPathPendingCreation = nil
            return
        }

        isCreatingHostDirectory = true
        error = nil
        defer {
            isCreatingHostDirectory = false
            hostPathPendingCreation = nil
        }

        do {
            let result = try await api.createHostPath(path: path)
            hostMount = result.status.path.isEmpty ? path : result.status.path
            hostMountStatus = result.status
            hostMountValidationMessage = result.status.isValidWorkspaceDirectory
                ? nil
                : result.status.userMessage
            isCheckingHostMount = false
        } catch {
            self.error = "Create folder failed: \(error.localizedDescription)"
        }
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

    private func loadSkills() async {
        guard let api = apiClient else { return }

        isLoadingSkills = true
        skillsError = nil
        defer { isLoadingSkills = false }

        do {
            let cwd = hostMount.trimmingCharacters(in: .whitespacesAndNewlines)
            availableSkills = try await api.listSkills(cwd: cwd.isEmpty ? nil : cwd)
        } catch {
            skillsError = error.localizedDescription
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

        let trimmedHostMount = hostMount.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHostMount.isEmpty {
            guard let hostMountStatus, hostMountStatus.path == trimmedHostMount,
                  hostMountStatus.isValidWorkspaceDirectory else {
                error = hostMountValidationMessage ?? "Folder doesn’t exist"
                return
            }
        }

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
            systemPrompt: nullableJSONString(systemPrompt),
            systemPromptMode: .append,
            hostMount: nullableJSONString(trimmedHostMount),
            gitStatusEnabled: gitStatusEnabled,
            sandboxConfig: sandboxConfigValue
        )

        do {
            let updated = try await api.updateWorkspace(id: workspace.id, request)
            if let activeServerId {
                workspaceStore.upsert(updated, serverId: activeServerId)
            }
            onSaved?()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isSaving = false
        }
    }
}

// MARK: - Workspace Instructions Editor

private struct WorkspaceSystemPromptEditorView: View {
    @Binding var systemPrompt: String

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Workspace instructions")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)

                Text("Added after Pi’s base prompt for every session in this workspace.")
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
                .autocorrectionDisabled(false)
                .textInputAutocapitalization(.sentences)
                .writingToolsBehavior(.complete)
                .writingToolsAffordanceVisibility(.visible)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .themedTextInputCard(strokeOpacity: 0.25)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.themeBg.ignoresSafeArea())
        .navigationTitle("Workspace Instructions")
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
                Text("Added after Pi prompt")
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

private struct ExtensionSettingsRow: View {
    let extensionInfo: ExtensionInfo
    let isToggling: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(extensionInfo.name)
                    .font(.body)
                    .foregroundStyle(extensionInfo.enabled ? .themeFg : .themeComment)

                Text(extensionInfo.subtitle)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.themeComment)
            }

            Spacer(minLength: 12)

            if isToggling {
                ProgressView()
                    .controlSize(.small)
            } else {
                WorkspaceSelectionButton(
                    isSelected: extensionInfo.enabled,
                    accessibilityLabel: extensionInfo.enabled
                        ? "Disable \(extensionInfo.name) extension in Pi settings"
                        : "Enable \(extensionInfo.name) extension in Pi settings",
                    action: onToggle
                )
            }
        }
    }
}

private struct SkillSettingsRow: View {
    let skill: SkillInfo
    let isToggling: Bool
    let onToggle: () -> Void
    let onShowDetail: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.body)
                    .foregroundStyle(skill.enabled ? .themeFg : .themeComment)

                Text(skill.description)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            if isToggling {
                ProgressView()
                    .controlSize(.small)
            } else {
                WorkspaceSelectionButton(
                    isSelected: skill.enabled,
                    accessibilityLabel: skill.enabled
                        ? "Disable \(skill.name) skill in Pi settings"
                        : "Enable \(skill.name) skill in Pi settings",
                    action: onToggle
                )
            }

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
