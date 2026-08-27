import SwiftUI

enum AgentManagementRow: Equatable, Identifiable {
    case pi
    case saved(AgentDefinitionSummary)

    var id: String {
        switch self {
        case .pi: "pi"
        case .saved(let agent): "saved:\(agent.id)"
        }
    }

    var agentId: String? {
        guard case .saved(let agent) = self else { return nil }
        return agent.id
    }

    var name: String {
        switch self {
        case .pi: "Pi"
        case .saved(let agent): agent.name
        }
    }
}

enum AgentManagementPresentation {
    static let piAvatar = AssistantAvatar.officialPi
    static let globalSystemPromptPath = "~/.pi/agent/SYSTEM.md"
    static let piIdentityAccessibilityLabel = "Pi, Official Pi avatar"
    static let piDefaultPromptInUseLabel = "Pi default in use until SYSTEM.md exists"
    static let piStandardToolsSummary = "Pi standard"
    static let piToolsInheritFooter =
        "Uses Pi's standard built-in tools. Extension tools stay enabled."
    static let piToolsExactFooter =
        "Only the selected built-in tools are available. Extension tools stay enabled."

    static func rows(savedAgents: [AgentDefinitionSummary]) -> [AgentManagementRow] {
        [.pi] + savedAgents.map(AgentManagementRow.saved)
    }

    static func piPromptIsReviewable(_ source: PiSystemPromptSnapshot.Source) -> Bool {
        source == .file
    }

    static func piSystemPromptAccessibilityLabel(source: PiSystemPromptSnapshot.Source) -> String {
        source == .file ? "Read and comment on SYSTEM.md" : piDefaultPromptInUseLabel
    }

    static func piSystemPromptAccessibilityValue(source: PiSystemPromptSnapshot.Source) -> String? {
        source == .file ? nil : piDefaultPromptInUseLabel
    }

    struct PiToolsSaveCoordinator: Equatable {
        var persisted: [String]?
        private(set) var isSaving = false
        private var hasQueuedSave = false

        init(persisted: [String]? = nil) {
            self.persisted = persisted
        }

        private(set) var pendingDesired: [String]?

        /// Returns true when the caller should run the save loop.
        mutating func requestSave() -> Bool {
            if isSaving {
                hasQueuedSave = true
                return false
            }
            isSaving = true
            hasQueuedSave = false
            return true
        }

        /// Captures the latest leave-time payload, then requests the save loop.
        mutating func requestSave(desired next: [String]?) -> Bool {
            pendingDesired = next
            return requestSave()
        }

        /// Call after a write or unchanged skip. Returns true to continue with the latest desired value.
        mutating func finishAttempt(persisted next: [String]?) -> Bool {
            persisted = next
            if hasQueuedSave {
                hasQueuedSave = false
                return true
            }
            isSaving = false
            return false
        }

        mutating func fail() {
            hasQueuedSave = false
            isSaving = false
        }
    }

    enum PiToolsSavePayload: Equatable {
        /// Tools never loaded; do not PUT.
        case skip
        /// PUT this defaultTools value. `nil` writes JSON null (Pi defaults).
        case write([String]?)
    }

    /// PUT body for Pi Tools. Back (isPresented true→false) and post-load
    /// checkbox/mode changes both save the captured selection, not later view state.
    static func piToolsSavePayload(
        leaveHasLoadedTools: Bool,
        leaveMode: AgentToolSelectionMode,
        leaveSelectedNames: Set<String>,
        laterHasLoadedTools _: Bool,
        laterMode _: AgentToolSelectionMode,
        laterSelectedNames _: Set<String>,
        builtInTools: [ServerToolSummary],
        pickerWasPresented: Bool,
        pickerIsPresented: Bool,
        selectionChangedAfterLoad: Bool,
        isApplyingLoadedTools: Bool = false,
        namesChanged: Bool = false
    ) -> PiToolsSavePayload {
        guard leaveHasLoadedTools else { return .skip }
        // GET/revert binding writes are not a user selection change.
        guard !isApplyingLoadedTools else { return .skip }
        // inherit→exact sets names then mode; names onChange must not PUT null.
        if namesChanged && leaveMode == .inherit { return .skip }
        let dismissedPicker = pickerWasPresented && !pickerIsPresented
        guard dismissedPicker || selectionChangedAfterLoad else { return .skip }
        let desired: [String]? = leaveMode == .exact
            ? piExactToolNames(selectedNames: leaveSelectedNames, builtInTools: builtInTools)
            : nil
        return .write(desired)
    }

