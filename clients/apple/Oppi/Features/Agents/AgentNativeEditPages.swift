import SwiftUI

enum AgentToolSelectionMode: String, CaseIterable {
    case inherit
    case exact
    case existingPolicy

    var title: String {
        switch self {
        case .inherit: "Pi defaults"
        case .exact: "Choose tools"
        case .existingPolicy: "Existing policy"
        }
    }
}

struct AgentExtensionToolGroup: Identifiable {
    let id: String
    let name: String
    let tools: [ServerToolSummary]
}

enum AgentResourceCatalogState: Equatable {
    case unavailable
    case loading
    case neverLoaded
    case failed
    case cachedOffline
    case empty
    case content

    static func resolve(
        hasLoaded: Bool,
        isSyncing: Bool,
        lastSyncFailed: Bool,
        hasRows: Bool
    ) -> Self {
        guard hasLoaded else {
            if isSyncing { return .loading }
            return lastSyncFailed ? .failed : .neverLoaded
        }
        if lastSyncFailed { return .cachedOffline }
        return hasRows ? .content : .empty
    }

    static func isExactSelectionSaveAllowed(
        initialSelectionWasInherited: Bool,
        catalogState: Self
    ) -> Bool {
        !initialSelectionWasInherited || [.empty, .content, .cachedOffline].contains(catalogState)
    }

    func statusMessage(for resourceName: String) -> String? {
        switch self {
        case .unavailable:
            return "Connect to load the server's \(resourceName) catalog."
        case .loading:
            return "Loading \(resourceName.lowercased())…"
        case .neverLoaded:
            return "The \(resourceName) catalog has not loaded yet."
        case .failed:
            return "Could not load the \(resourceName.lowercased()) catalog. Existing selections are kept."
        case .cachedOffline:
            return "Showing cached \(resourceName.lowercased()) settings. Pull to retry."
        case .empty, .content:
            return nil
        }
    }
}

/// Edit Agent's SwiftUI pages. `AgentNativeEditViewController` pushes the
/// selection pages and presents the model picker through these; each page
/// reads and edits the shared draft, so its changes show on the editor.
@MainActor
enum AgentNativeEditPages {
    static func pushTools(_ draft: AgentNativeEditDraft, navigator: ScreenNavigator) {
        navigator.push { AgentNativeEditToolsPage(draft: draft) }
    }

    static func pushSkills(_ draft: AgentNativeEditDraft, navigator: ScreenNavigator) {
        navigator.push { AgentNativeEditSkillsPage(draft: draft) }
    }

    static func pushExtensions(_ draft: AgentNativeEditDraft, navigator: ScreenNavigator) {
        navigator.push { AgentNativeEditExtensionsPage(draft: draft) }
    }

    static func pushWorkspaces(_ draft: AgentNativeEditDraft, navigator: ScreenNavigator) {
        navigator.push { AgentNativeEditWorkspacesPage(draft: draft) }
    }

    /// The picker gets this editor's server explicitly.
    static func presentModelPicker(_ draft: AgentNativeEditDraft, apiClient: APIClient?, navigator: ScreenNavigator) {
        navigator.present(.sheet.inNavigation()) {
            ModelPickerSheet(currentModel: draft.model.managementNilIfBlank) { selected in
                draft.model = ModelSwitchPolicy.fullModelID(for: selected)
                AppPreferences.RecentModels.record(draft.model)
            }
            .environment(\.apiClient, apiClient)
            .environment(draft.connection.chatState)
        }
    }
}

private struct AgentNativeEditToolsPage: View {
    let draft: AgentNativeEditDraft

    var body: some View {
        @Bindable var draft = draft
        AgentToolSelectionView(
            mode: $draft.toolSelectionMode,
            selectedNames: $draft.selectedToolNames,
            builtInTools: draft.availableBuiltInTools,
            extensionGroups: draft.effectiveExtensionToolGroups,
            unavailableNames: draft.unavailableSelectedToolNames,
            defaultSelection: draft.effectiveDefaultToolNames,
            existingPolicySummary: draft.existingToolPolicySummary,
            isLoadingExtensionTools: draft.isLoadingExtensionTools
        )
    }
}

private struct AgentNativeEditSkillsPage: View {
    let draft: AgentNativeEditDraft

