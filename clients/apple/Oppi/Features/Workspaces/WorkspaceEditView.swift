import SwiftUI

/// Edit an existing workspace's configuration.
struct WorkspaceEditView: View {
    private enum SelectableRowID: Hashable {
        case skill(String)
        case extensionName(String)
    }

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
    @State private var systemPromptMode: WorkspaceSystemPromptMode = .append
    @State private var gitStatusEnabled: Bool = true
    @State private var extensionNames: String = ""
    @State private var availableExtensions: [ExtensionInfo] = []
    @State private var isLoadingExtensions = false
    @State private var extensionsError: String?
    @State private var isSaving = false
    @State private var error: String?
    @State private var availableModels: [ModelInfo] = []
    @State private var selectedSkillDetail: SkillDetailDestination?
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

    private var selectableRowSelection: Binding<Set<SelectableRowID>> {
        Binding(
            get: {
                let visibleSkillNames = selectedSkills.intersection(Set(skills.map(\.name)))
                let visibleExtensionNames = selectedExtensionSet.intersection(availableExtensionNameSet)
                return Set(visibleSkillNames.map { SelectableRowID.skill($0) })
                    .union(visibleExtensionNames.map { SelectableRowID.extensionName($0) })
            },
            set: { newSelection in
                let visibleSkillNames = Set(skills.map(\.name))
                let hiddenSkillNames = selectedSkills.subtracting(visibleSkillNames)
                let nextVisibleSkillNames = Set(newSelection.compactMap { row -> String? in
                    if case let .skill(name) = row {
                        return name
                    }
                    return nil
                })
                selectedSkills = hiddenSkillNames.union(nextVisibleSkillNames)

                let currentExtensionNames = parseUniqueNames(extensionNames)
                let hiddenExtensionNames = currentExtensionNames.filter { !availableExtensionNameSet.contains($0) }
                let nextVisibleExtensionNames = Set(newSelection.compactMap { row -> String? in
                    if case let .extensionName(name) = row {
                        return name
                    }
                    return nil
                })
                let orderedVisibleExtensionNames = availableExtensions
                    .map(\.name)
                    .filter(nextVisibleExtensionNames.contains)
                setSelectedExtensionNames(orderedVisibleExtensionNames + hiddenExtensionNames)
            }
        )
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
        List(selection: selectableRowSelection) {
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
        .environment(\.editMode, .constant(.active))
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
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ext.name)
                    .font(.body)
                    .foregroundStyle(.themeFg)
                Text(ext.subtitle)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.themeComment)
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .tag(SelectableRowID.extensionName(ext.name))
    }

    @ViewBuilder
    private func skillRow(_ skill: SkillInfo) -> some View {
        SkillSelectionRow(
            skill: skill,
            onShowDetail: {
                selectedSkillDetail = SkillDetailDestination(skillName: skill.name)
            }
        )
        .tag(SelectableRowID.skill(skill.name))
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
        systemPromptMode = source.systemPromptMode
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
            systemPromptMode: systemPromptMode,
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

// MARK: - Skill Selection Row

private struct SkillSelectionRow: View {
    let skill: SkillInfo
    let onShowDetail: () -> Void

    var body: some View {
        HStack(spacing: 12) {
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

            Button(action: onShowDetail) {
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundStyle(.themeComment)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(skill.name) details")
        }
        .contentShape(Rectangle())
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
