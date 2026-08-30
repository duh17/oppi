import SwiftUI

struct MacCatalogListColumn: View {
    let section: MacSidebarSection
    @Bindable var store: MacCatalogStore

    init(section: MacSidebarSection, store: MacCatalogStore = .shared) {
        self.section = section
        self.store = store
    }

    var body: some View {
        Group {
            switch section {
            case .agents:
                agentList
            case .schedules:
                scheduleList
            case .skills:
                skillList
            case .extensions:
                extensionList
            default:
                MacShellEmptyDetail(
                    title: section.title,
                    message: "This area is not available yet.",
                    systemImage: section.icon
                )
            }
        }
        .navigationTitle(section.title)
        .searchable(text: $store.query, prompt: searchPrompt)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await store.load(section) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading(section))
            }
            if section == .agents || section == .schedules {
                ToolbarItem {
                    Button {
                        if section == .agents {
                            store.beginCreateAgent()
                        } else {
                            store.beginCreateSchedule()
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
                ToolbarItem {
                    Button {
                        Task {
                            if section == .agents {
                                await store.beginCreateAgentControlSession()
                            } else {
                                await store.beginCreateScheduleControlSession()
                            }
                        }
                    } label: {
                        Label("Ask Oppi", systemImage: "text.bubble")
                    }
                    .help("Create with Oppi")
                    .accessibilityIdentifier("mac.catalog.askOppi")
                }
            }
        }
        .task(id: section) {
            store.query = ""
            await store.load(section)
        }
        .overlay(alignment: .bottom) {
            if store.isLoading(section) {
                ProgressView("Loading \(section.title.lowercased())…")
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
            }
        }
    }

    private var searchPrompt: String {
        switch section {
        case .agents: "Search agents"
        case .schedules: "Search schedules"
        case .skills: "Search skills"
        case .extensions: "Search extensions"
        default: "Search"
        }
    }

    private var agentList: some View {
        let presentation = MacCatalogAgentListPresentation(agents: store.agents, query: store.query)
        return List(selection: $store.selectedAgentID) {
            catalogStateSection(for: .agents, emptyMessage: presentation.emptyMessage) {
                ForEach(presentation.rows) { row in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                            Text(row.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        agentIcon(row)
                    }
                    .tag(row.id)
                }
            }
        }
        .onChange(of: store.selectedAgentID) { _, newValue in
            guard newValue != nil else { return }
            store.isCreatingAgent = false
            Task { await store.loadSelectedAgent() }
        }
    }

    private var scheduleList: some View {
        let presentation = MacCatalogScheduleListPresentation(
            schedules: store.schedules,
            status: store.scheduleStatusFilter,
            query: store.query
        )
        return List(selection: $store.selectedScheduleID) {
            Section {
                Picker("Status", selection: $store.scheduleStatusFilter) {
                    Text("Active").tag(AgentScheduleStatus.active)
                    Text("Paused").tag(AgentScheduleStatus.paused)
                    Text("Archived").tag(AgentScheduleStatus.archived)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            catalogStateSection(for: .schedules, emptyMessage: presentation.emptyMessage) {
                ForEach(presentation.rows) { schedule in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(schedule.name)
                            Text(schedule.trigger.detailTimingSummary())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: schedule.status == .paused ? "pause.circle" : "clock")
                    }
                    .tag(schedule.id)
                }
            }
        }
        .onChange(of: store.selectedScheduleID) { _, newValue in
            guard newValue != nil else { return }
            store.isCreatingSchedule = false
            Task { await store.loadSelectedSchedule() }
        }
        .onChange(of: store.scheduleStatusFilter) { _, filter in
            store.applyScheduleStatusFilter(filter)
        }
    }

    private var skillList: some View {
        let presentation = MacCatalogSkillListPresentation(skills: store.skills, query: store.query)
        return List(selection: $store.selectedSkillID) {
            catalogStateSection(for: .skills, emptyMessage: presentation.emptyMessage) {
                ForEach(presentation.sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.items) { skill in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skill.name)
                                    Text(skill.description.isEmpty ? skill.provenance.label : skill.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            } icon: {
                                Image(systemName: "sparkles.rectangle.stack")
                            }
                            .tag(skill.id)
                        }
                    }
                }
            }
        }
        .onChange(of: store.selectedSkillID) { _, newValue in
            guard newValue != nil else { return }
            Task { await store.loadSelectedSkill() }
        }
    }

    private var extensionList: some View {
        let presentation = MacCatalogExtensionListPresentation(extensions: store.extensions, query: store.query)
        return List(selection: $store.selectedExtensionID) {
            catalogStateSection(for: .extensions, emptyMessage: presentation.emptyMessage) {
                ForEach(presentation.sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.items) { resource in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(resource.name)
                                    Text(resource.description?.isEmpty == false ? resource.description ?? "" : resource.provenance.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            } icon: {
                                Image(systemName: resource.kind == .builtIn ? "puzzlepiece.extension.fill" : "puzzlepiece.extension")
                            }
                            .tag(resource.id)
                        }
                    }
                }
                if presentation.hasNoPiExtensions {
                    Section {
                        Text(MacCatalogExtensionListPresentation.emptyMessage)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: store.selectedExtensionID) { _, newValue in
            guard newValue != nil else { return }
            Task { await store.loadSelectedExtension() }
        }
    }

    @ViewBuilder
    private func catalogStateSection<Content: View>(
        for section: MacSidebarSection,
        emptyMessage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        switch store.contentState(for: section) {
        case .loading:
            EmptyView()
        case .unavailable:
            Section {
                ContentUnavailableView(
                    "Couldn’t Load \(section.title)",
                    systemImage: "exclamationmark.triangle",
                    description: Text(store.lastError(for: section) ?? "The local server did not return this catalog.")
                )
            }
        case .empty:
            Section {
                ContentUnavailableView(
                    section.title,
                    systemImage: section.icon,
                    description: Text(emptyMessage)
                )
            }
        case .filteredNoResults:
            Section {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("Nothing matches “\(store.query)”.")
                )
            }
        case .content:
            content()
        }
    }

    @ViewBuilder
    private func agentIcon(_ row: MacCatalogAgentRow) -> some View {
        switch row {
        case .pi:
            Image(systemName: "circle.hexagonpath")
        case .saved(let agent):
            switch agent.icon {
            case .emoji(let value):
                Text(value)
            case .symbol(let name):
                Image(systemName: name)
            case .defaultValue, .genmoji:
                Image(systemName: "person.crop.circle")
            }
        }
    }
}