    var body: some View {
        @Bindable var draft = draft
        AgentSkillSelectionView(
            skills: draft.availableSkills,
            selectedPaths: $draft.selectedSkillPaths,
            catalogState: draft.skillCatalogState
        )
    }
}

private struct AgentNativeEditExtensionsPage: View {
    let draft: AgentNativeEditDraft

    var body: some View {
        @Bindable var draft = draft
        AgentExtensionSelectionView(
            extensions: draft.availableExtensions,
            selectedIds: $draft.selectedExtensionIds,
            catalogState: draft.extensionCatalogState
        )
    }
}

private struct AgentNativeEditWorkspacesPage: View {
    let draft: AgentNativeEditDraft

    var body: some View {
        @Bindable var draft = draft
        AgentWorkspaceSelectionView(
            workspaces: draft.workspaces,
            selectedIds: $draft.selectedAllowedWorkspaceIds,
            requiredRuntime: draft.requiredRuntime
        )
    }
}

private struct AgentWorkspaceSelectionView: View {
    let workspaces: [Workspace]
    @Binding var selectedIds: Set<String>
    let requiredRuntime: WorkspaceRuntime?

    private var displayedWorkspaces: [Workspace] {
        workspaces.filter { workspace in
            selectedIds.contains(workspace.id)
                || (requiredRuntime.map { $0 == (workspace.runtime ?? .host) } ?? true)
        }
    }

    var body: some View {
        List {
            if displayedWorkspaces.isEmpty {
                ContentUnavailableView(
                    "No Compatible Workspace",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Add a workspace that matches the required runtime, or choose Any runtime.")
                )
            } else {
                ForEach(displayedWorkspaces) { workspace in
                    let selected = selectedIds.contains(workspace.id)
                    Button {
                        if selected {
                            selectedIds.remove(workspace.id)
                        } else {
                            selectedIds.insert(workspace.id)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? .themeBlue : .themeComment)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(workspace.name)
                                    .foregroundStyle(.themeFg)
                                Text(workspaceRuntimeSummary(workspace))
                                    .font(.caption)
                                    .foregroundStyle(
                                        runtimeMatches(workspace) ? .themeComment : .themeOrange
                                    )
                            }
                            Spacer()
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                }
            }
        }
        .navigationTitle("Allowed Workspaces")
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
    }

    private func runtimeMatches(_ workspace: Workspace) -> Bool {
        requiredRuntime.map { $0 == (workspace.runtime ?? .host) } ?? true
    }

    private func workspaceRuntimeSummary(_ workspace: Workspace) -> String {
        let runtime = (workspace.runtime ?? .host).rawValue.capitalized
        return runtimeMatches(workspace) ? runtime : "\(runtime) · Does not match required runtime"
    }
}

struct AgentToolSelectionView: View {
    @Binding var mode: AgentToolSelectionMode
    @Binding var selectedNames: Set<String>
    let builtInTools: [ServerToolSummary]
    let extensionGroups: [AgentExtensionToolGroup]
    let unavailableNames: [String]
    let defaultSelection: Set<String>
    let existingPolicySummary: String?
    let isLoadingExtensionTools: Bool
    var title = "Agent Tools"
    var inheritFooter =
        "Uses Pi's default coding tools and tools from effective extensions. Future extension tools follow discovery automatically."
    var exactFooter =
        "Only selected names are available. This freezes both built-in and extension tools until the Agent is edited again."
    var showsExtensionTools = true
    /// Tools Pi extensions register off. Shown in every mode when a binding is supplied.
    var optionalTools: [ServerToolSummary] = []
    var selectedOptionalNames: Binding<Set<String>>?
    var optionalToolsFooter = ""

    private var selectableModes: [AgentToolSelectionMode] {
        existingPolicySummary == nil
            ? [.inherit, .exact]
            : [.inherit, .exact, .existingPolicy]
    }

    private var knownNames: Set<String> {
        Set(builtInTools.map(\.name) + extensionGroups.flatMap { $0.tools.map(\.name) })
    }

    private var modeBinding: Binding<AgentToolSelectionMode> {
        Binding(
            get: { mode },
            set: { newMode in
                if newMode == .exact, mode != .exact {
                    selectedNames = defaultSelection
                }
                mode = newMode
            }
        )
    }