    /// Skip replacing the in-memory selection while a write is in flight or the picker is open.
    /// PUT failure still reverts visible selection, including while the picker is presented.
    static func shouldApplyLoadedPiTools(
        hasLoadedTools: Bool,
        isSaving: Bool,
        pickerIsPresented: Bool,
        isRevertingAfterFailure: Bool = false
    ) -> Bool {
        if isRevertingAfterFailure { return true }
        return !hasLoadedTools || (!isSaving && !pickerIsPresented)
    }

    static func piToolsSummary(defaultTools: [String]?) -> String {
        guard let defaultTools else { return piStandardToolsSummary }
        return defaultTools.isEmpty ? "None" : defaultTools.joined(separator: ", ")
    }

    static func piExactToolNames(
        selectedNames: Set<String>,
        builtInTools: [ServerToolSummary]
    ) -> [String] {
        builtInTools.map(\.name).filter { selectedNames.contains($0) }
    }
}

struct UseOppiSessionRow: View {
    let supportingText: String?
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Use Oppi Session")
                        .foregroundStyle(.themeFg)
                    if let supportingText {
                        Text(supportingText)
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeComment)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel("Use Oppi Session")
        .accessibilityHint(supportingText ?? "Opens an Oppi session")
    }
}

struct AgentManagementView: View {
    @Environment(\.apiClient) private var apiClient

    @State private var agents: [AgentDefinitionSummary] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(AgentManagementPresentation.rows(savedAgents: agents)) { row in
                    switch row {
                    case .pi:
                        NavigationLink {
                            PiAgentDetailView()
                        } label: {
                            PiAgentSummaryRow()
                        }
                        .accessibilityIdentifier("agents.row.pi")
                    case .saved(let agent):
                        NavigationLink {
                            AgentDetailView(agentId: agent.id) { updated in
                                guard let index = agents.firstIndex(where: { $0.id == updated.id }) else {
                                    return
                                }
                                agents[index] = AgentDefinitionSummary(
                                    id: updated.id,
                                    name: updated.name,
                                    icon: updated.definition.icon,
                                    description: updated.description,
                                    launchConstraints: updated.definition.launchConstraints,
                                    status: updated.status,
                                    version: updated.version,
                                    createdAt: updated.createdAt,
                                    updatedAt: updated.updatedAt,
                                    archivedAt: updated.archivedAt
                                )
                            }
                        } label: {
                            AgentSummaryRow(agent: agent)
                        }
                        .accessibilityIdentifier("agents.row.\(agent.id)")
                    }
                }