struct MacCatalogDetailColumn: View {
    let section: MacSidebarSection
    @Bindable var store: MacCatalogStore

    init(section: MacSidebarSection, store: MacCatalogStore = .shared) {
        self.section = section
        self.store = store
    }

    var body: some View {
        Group {
            switch section {
            case .agents:
                agentDetail
            case .schedules:
                scheduleDetail
            case .skills:
                skillDetail
            case .extensions:
                extensionDetail
            default:
                MacShellEmptyDetail(
                    title: section.title,
                    message: "This area is not available yet.",
                    systemImage: section.icon
                )
            }
        }
        .task(id: section) {
            switch section {
            case .agents:
                await store.loadSelectedAgent()
            case .schedules:
                await store.loadSelectedSchedule()
            case .skills:
                await store.loadSelectedSkill()
            case .extensions:
                await store.loadSelectedExtension()
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var agentDetail: some View {
        if store.isCreatingAgent || store.agentDraft != nil, store.selectedAgentID != MacCatalogAgentRow.pi.id {
            MacAgentEditor(store: store)
        } else if store.selectedAgentID == MacCatalogAgentRow.pi.id {
            ContentUnavailableView(
                "Pi",
                systemImage: "circle.hexagonpath",
                description: Text("Pi uses the server's global configuration. Saved Agents add reusable instructions, resources, and session defaults.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MacShellEmptyDetail(
                title: "Select an Agent",
                message: "Choose a saved Agent to edit it, or add a new one.",
                systemImage: "person.crop.circle"
            )
        }
    }

    @ViewBuilder
    private var scheduleDetail: some View {
        if store.isCreatingSchedule || store.scheduleDraft != nil {
            MacScheduleEditor(store: store)
        } else {
            MacShellEmptyDetail(
                title: "Select a Schedule",
                message: "Choose a schedule to edit it, or add a new one.",
                systemImage: "clock"
            )
        }
    }

    @ViewBuilder
    private var skillDetail: some View {
        if let skill = store.loadedSkill?.summary ?? store.selectedSkill {
            MacSkillInspector(store: store, skill: skill)
        } else {
            MacShellEmptyDetail(
                title: "Select a Skill",
                message: "Choose a Skill to inspect or enable it.",
                systemImage: "sparkles.rectangle.stack"
            )
        }
    }

    @ViewBuilder
    private var extensionDetail: some View {
        if let resource = store.loadedExtension?.summary ?? store.selectedExtension {
            MacExtensionInspector(store: store, resource: resource)
        } else {
            MacShellEmptyDetail(
                title: "Select an Extension",
                message: "Choose an Extension to inspect or enable it.",
                systemImage: "shippingbox"
            )
        }
    }
}

private struct MacAgentEditor: View {
    @Bindable var store: MacCatalogStore
    @State private var error: String?

    var body: some View {
        Form {
            Section("Agent") {
                TextField("Name", text: draftBinding(\.name))
                TextField("Description", text: draftBinding(\.description), axis: .vertical)
                    .lineLimit(2...4)
            }
            Section("Instructions") {
                Picker("Mode", selection: draftBinding(\.instructionMode)) {
                    Text("Append").tag(AgentInstructionMode.append)
                    Text("Replace").tag(AgentInstructionMode.replace)
                }
                TextEditor(text: draftBinding(\.instructionText))
                    .font(.body)
                    .frame(minHeight: 160)
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(store.isCreatingAgent ? "New Agent" : store.agentDraft?.name ?? "Agent")
        .toolbar {
            ToolbarItem {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(!(store.agentDraft?.canSave ?? false) || store.isSaving)
            }
            if !store.isCreatingAgent {
                ToolbarItem {
                    Button("Edit with Oppi") {
                        Task { await store.beginReviseSelectedAgentControlSession() }
                    }
                    .disabled(store.isSaving)
                    .help("Revise this Agent with Oppi")
                    .accessibilityIdentifier("mac.catalog.editWithOppi")
                }
                ToolbarItem {
                    Button("Archive", role: .destructive) {
                        Task { await archive() }
                    }
                    .disabled(store.isSaving)
                }
            }
        }
    }

    private func draftBinding<Value>(_ keyPath: WritableKeyPath<MacAgentEditorDraft, Value>) -> Binding<Value> {
        Binding(
            get: { store.agentDraft?[keyPath: keyPath] ?? MacAgentEditorDraft.blank()[keyPath: keyPath] },
            set: { newValue in
                if store.agentDraft == nil {
                    store.agentDraft = .blank()
                }
                store.agentDraft?[keyPath: keyPath] = newValue
            }
        )
    }

    private func save() async {
        guard let draft = store.agentDraft else { return }
        do {
            try await store.saveAgent(draft)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func archive() async {
        do {
            try await store.archiveSelectedAgent()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct MacScheduleEditor: View {
    @Bindable var store: MacCatalogStore
    @State private var error: String?

    var body: some View {
        Form {
            Section("Schedule") {
                TextField("Name", text: draftBinding(\.name))
                Picker("Workspace", selection: draftBinding(\.workspaceId)) {
                    if store.workspaces.isEmpty {
                        Text("No workspaces").tag("")
                    }
                    ForEach(store.workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
                if store.isCreatingSchedule || store.scheduleDraft?.existingTrigger == nil {
                    Picker("Repeat", selection: draftBinding(\.cadence)) {
                        ForEach(MacScheduleEditorDraft.Cadence.allCases) { cadence in
                            Text(cadence.title).tag(cadence)
                        }
                    }
                } else if let trigger = store.scheduleDraft?.existingTrigger {
                    LabeledContent("Repeat", value: trigger.detailTimingSummary())
                }
            }
            Section("Prompt") {
                TextEditor(text: draftBinding(\.prompt))
                    .font(.body)
                    .frame(minHeight: 140)
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(store.isCreatingSchedule ? "New Schedule" : store.scheduleDraft?.name ?? "Schedule")
        .toolbar {
            ToolbarItem {
                Button("Save") {
                    Task { await save() }
                }
                .disabled(!(store.scheduleDraft?.canSave ?? false) || store.isSaving)
            }
            if !store.isCreatingSchedule {
                ToolbarItem {
                    Button("Edit with Oppi") {
                        Task { await store.beginReviseSelectedScheduleControlSession() }
                    }
                    .disabled(store.isSaving)
                    .help("Revise this Schedule with Oppi")
                    .accessibilityIdentifier("mac.catalog.editWithOppi")
                }
            }
            if !store.isCreatingSchedule, let status = store.selectedSchedule?.status {
                ToolbarItem {
                    scheduleStatusButton(status)
                }
            }
        }
    }

    @ViewBuilder
    private func scheduleStatusButton(_ status: AgentScheduleStatus) -> some View {
        switch status {
        case .active:
            Button("Pause") {
                Task { await setStatus(.paused) }
            }
            .disabled(store.isSaving)
        case .paused:
            Button("Resume") {
                Task { await setStatus(.active) }
            }
            .disabled(store.isSaving)
        case .archived:
            Button("Restore") {
                Task { await setStatus(.active) }
            }
            .disabled(store.isSaving)
        }
    }

    private func draftBinding<Value>(_ keyPath: WritableKeyPath<MacScheduleEditorDraft, Value>) -> Binding<Value> {
        Binding(
            get: {
                store.scheduleDraft?[keyPath: keyPath]
                    ?? MacScheduleEditorDraft.blank(workspaceId: "")[keyPath: keyPath]
            },
            set: { newValue in
                if store.scheduleDraft == nil {
                    store.scheduleDraft = .blank(workspaceId: store.workspaces.first?.id ?? "")
                }
                store.scheduleDraft?[keyPath: keyPath] = newValue
            }
        )
    }

    private func save() async {
        guard let draft = store.scheduleDraft else { return }
        do {
            try await store.saveSchedule(draft)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setStatus(_ status: AgentScheduleStatus) async {
        do {
            try await store.setSelectedScheduleStatus(status)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct MacSkillInspector: View {
    @Bindable var store: MacCatalogStore
    let skill: ServerSkillSummary
    @State private var error: String?

    var body: some View {
        Form {
            Section("Skill") {
                LabeledContent("Name", value: skill.name)
                LabeledContent("Source", value: skill.provenance.label)
                if let packageName = skill.packageName {
                    LabeledContent("Package", value: packageName)
                }
                Toggle("Enabled", isOn: enabledBinding)
                    .disabled(store.isSaving || skill.state == .error)
            }
            if !skill.description.isEmpty {
                Section("Description") {
                    Text(skill.description)
                }
            }
            if let loadError = skill.loadError, !loadError.isEmpty {
                Section("Error") {
                    Text(loadError)
                        .foregroundStyle(.red)
                }
            }
            if let markdown = store.loadedSkill?.skillMarkdown, !markdown.isEmpty {
                Section("SKILL.md") {
                    Text(markdown)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(skill.name)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { skill.state == .enabled },
            set: { newValue in
                Task {
                    do {
                        try await store.setSelectedSkillEnabled(newValue)
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        )
    }
}

private struct MacExtensionInspector: View {
    @Bindable var store: MacCatalogStore
    let resource: ServerExtensionSummary
    @State private var error: String?

    var body: some View {
        Form {
            Section("Extension") {
                LabeledContent("Name", value: resource.name)
                LabeledContent("Source", value: resource.provenance.label)
                if let packageName = resource.packageName {
                    LabeledContent("Package", value: packageName)
                }
                if resource.kind != .builtIn {
                    Toggle("Enabled", isOn: enabledBinding)
                        .disabled(store.isSaving || resource.state == .error)
                } else {
                    LabeledContent("State", value: MacCatalogExtensionListPresentation.stateLabel(for: resource.state))
                }
            }
            if let description = resource.description, !description.isEmpty {
                Section("Description") {
                    Text(description)
                }
            }
            let tools = store.loadedExtension?.contributedToolDetails
                ?? resource.contributedToolDetails
                ?? []
            if !tools.isEmpty {
                Section("Tools") {
                    ForEach(tools) { tool in
                        LabeledContent(tool.name, value: tool.description ?? "")
                    }
                }
            }
            if let loadError = resource.loadError, !loadError.isEmpty {
                Section("Error") {
                    Text(loadError)
                        .foregroundStyle(.red)
                }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(resource.name)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { resource.state == .on },
            set: { newValue in
                Task {
                    do {
                        try await store.setSelectedExtensionEnabled(newValue)
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        )
    }
}

struct MacControlSessionLaunchSheet: View {
    @Bindable var store: MacCatalogStore
    let onOpenSession: (MacSelectedSessionTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if store.controlLaunchDraft?.domain != .workspaces {
                        Picker("Workspace", selection: workspaceIDBinding) {
                            if store.workspaces.isEmpty {
                                Text("No workspaces").tag("")
                            }
                            ForEach(store.workspaces) { workspace in
                                Text(workspace.name).tag(workspace.id)
                            }
                        }
                    }
                    TextEditor(text: requestBinding)
                        .font(.body)
                        .frame(minHeight: 140)
                } header: {
                    Text(store.controlLaunchDraft?.placeholder ?? "Describe the outcome you want…")
                } footer: {
                    if store.controlLaunchDraft?.domain != .workspaces {
                        Text("The selected workspace is prompt context only. Oppi inspects and updates server-owned definitions.")
                    }
                }
                if let message = error ?? store.controlLaunchError {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(store.isLaunchingControlSession)
            .navigationTitle(store.controlLaunchDraft?.title ?? "Ask Oppi")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.cancelControlSessionLaunch()
                        dismiss()
                    }
                    .disabled(store.isLaunchingControlSession)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task { await send() }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!(store.controlLaunchDraft?.canSubmit ?? false) || store.isLaunchingControlSession)
                    .accessibilityIdentifier("mac.guided.send")
                }
            }
        }
        .frame(minWidth: 440, minHeight: 360)
        .interactiveDismissDisabled(store.isLaunchingControlSession)
    }

    private var workspaceIDBinding: Binding<String> {
        Binding(
            get: { store.controlLaunchDraft?.workspaceId ?? "" },
            set: { newValue in
                guard let workspace = store.workspaces.first(where: { $0.id == newValue }) else { return }
                store.selectControlLaunchWorkspace(workspace)
            }
        )
    }

    private var requestBinding: Binding<String> {
        Binding(
            get: { store.controlLaunchDraft?.userRequest ?? "" },
            set: { store.controlLaunchDraft?.userRequest = $0 }
        )
    }

    private func send() async {
        do {
            let target = try await store.launchControlSession()
            error = nil
            if store.controlLaunchDraft == nil {
                onOpenSession(target)
                dismiss()
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}