    @ViewBuilder
    private var selectionMenuItems: some View {
        Button("Select All", systemImage: "checkmark.circle") { selectedNames.formUnion(knownNames) }
            .disabled(knownNames.isEmpty)
        Button("Select None", systemImage: "circle") { selectedNames.removeAll() }
    }

    var body: some View {
        List {
            Section {
                Picker("Selection", selection: modeBinding) {
                    ForEach(selectableModes, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .accessibilityIdentifier("agent.nativeEdit.toolMode")
            } footer: {
                switch mode {
                case .inherit:
                    Text(inheritFooter)
                case .exact:
                    Text(exactFooter)
                case .existingPolicy:
                    Text("This Agent uses \(existingPolicySummary ?? "an existing tool policy"). Choose another mode to replace it.")
                }
            }

            if mode == .exact {
                if builtInTools.isEmpty {
                    Section {
                        Label("Built-in tool catalog unavailable", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.themeOrange)
                    } footer: {
                        Text("Reconnect to a current server before creating a new exact selection.")
                    }
                } else {
                    Section("Built-in Pi Tools") {
                        ForEach(builtInTools) { tool in
                            toolButton(tool, source: nil, canAdd: true)
                        }
                    }
                }

                if showsExtensionTools, isLoadingExtensionTools {
                    Section {
                        ProgressView("Loading selected extension tools…")
                    }
                }

                if showsExtensionTools {
                    ForEach(extensionGroups) { group in
                        Section(group.name) {
                            ForEach(group.tools) { tool in
                                toolButton(tool, source: group.name, canAdd: true)
                            }
                        }
                    }
                }

                if !unavailableNames.isEmpty {
                    Section {
                        ForEach(unavailableNames, id: \.self) { name in
                            toolButton(
                                ServerToolSummary(
                                    name: name,
                                    description: "Not resolved by the server-global catalog"
                                ),
                                source: nil,
                                canAdd: false
                            )
                        }
                    } header: {
                        Text("Unavailable Selections")
                    } footer: {
                        Text("These saved names are preserved. Launch succeeds only in a workspace that supplies them; deselect a name to remove it.")
                    }
                }
            }

            if let selectedOptionalNames, !optionalTools.isEmpty {
                Section {
                    ForEach(optionalTools) { tool in
                        optionalToolToggle(tool, selection: selectedOptionalNames)
                    }
                } header: {
                    Text("Optional Pi Tools")
                } footer: {
                    Text(optionalToolsFooter)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
        .toolbar {
            if mode == .exact {
                if #available(iOS 27.0, *) {
                    ToolbarOverflowMenu { selectionMenuItems }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            selectionMenuItems
                        } label: {
                            Label("Tool selection actions", systemImage: "ellipsis.circle")
                        }
                    }
                }
            }
        }
    }

    private func optionalToolToggle(
        _ tool: ServerToolSummary,
        selection: Binding<Set<String>>
    ) -> some View {
        Toggle(isOn: Binding(
            get: { selection.wrappedValue.contains(tool.name) },
            set: { isOn in
                if isOn {
                    selection.wrappedValue.insert(tool.name)
                } else {
                    selection.wrappedValue.remove(tool.name)
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.name)
                    .foregroundStyle(.themeFg)
                if let description = tool.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .lineLimit(2)
                }
            }
        }
        .tint(.themeBlue)
        .frame(minHeight: 44)
        .accessibilityHint(tool.description ?? "")
        .accessibilityIdentifier("agent.nativeEdit.optionalTool.\(tool.name)")
    }

    private func toolButton(
        _ tool: ServerToolSummary,
        source: String?,
        canAdd: Bool
    ) -> some View {
        let isSelected = selectedNames.contains(tool.name)
        return Button {
            if isSelected {
                selectedNames.remove(tool.name)
            } else if canAdd {
                selectedNames.insert(tool.name)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .themeBlue : .themeComment)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.name)
                        .foregroundStyle(.themeFg)
                    if let description = tool.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                            .lineLimit(2)
                    }
                    if !canAdd {
                        Text("Unavailable")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.themeOrange)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelected && !canAdd)
        .accessibilityLabel(tool.name)
        .accessibilityHint(tool.description ?? "")
        .accessibilityValue([
            isSelected ? "Selected" : "Not selected",
            source,
            canAdd ? nil : "Unavailable",
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("agent.nativeEdit.tool.\(tool.name)")
    }
}

extension AgentToolSelectionView {
    init(
        mode: Binding<AgentToolSelectionMode>,
        selectedNames: Binding<Set<String>>,
        builtInTools: [ServerToolSummary],
        defaultSelection: Set<String>,
        optionalTools: [ServerToolSummary],
        selectedOptionalNames: Binding<Set<String>>,
        title: String,
        inheritFooter: String,
        exactFooter: String,
        optionalToolsFooter: String
    ) {
        self.init(
            mode: mode,
            selectedNames: selectedNames,
            builtInTools: builtInTools,
            extensionGroups: [],
            unavailableNames: [],
            defaultSelection: defaultSelection,
            existingPolicySummary: nil,
            isLoadingExtensionTools: false,
            title: title,
            inheritFooter: inheritFooter,
            exactFooter: exactFooter,
            showsExtensionTools: false,
            optionalTools: optionalTools,
            selectedOptionalNames: selectedOptionalNames,
            optionalToolsFooter: optionalToolsFooter
        )
    }
}

private struct AgentSkillSelectionView: View {
    let skills: [ServerSkillSummary]
    @Binding var selectedPaths: Set<String>
    let catalogState: AgentResourceCatalogState

    private var selectableSkills: [ServerSkillSummary] {
        skills.filter { $0.path != nil }
    }

    private var discoveredPaths: Set<String> {
        Set(selectableSkills.compactMap(\.path))
    }

    private var unavailablePaths: [String] {
        selectedPaths.subtracting(discoveredPaths).sorted()
    }

    var body: some View {
        List {
            catalogStatus

            if catalogState == .empty && selectableSkills.isEmpty && unavailablePaths.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Skills Found",
                        systemImage: "hammer",
                        description: Text("This server has no selectable Skills.")
                    )
                }
            } else if catalogState == .content && selectableSkills.isEmpty && unavailablePaths.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Selectable Skills",
                        systemImage: "hammer",
                        description: Text("The loaded Skills catalog has no selectable paths.")
                    )
                }
            }

            if !selectableSkills.isEmpty {
                Section("Discovered Skills") {
                    ForEach(selectableSkills) { skill in
                        if let path = skill.path {
                            resourceButton(
                                resourceKind: "skill",
                                id: path,
                                title: skill.name,
                                subtitle: skill.description,
                                status: skill.state == .error
                                    ? (skill.loadError ?? "Cannot load")
                                    : skill.state == .disabled ? "Disabled by default · selectable for this Agent" : nil,
                                canAdd: skill.state != .error
                            )
                        }
                    }
                }
            }

            if !unavailablePaths.isEmpty {
                Section {
                    ForEach(unavailablePaths, id: \.self) { path in
                        resourceButton(
                            resourceKind: "skill",
                            id: path,
                            title: path,
                            subtitle: "No longer discovered on this server",
                            status: "Unavailable",
                            canAdd: false
                        )
                    }
                } header: {
                    Text("Unavailable Selections")
                } footer: {
                    Text("Deselect these paths before saving, or restore them on the server.")
                }
            }
        }
        .navigationTitle("Agent Skills")
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
    }

    @ViewBuilder
    private var catalogStatus: some View {
        switch catalogState {
        case .loading:
            Section {
                ProgressView("Loading Skills…")
            }
        case .neverLoaded:
            Section {
                Label("Skills catalog has not loaded", systemImage: "questionmark.circle")
                    .foregroundStyle(.themeOrange)
            } footer: {
                Text("Reconnect or retry before choosing a new exact selection.")
            }
        case .failed:
            Section {
                Label("Skills unavailable", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.themeOrange)
            } footer: {
                Text("Existing selections are preserved. Retry before choosing new Skills.")
            }
        case .cachedOffline:
            Section {
                Label("Showing cached Skills", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.themeOrange)
            }
        case .unavailable:
            Section {
                Label("Skills unavailable offline", systemImage: "wifi.slash")
                    .foregroundStyle(.themeOrange)
            } footer: {
                Text("Existing selections are preserved, and unavailable selections can still be removed.")
            }
        case .empty, .content:
            EmptyView()
        }
    }

    private func resourceButton(
        resourceKind: String,
        id: String,
        title: String,
        subtitle: String,
        status: String?,
        canAdd: Bool
    ) -> some View {
        let isSelected = selectedPaths.contains(id)
        return Button {
            if isSelected {
                selectedPaths.remove(id)
            } else if canAdd {
                selectedPaths.insert(id)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .themeBlue : .themeComment)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.themeFg)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                    if let status {
                        Text(status)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.themeOrange)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelected && !canAdd)
        .accessibilityLabel(title)
        .accessibilityValue([isSelected ? "Selected" : "Not selected", status].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("agent.nativeEdit.\(resourceKind).\(id)")
    }
}