                if isLoading && agents.isEmpty {
                    ProgressView("Loading saved Agents…")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } header: {
                Text("Agents")
            } footer: {
                Text("Pi uses the server's global Pi configuration. Saved Agents add reusable instructions, resources, and session defaults.")
            }
        }
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GuidedControlSessionComposer(
                domain: .agents,
                intent: .create,
                placeholder: "Describe a new Agent…"
            )
        }
        .refreshable { await loadAgents() }
        .task { await loadAgents() }
        .alert("Agents", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    @MainActor
    private func loadAgents() async {
        guard let apiClient else {
            error = "Server is offline"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            agents = try await apiClient.listAgents()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PiAgentSummaryRow: View {
    var body: some View {
        HStack(spacing: 12) {
            AssistantAvatarPreview(
                avatar: AgentManagementPresentation.piAvatar,
                sessionId: "pi-agent-row",
                size: 30
            )
            .padding(4)
            .background(.themeBgHighlight, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text("Pi")
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                Text("Global Pi configuration")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
    }
}

struct PiAgentDetailView: View {
    @Environment(\.apiClient) private var apiClient

    @State private var isShowingSystemPromptSession = false
    @State private var isShowingFilePromptReview = false
    @State private var isShowingDefaultPrompt = false
    @State private var isShowingPiTools = false
    @State private var prompt: PiSystemPromptSnapshot?
    @State private var defaultTools: [String]?
    @State private var builtInTools: [ServerToolSummary] = []
    @State private var toolSelectionMode: AgentToolSelectionMode = .inherit
    @State private var selectedToolNames: Set<String> = []
    @State private var hasLoadedTools = false
    @State private var isApplyingLoadedTools = false
    @State private var toolsSave = AgentManagementPresentation.PiToolsSaveCoordinator()
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    AssistantAvatarPreview(
                        avatar: AgentManagementPresentation.piAvatar,
                        sessionId: "pi-agent-detail",
                        size: 44
                    )
                    .padding(6)
                    .background(.themeBgHighlight, in: RoundedRectangle(cornerRadius: 14))
                    Text("Pi")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.themeFg)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(AgentManagementPresentation.piIdentityAccessibilityLabel)
                .accessibilityIdentifier("agents.pi.identity")
            }

            Section("System Prompt") {
                LabeledContent("File") {
                    Text(AgentManagementPresentation.globalSystemPromptPath)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("agents.pi.systemPromptPath")
                }

                Button {
                    openPrompt()
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        if let content = prompt?.content, !content.isEmpty {
                            Text(content)
                                .foregroundStyle(.themeFg)
                                .multilineTextAlignment(.leading)
                                .lineLimit(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if isLoading {
                            ProgressView("Loading prompt…")
                        }

                        if usesDefaultPrompt {
                            Text(AgentManagementPresentation.piDefaultPromptInUseLabel)
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                        } else {
                            Label("Read and comment", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.themeBlue)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    AgentManagementPresentation.piSystemPromptAccessibilityLabel(
                        source: prompt?.source ?? .default
                    )
                )
                .accessibilityValue(
                    AgentManagementPresentation.piSystemPromptAccessibilityValue(
                        source: prompt?.source ?? .default
                    ) ?? ""
                )
                .accessibilityIdentifier("agents.pi.systemPrompt")
            }

            Section {
                Button {
                    isShowingPiTools = true
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        LabeledContent(
                            "Tools",
                            value: AgentManagementPresentation.piToolsSummary(defaultTools: defaultTools)
                        )
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.themeComment)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("agents.pi.tools")
            } footer: {
                Text("Chooses Pi's built-in tools. Extension tools stay enabled.")
            }

            Section {
                Button {
                    isShowingSystemPromptSession = true
                } label: {
                    Label("Edit SYSTEM.md with Pi", systemImage: "text.bubble")
                }
                .accessibilityIdentifier("agents.pi.editSystemPrompt")
            } footer: {
                Text("Opens a Pi Control session so Pi can inspect, create, or edit the global file. Pi is not stored as a saved Agent.")
            }
        }
        .navigationTitle("Pi")
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
        .navigationDestination(isPresented: $isShowingPiTools) {
            AgentToolSelectionView(
                mode: $toolSelectionMode,
                selectedNames: $selectedToolNames,
                builtInTools: builtInTools,
                defaultSelection: defaultBuiltInSelection,
                title: "Pi Tools",
                inheritFooter: AgentManagementPresentation.piToolsInheritFooter,
                exactFooter: AgentManagementPresentation.piToolsExactFooter
            )
        }
        .task {
            guard !hasLoadedTools else { return }
            await load()
        }
        .refreshable { await load() }
        .onChange(of: isShowingPiTools) { wasPresented, isPresented in
            guard wasPresented, !isPresented else { return }
            saveCurrentTools(
                pickerWasPresented: true,
                pickerIsPresented: false,
                selectionChangedAfterLoad: false
            )
        }
        .onChange(of: toolSelectionMode) { _, _ in
            syncDisplayedDefaultTools()
            saveCurrentTools(
                pickerWasPresented: isShowingPiTools,
                pickerIsPresented: isShowingPiTools,
                selectionChangedAfterLoad: true
            )
        }
        .onChange(of: selectedToolNames) { _, _ in
            syncDisplayedDefaultTools()
            saveCurrentTools(
                pickerWasPresented: isShowingPiTools,
                pickerIsPresented: isShowingPiTools,
                selectionChangedAfterLoad: true,
                namesChanged: true
            )
        }
        .sheet(isPresented: $isShowingSystemPromptSession) {
            GuidedControlSessionSheet(
                domain: .agents,
                intent: .revise,
                targetName: "Pi global configuration",
                initialRequest: "Inspect ~/.pi/agent/SYSTEM.md and help me create or edit Pi's global system prompt. Explain that SYSTEM.md replaces Pi's default system prompt and APPEND_SYSTEM.md appends to it before making changes.",
                allowsEmptyRequest: false,
                placeholder: "Describe how Pi's global system prompt should change…"
            )
        }
        .sheet(isPresented: $isShowingFilePromptReview) {
            if let prompt, let resolvedPath = prompt.resolvedPath {
                ReviewableControlMarkdownView(
                    content: prompt.content,
                    domain: .agents,
                    targetId: "pi",
                    targetName: "Pi",
                    sourceLabel: "SYSTEM.md",
                    sourcePath: resolvedPath
                )
            }
        }
        .fullScreenCover(isPresented: $isShowingDefaultPrompt) {
            EmbeddedFileViewerView(
                content: .fromText(
                    prompt?.content ?? "",
                    filePath: "Pi-default-system-prompt.md"
                )
            )
            .ignoresSafeArea(edges: .top)
        }
        .alert("Pi", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var usesDefaultPrompt: Bool {
        prompt?.source != .file
    }

    private var defaultBuiltInSelection: Set<String> {
        Set(builtInTools.filter { $0.defaultEnabled == true }.map(\.name))
    }

    private func openPrompt() {
        if AgentManagementPresentation.piPromptIsReviewable(prompt?.source ?? .default) {
            isShowingFilePromptReview = true
        } else if prompt?.content != nil {
            isShowingDefaultPrompt = true
        }
    }

    private func syncDisplayedDefaultTools() {
        guard hasLoadedTools else { return }
        defaultTools = toolSelectionMode == .exact
            ? AgentManagementPresentation.piExactToolNames(
                selectedNames: selectedToolNames,
                builtInTools: builtInTools
            )
            : nil
    }

    @MainActor
    private func load() async {
        guard let apiClient else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            async let fetchedPrompt = apiClient.getPiSystemPrompt()
            async let fetchedTools = apiClient.getPiDefaultTools()
            async let fetchedCatalog = apiClient.listServerExtensions()
            let (resolvedPrompt, resolvedTools, catalog) = try await (fetchedPrompt, fetchedTools, fetchedCatalog)
            prompt = resolvedPrompt
            builtInTools = catalog.builtInTools
            applyLoadedDefaultTools(resolvedTools.defaultTools)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func applyLoadedDefaultTools(
        _ loaded: [String]?,
        isRevertingAfterFailure: Bool = false
    ) {
        guard AgentManagementPresentation.shouldApplyLoadedPiTools(
            hasLoadedTools: hasLoadedTools,
            isSaving: toolsSave.isSaving,
            pickerIsPresented: isShowingPiTools,
            isRevertingAfterFailure: isRevertingAfterFailure
        ) else {
            hasLoadedTools = true
            return
        }
        // Binding onChange must not PUT while GET/revert writes mode and names.
        isApplyingLoadedTools = true
        toolsSave = AgentManagementPresentation.PiToolsSaveCoordinator(persisted: loaded)
        defaultTools = loaded
        if let loaded {
            toolSelectionMode = .exact
            selectedToolNames = Set(loaded)
        } else {
            toolSelectionMode = .inherit
            selectedToolNames = defaultBuiltInSelection
        }
        hasLoadedTools = true
        Task { @MainActor in
            isApplyingLoadedTools = false
        }
    }

    private func saveCurrentTools(
        pickerWasPresented: Bool,
        pickerIsPresented: Bool,
        selectionChangedAfterLoad: Bool,
        namesChanged: Bool = false
    ) {
        let action = AgentManagementPresentation.piToolsSavePayload(
            leaveHasLoadedTools: hasLoadedTools,
            leaveMode: toolSelectionMode,
            leaveSelectedNames: selectedToolNames,
            laterHasLoadedTools: hasLoadedTools,
            laterMode: toolSelectionMode,
            laterSelectedNames: selectedToolNames,
            builtInTools: builtInTools,
            pickerWasPresented: pickerWasPresented,
            pickerIsPresented: pickerIsPresented,
            selectionChangedAfterLoad: selectionChangedAfterLoad,
            isApplyingLoadedTools: isApplyingLoadedTools,
            namesChanged: namesChanged
        )
        guard case .write(let desired) = action else { return }
        // Mark isSaving before the async PUT so a following GET cannot apply stale names.
        guard toolsSave.requestSave(desired: desired) else { return }
        Task {
            await performQueuedPiToolsSave()
        }
    }

    @MainActor
    private func performQueuedPiToolsSave() async {
        guard let apiClient else {
            let persisted = toolsSave.persisted
            toolsSave.fail()
            applyLoadedDefaultTools(persisted, isRevertingAfterFailure: true)
            return
        }

        while true {
            let next = toolsSave.pendingDesired
            if next == toolsSave.persisted {
                let persisted = toolsSave.persisted
                if !toolsSave.finishAttempt(persisted: persisted) { return }
                continue
            }
            do {
                let saved = try await apiClient.setPiDefaultTools(next)
                defaultTools = saved.defaultTools
                error = nil
                if !toolsSave.finishAttempt(persisted: saved.defaultTools) { return }
            } catch {
                let persisted = toolsSave.persisted
                toolsSave.fail()
                applyLoadedDefaultTools(persisted, isRevertingAfterFailure: true)
                self.error = error.localizedDescription
                return
            }
        }
    }
}

private struct AgentSummaryRow: View {
    let agent: AgentDefinitionSummary

    var body: some View {
        HStack(spacing: 12) {
            AgentIconView(value: agent.icon, size: 22, frameSize: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(agent.name)
                        .font(.headline)
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)

                    StatusPill(
                        text: "v\(agent.version)",
                        tone: .neutral,
                        emphasis: .quiet,
                        size: .mini,
                        monospacedDigit: true
                    )
                }

                if let description = agent.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .lineLimit(2)
                } else {
                    Text("No description")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
            }

            Spacer(minLength: 8)

            Text(agent.updatedAt.relativeString())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.themeComment)
        }
        .padding(.vertical, 4)
    }
}

private struct AgentDetailView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(ServerConnection.self) private var connection
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(AppNavigation.self) private var navigation

    let agentId: String
    let onUpdated: (StoredAgentDefinition) -> Void

    @State private var agent: StoredAgentDefinition?
    @State private var isLoading = false
    @State private var error: String?
    @State private var isShowingNativeEdit = false
    @State private var isShowingRevision = false
    @State private var isShowingDefinitionReview = false
    @State private var isShowingIconPicker = false
    @State private var isShowingSchedule = false
    @State private var isArchiving = false
    @State private var isLoadingResources = false

    var body: some View {
        List {
            if isLoading && agent == nil {
                ProgressView("Loading agent…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .themedListRowBackground()
            } else if let agent {
                Section("Definition") {
                    Button {
                        isShowingIconPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            Text("Icon")
                                .foregroundStyle(.themeComment)
                            Spacer(minLength: 12)
                            AgentIconView(value: agent.definition.icon, size: 24, frameSize: 32)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.themeComment)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Icon")
                    .accessibilityValue(iconSummary(agent.definition.icon))
                    .accessibilityHint("Opens the Agent icon picker")
                    .accessibilityIdentifier("agents.detail.icon")

                    detailRow("Name", agent.definition.name)
                    if let description = agent.definition.description, !description.isEmpty {
                        detailTextBlock("Description", description)
                    }
                    detailRow("Status", agent.status.rawValue.capitalized)
                    detailRow("Version", "v\(agent.version)")
                }

                if let instructions = agent.definition.instructions {
                    Section(systemPromptTitle(instructions.mode)) {
                        Button {
                            isShowingDefinitionReview = true
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(instructions.text)
                                    .foregroundStyle(.themeFg)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Label("Read and comment", systemImage: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.themeBlue)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Read and comment on Agent definition")
                        .accessibilityIdentifier("agents.detail.definition")
                    }
                }

                Section("Pi Session Defaults") {
                    let defaults = agent.definition.sessionDefaults
                    detailRow("Model", defaults?.model?.nilIfBlank ?? "Server default")
                    detailRow("Thinking Level", defaults?.thinkingLevel?.rawValue ?? "Default")
                    toolDefaultRows(defaults)
                }

                Section("Resources") {
                    resourceRow(
                        "Skills",
                        values: agent.definition.resources?.skillPaths,
                        displayValues: skillDisplayNames(agent.definition.resources?.skillPaths)
                    )
                    resourceRow(
                        "Extensions",
                        values: agent.definition.resources?.extensionIds,
                        displayValues: extensionDisplayNames(agent.definition.resources?.extensionIds)
                    )
                    if agent.definition.resources?.noContextFiles == true {
                        Label("Context files disabled", systemImage: "doc.badge.gearshape")
                            .font(.subheadline)
                    }
                    if let message = skillCatalogState.statusMessage(for: "Skills") {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.themeOrange)
                    }
                    if let message = extensionCatalogState.statusMessage(for: "Extensions") {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.themeOrange)
                    }
                }

                if let constraints = agent.definition.launchConstraints {
                    Section("Launch Constraints") {
                        detailRow("Runtime", constraints.requiredRuntime?.rawValue.capitalized ?? "Any")
                        detailRow("Workspaces", allowedWorkspaceNames(constraints.allowedWorkspaceIds))
                    }
                }

                Section("Automation") {

                    Button {
                        isShowingSchedule = true
                    } label: {
                        Label("Schedule Recurring Run", systemImage: "calendar.badge.clock")
                    }
                    .disabled(workspaceStore.workspaces.isEmpty)
                    .accessibilityIdentifier("agents.detail.schedule")

                    if workspaceStore.workspaces.isEmpty {
                        Text("Create or sync a workspace before starting or scheduling this Agent.")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    } else {
                        Text("Schedules can run this Agent with a recurring briefing prompt, selected workspace, and repeat time.")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                }
            } else {
                ContentUnavailableView("Agent Not Found", systemImage: "questionmark.circle")
                    .themedListRowBackground()
            }
        }
        .navigationTitle(agent?.name ?? "Agent")
        .navigationBarTitleDisplayMode(.inline)
        .themedListSurface()
        .toolbar {
            if let agent, agent.status == .active {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Edit") {
                        isShowingNativeEdit = true
                    }
                    .accessibilityIdentifier("agents.detail.edit")

                    Menu {
                        Button {
                            isShowingRevision = true
                        } label: {
                            Label("Edit with Oppi", systemImage: "text.bubble")
                        }
                        .accessibilityIdentifier("agents.detail.revise")

                        Button("Archive Agent", role: .destructive) {
                            Task { await archiveAgent() }
                        }
                        .disabled(isArchiving)
                        .accessibilityIdentifier("agents.detail.archive")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Agent actions")
                    .accessibilityIdentifier("agents.detail.actions")
                }

                // Match session inbox: pin compose to the trailing bottom bar with neutral chrome.
                ToolbarItem(placement: .bottomBar) {
                    Spacer()
                }

                ToolbarItem(placement: .bottomBar) {
                    Button {
                        startQuickSession(with: agent)
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .foregroundStyle(.themeFg)
                    .disabled(workspaceStore.workspaces.isEmpty || connection.currentServerId == nil)
                    .accessibilityLabel("Start session with \(agent.name)")
                    .accessibilityIdentifier("agents.detail.launch")
                }
            }
        }
        .task(id: agentId) {
            await loadAgent()
            await loadResources()
        }
        .refreshable {
            await loadAgent()
            await loadResources()
        }
        .fullScreenCover(isPresented: $isShowingNativeEdit) {
            if let agent {
                AgentNativeEditView(agent: agent) { updated in
                    self.agent = updated
                    onUpdated(updated)
                }
            }
        }
        .sheet(isPresented: $isShowingIconPicker) {
            if let agent {
                AgentIconPickerView(agent: agent) { updated in
                    self.agent = updated
                    onUpdated(updated)
                }
            }
        }
        .sheet(isPresented: $isShowingRevision) {
            if let agent {
                GuidedControlSessionSheet(
                    domain: .agents,
                    intent: .revise,
                    targetId: agent.id,
                    targetName: agent.name,
                    placeholder: "Describe how this Agent should change…"
                )
            }
        }
        .sheet(isPresented: $isShowingDefinitionReview) {
            if let agent {
                ReviewableControlMarkdownView(
                    content: definitionMarkdown(agent),
                    domain: .agents,
                    targetId: agent.id,
                    targetName: agent.name,
                    sourceLabel: "\(agent.name) definition",
                    sourcePath: "Agents/\(agent.id)/Definition.md"
                )
            }
        }

        .sheet(isPresented: $isShowingSchedule) {
            if let agent {
                GuidedControlSessionSheet(
                    domain: .schedules,
                    intent: .create,
                    initialRequest: "Create a schedule that runs saved Agent \(agent.name) (canonical Agent ID: \(agent.id)).",
                    allowsEmptyRequest: false,
                    placeholder: "Describe when and how this Agent should run…"
                )
            }
        }
        .alert("Agent", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func iconSummary(_ value: IconChoice) -> String {
        AgentIconPickerView.description(value)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        LabeledContent {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(title)
                .foregroundStyle(.themeComment)
        }
        .font(.subheadline)
    }

    private func detailTextBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.themeComment)
            Text(value)
                .foregroundStyle(.themeFg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func systemPromptTitle(_ mode: AgentInstructionMode) -> String {
        switch mode {
        case .append: return "Append System Prompt"
        case .replace: return "Replace System Prompt"
        }
    }

    private func definitionMarkdown(_ agent: StoredAgentDefinition) -> String {
        let definition = agent.definition
        let defaults = definition.sessionDefaults
        let resources = definition.resources
        let instructions: [String]
        if let instruction = definition.instructions {
            instructions = [
                "## \(systemPromptTitle(instruction.mode))",
                "",
                instruction.text,
            ]
        } else {
            instructions = ["## System Prompt", "", "_Uses the server default._"]
        }

        var lines = ["# \(definition.name)", ""]
        if let description = definition.description?.nilIfBlank {
            lines.append(description)
            lines.append("")
        }
        lines += instructions
        lines += [
            "",
            "## Pi Session Defaults",
            "",
            "- **Model:** \(defaults?.model?.nilIfBlank ?? "Server default")",
            "- **Thinking level:** \(defaults?.thinkingLevel?.rawValue ?? "Default")",
            "- **Tools:** \(agentToolSummary(defaults))",
            "",
            "## Resources",
            "",
            "- **Skills:** \(resourceSummary(resources?.skillPaths, displayValues: skillDisplayNames(resources?.skillPaths)))",
            "- **Extensions:** \(resourceSummary(resources?.extensionIds, displayValues: extensionDisplayNames(resources?.extensionIds)))",
            "- **Context files:** \(resources?.noContextFiles == true ? "Disabled" : "Default discovery")",
        ]
        return lines.joined(separator: "\n")
    }

    private func agentToolSummary(_ defaults: AgentSessionDefaults?) -> String {
        if let noTools = defaults?.noTools { return noTools.displayName }
        if let allowed = defaults?.tools {
            return allowed.isEmpty ? "Allowed: None" : "Allowed: \(allowed.joined(separator: ", "))"
        }
        if let excluded = defaults?.excludeTools {
            return excluded.isEmpty ? "Excluded: None" : "Excluded: \(excluded.joined(separator: ", "))"
        }
        return "Default"
    }

    private func allowedWorkspaceNames(_ ids: [String]?) -> String {
        guard let ids else { return "Any" }
        return ids.map { id in
            workspaceStore.workspaces.first(where: { $0.id == id })?.name ?? id
        }.joined(separator: ", ")
    }

    private func resourceSummary(_ values: [String]?, displayValues: [String]? = nil) -> String {
        guard let values else { return "Default discovery" }
        guard !values.isEmpty else { return "None" }
        return (displayValues ?? values).joined(separator: ", ")
    }

    private func skillDisplayNames(_ paths: [String]?) -> [String]? {
        guard let paths, let serverId = connection.currentServerId else { return nil }
        let catalog = connection.serverResourceStore.skills(forServer: serverId)
        return paths.map { path in
            catalog.first(where: { $0.path == path })?.name ?? path
        }
    }

    private func extensionDisplayNames(_ ids: [String]?) -> [String]? {
        guard let ids, let serverId = connection.currentServerId else { return nil }
        let catalog = connection.serverResourceStore.extensions(forServer: serverId)
        return ids.map { id in
            catalog.first(where: { $0.id == id })?.name ?? id
        }
    }

    private var skillCatalogState: AgentResourceCatalogState {
        guard let serverId = connection.currentServerId else { return .unavailable }
        let sync = connection.serverResourceStore.syncState(for: .skills, serverId: serverId)
        return AgentResourceCatalogState.resolve(
            hasLoaded: connection.serverResourceStore.hasLoadedSkills(forServer: serverId),
            isSyncing: isLoadingResources || sync.isSyncing,
            lastSyncFailed: sync.lastSyncFailed,
            hasRows: !connection.serverResourceStore.skills(forServer: serverId).isEmpty
        )
    }

    private var extensionCatalogState: AgentResourceCatalogState {
        guard let serverId = connection.currentServerId else { return .unavailable }
        let sync = connection.serverResourceStore.syncState(for: .extensions, serverId: serverId)
        return AgentResourceCatalogState.resolve(
            hasLoaded: connection.serverResourceStore.hasLoadedExtensions(forServer: serverId),
            isSyncing: isLoadingResources || sync.isSyncing,
            lastSyncFailed: sync.lastSyncFailed,
            hasRows: !connection.serverResourceStore.extensions(forServer: serverId).isEmpty
        )
    }

    @ViewBuilder
    private func toolDefaultRows(_ defaults: AgentSessionDefaults?) -> some View {
        if defaults?.noTools == nil && defaults?.tools == nil && defaults?.excludeTools == nil {
            detailRow("Tools", "Default")
        } else {
            if let noTools = defaults?.noTools {
                detailRow("Tools", noTools.displayName)
            }
            if let allowed = defaults?.tools {
                detailTextBlock(
                    "Allowed Tools",
                    allowed.isEmpty ? "None" : allowed.joined(separator: ", ")
                )
            }
            if let excluded = defaults?.excludeTools {
                detailTextBlock(
                    "Excluded Tools",
                    excluded.isEmpty ? "None" : excluded.joined(separator: ", ")
                )
            }
        }
    }

    @ViewBuilder
    private func resourceRow(
        _ title: String,
        values: [String]?,
        displayValues: [String]? = nil
    ) -> some View {
        if let values {
            if values.isEmpty {
                detailRow(title, "None")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                    Text((displayValues ?? values).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                        .textSelection(.enabled)
                }
            }
        } else {
            detailRow(title, "Default discovery")
        }
    }

    @MainActor
    private func loadAgent() async {
        guard let apiClient else {
            error = "Server is offline"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            agent = try await apiClient.getAgent(agentId)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func loadResources() async {
        guard let apiClient, let serverId = connection.currentServerId else { return }
        isLoadingResources = true
        defer { isLoadingResources = false }
        await connection.serverResourceStore.load(serverId: serverId, api: apiClient)
    }

    private func startQuickSession(with agent: StoredAgentDefinition) {
        guard let serverId = connection.currentServerId else { return }
        navigation.pendingQuickSessionLaunchContext = QuickSessionLaunchContext(
            serverId: serverId,
            agentId: agent.id
        )
        navigation.showQuickSession = true
    }

    @MainActor
    private func archiveAgent() async {
        guard let apiClient else { return }
        isArchiving = true
        defer { isArchiving = false }

        do {
            agent = try await apiClient.archiveAgent(agentId: agentId)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