private struct AgentExtensionSelectionView: View {
    let extensions: [ServerExtensionSummary]
    @Binding var selectedIds: Set<String>
    let catalogState: AgentResourceCatalogState

    private var discoveredIds: Set<String> { Set(extensions.map(\.id)) }

    private var unavailableIds: [String] {
        selectedIds.subtracting(discoveredIds).sorted()
    }

    var body: some View {
        List {
            catalogStatus

            if catalogState == .empty && extensions.isEmpty && unavailableIds.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Extensions Found",
                        systemImage: "puzzlepiece.extension",
                        description: Text("This server has no selectable Extensions.")
                    )
                }
            }

            if !extensions.isEmpty {
                Section("Discovered Extensions") {
                    ForEach(extensions) { resource in
                        resourceButton(
                            resourceKind: "extension",
                            id: resource.id,
                            title: resource.name,
                            subtitle: resource.description ?? resource.provenance.label,
                            status: resource.state == .error
                                ? (resource.loadError ?? "Cannot load")
                                : resource.state == .off ? "Off by default · selectable for this Agent" : nil,
                            canAdd: resource.state != .error
                        )
                    }
                }
            }

            if !unavailableIds.isEmpty {
                Section {
                    ForEach(unavailableIds, id: \.self) { id in
                        resourceButton(
                            resourceKind: "extension",
                            id: id,
                            title: id,
                            subtitle: "No longer discovered on this server",
                            status: "Unavailable",
                            canAdd: false
                        )
                    }
                } header: {
                    Text("Unavailable Selections")
                } footer: {
                    Text("Deselect these identifiers before saving, or restore them on the server.")
                }
            }
        }
        .navigationTitle("Agent Extensions")
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
    }

    @ViewBuilder
    private var catalogStatus: some View {
        switch catalogState {
        case .loading:
            Section {
                ProgressView("Loading Extensions…")
            }
        case .neverLoaded:
            Section {
                Label("Extensions catalog has not loaded", systemImage: "questionmark.circle")
                    .foregroundStyle(.themeOrange)
            } footer: {
                Text("Reconnect or retry before choosing a new exact selection.")
            }
        case .failed:
            Section {
                Label("Extensions unavailable", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.themeOrange)
            } footer: {
                Text("Existing selections are preserved. Retry before choosing new Extensions.")
            }
        case .cachedOffline:
            Section {
                Label("Showing cached Extensions", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.themeOrange)
            }
        case .unavailable:
            Section {
                Label("Extensions unavailable offline", systemImage: "wifi.slash")
                    .foregroundStyle(.themeOrange)
            } footer: {
                Text("Existing selections are preserved, and unavailable selections can still be removed.")
            }
        case .empty, .content:
            EmptyView()
        }
    }

    private func resourceButton(
        resourceKind: String,
        id: String,
        title: String,
        subtitle: String,
        status: String?,
        canAdd: Bool
    ) -> some View {
        let isSelected = selectedIds.contains(id)
        return Button {
            if isSelected {
                selectedIds.remove(id)
            } else if canAdd {
                selectedIds.insert(id)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .themeBlue : .themeComment)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.themeFg)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                    if let status {
                        Text(status)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.themeOrange)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelected && !canAdd)
        .accessibilityLabel(title)
        .accessibilityValue([isSelected ? "Selected" : "Not selected", status].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("agent.nativeEdit.\(resourceKind).\(id)")
    }
}

extension String {
    var managementNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}