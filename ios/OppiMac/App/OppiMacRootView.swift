import SwiftUI

struct OppiMacRootView: View {
    @Bindable var store: OppiMacStore
    @FocusState private var focusedColumn: OppiMacStore.FocusColumn?

    var body: some View {
        Group {
            if store.isConnected {
                connectedView
            } else {
                ConnectionSetupView(store: store)
            }
        }
        .onChange(of: store.requestedFocusColumn) { _, newValue in
            guard let newValue else { return }

            if newValue == .inspector {
                focusedColumn = .timeline
            } else {
                focusedColumn = newValue
            }
            store.requestedFocusColumn = nil
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { store.lastErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.lastErrorMessage = nil
                    }
                }
            ),
            actions: {
                Button("OK", role: .cancel) {
                    store.lastErrorMessage = nil
                }
            },
            message: {
                Text(store.lastErrorMessage ?? "")
            }
        )
    }

    private var connectedView: some View {
        NavigationSplitView {
            SessionSidebarView(store: store, focusedColumn: $focusedColumn)
        } detail: {
            TimelineColumnView(store: store, focusedColumn: $focusedColumn)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct ConnectionSetupView: View {
    @Bindable var store: OppiMacStore

    var body: some View {
        VStack(spacing: 18) {
            Text("OppiMac")
                .font(.largeTitle)
                .fontWeight(.semibold)

            Text("Connect to your pi-remote server")
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Host")
                    TextField("localhost", text: $store.draft.host)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("Port")
                    TextField("7749", text: $store.draft.port)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("Token")
                    SecureField("Bearer token", text: $store.draft.token)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("Label")
                    TextField("Chen", text: $store.draft.name)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .frame(maxWidth: 560)

            HStack(spacing: 12) {
                Button("Connect") {
                    Task {
                        await store.connect()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.isConnecting)

                if store.isConnecting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(28)
        .frame(minWidth: 860, minHeight: 520)
    }
}

private struct SessionSidebarView: View {
    @Bindable var store: OppiMacStore
    @FocusState.Binding var focusedColumn: OppiMacStore.FocusColumn?
    @State private var workspaceEditorMode: WorkspaceEditorMode?
    @State private var showWorkspaceDeleteConfirmation = false
    @State private var showSkillsBrowser = false

    private enum WorkspaceEditorMode: Identifiable {
        case create
        case edit(Workspace)

        var id: String {
            switch self {
            case .create:
                return "create"
            case .edit(let workspace):
                return "edit-\(workspace.id)-\(workspace.updatedAt.timeIntervalSince1970)"
            }
        }
    }

    private var workspaceSelection: Binding<String?> {
        Binding(
            get: { store.selectedWorkspaceID },
            set: { newValue in
                Task {
                    await store.selectWorkspace(newValue)
                }
            }
        )
    }

    private var sessionSelection: Binding<String?> {
        Binding(
            get: { store.selectedSessionID },
            set: { newValue in
                store.selectedSessionID = newValue
                Task {
                    await store.loadTimelineForCurrentSelection()
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.currentUserName ?? "Connected")
                        .font(.headline)
                    if let host = store.draft.host.split(separator: ":").first {
                        Text("\(host):\(store.draft.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Menu {
                    Button("Browse Skills…") {
                        showSkillsBrowser = true
                    }

                    Divider()

                    Button("Disconnect", role: .destructive) {
                        store.disconnect()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Workspace")
                        .font(.headline)

                    Spacer()

                    if store.isLoadingWorkspaces {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Menu {
                        Button("New Workspace") {
                            workspaceEditorMode = .create
                        }

                        Button("Edit Selected Workspace") {
                            if let selectedWorkspace = store.selectedWorkspace {
                                workspaceEditorMode = .edit(selectedWorkspace)
                            }
                        }
                        .disabled(store.selectedWorkspace == nil)

                        Button("Delete Selected Workspace", role: .destructive) {
                            showWorkspaceDeleteConfirmation = true
                        }
                        .disabled(store.selectedWorkspace == nil)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                }

                if store.workspaces.isEmpty {
                    Text("No workspaces found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Workspace", selection: workspaceSelection) {
                        ForEach(store.workspaces) { workspace in
                            Text(workspace.name)
                                .tag(Optional(workspace.id))
                        }
                    }
                    .labelsHidden()
                    .disabled(store.isLoadingWorkspaces)
                }

                if let selectedWorkspace = store.selectedWorkspace {
                    Text("\(selectedWorkspace.runtime.capitalized) · policy \(selectedWorkspace.policyPreset)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Sessions")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                if store.isLoadingSessions {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            List(selection: sessionSelection) {
                ForEach(store.sessions) { session in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sessionDisplayName(session))
                            .lineLimit(1)
                        Text("\(session.status.rawValue.capitalized) · \(session.lastActivity.relativeString())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(session.id)
                }
            }
            .listStyle(.sidebar)
            .focused($focusedColumn, equals: .sessions)

            HStack {
                Button("New") {
                    Task {
                        await store.createSessionInSelectedWorkspace()
                    }
                }
                .disabled(store.selectedWorkspaceID == nil)

                Button("Refresh") {
                    Task {
                        await store.refreshSessions()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Resume") {
                    Task {
                        await store.resumeSelectedSession()
                    }
                }
                .disabled(store.selectedSession?.status != .stopped)

                Button("Stop") {
                    Task {
                        await store.stopSelectedSession()
                    }
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(store.selectedSession == nil)

                Button("Delete", role: .destructive) {
                    Task {
                        await store.deleteSelectedSession()
                    }
                }
                .disabled(store.selectedSession == nil)
            }
        }
        .padding(12)
        .sheet(item: $workspaceEditorMode) { mode in
            switch mode {
            case .create:
                WorkspaceEditorSheet(
                    title: "New Workspace",
                    confirmTitle: "Create",
                    initialName: "",
                    initialDescription: "",
                    initialRuntime: "container",
                    initialPolicyPreset: "container",
                    onSave: { name, description, runtime, policyPreset in
                        Task {
                            await store.createWorkspace(
                                name: name,
                                description: description,
                                runtime: runtime,
                                policyPreset: policyPreset
                            )
                        }
                    }
                )
            case .edit(let workspace):
                WorkspaceEditorSheet(
                    title: "Edit Workspace",
                    confirmTitle: "Save",
                    initialName: workspace.name,
                    initialDescription: workspace.description ?? "",
                    initialRuntime: workspace.runtime,
                    initialPolicyPreset: workspace.policyPreset,
                    onSave: { name, description, runtime, policyPreset in
                        Task {
                            await store.updateSelectedWorkspace(
                                name: name,
                                description: description,
                                runtime: runtime,
                                policyPreset: policyPreset
                            )
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $showSkillsBrowser) {
            SkillsBrowserSheet(store: store)
        }
        .confirmationDialog(
            "Delete selected workspace?",
            isPresented: $showWorkspaceDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await store.deleteSelectedWorkspace()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the workspace and clears its sessions from this view.")
        }
    }

    private func sessionDisplayName(_ session: Session) -> String {
        if let name = session.name,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return session.id
    }
}

private struct WorkspaceEditorSheet: View {
    let title: String
    let confirmTitle: String
    let initialName: String
    let initialDescription: String
    let initialRuntime: String
    let initialPolicyPreset: String
    let onSave: (String, String?, String, String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var description: String
    @State private var runtime: String
    @State private var policyPreset: String

    init(
        title: String,
        confirmTitle: String,
        initialName: String,
        initialDescription: String,
        initialRuntime: String,
        initialPolicyPreset: String,
        onSave: @escaping (String, String?, String, String) -> Void
    ) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.initialName = initialName
        self.initialDescription = initialDescription
        self.initialRuntime = initialRuntime
        self.initialPolicyPreset = initialPolicyPreset
        self.onSave = onSave

        _name = State(initialValue: initialName)
        _description = State(initialValue: initialDescription)
        _runtime = State(initialValue: initialRuntime)
        _policyPreset = State(initialValue: initialPolicyPreset)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $description)
                }

                Section("Runtime") {
                    Picker("Runtime", selection: $runtime) {
                        Text("Container").tag("container")
                        Text("Host").tag("host")
                    }
                    .pickerStyle(.segmented)

                    Picker("Preset", selection: $policyPreset) {
                        ForEach(policyOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(
                            trimmedName,
                            trimmedDescription.isEmpty ? nil : trimmedDescription,
                            runtime,
                            policyPreset
                        )
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: runtime) { _, newRuntime in
                normalizePolicyPreset(for: newRuntime)
            }
        }
        .frame(minWidth: 420, minHeight: 280)
    }

    private var policyOptions: [(label: String, value: String)] {
        if runtime == "host" {
            return [("Host", "host"), ("Container", "container")]
        }

        return [("Container", "container"), ("Host", "host")]
    }

    private func normalizePolicyPreset(for runtime: String) {
        let allowed = Set(policyOptions.map(\.value))
        guard !allowed.contains(policyPreset) else { return }
        policyPreset = runtime == "host" ? "host" : "container"
    }
}

private struct SkillsBrowserSheet: View {
    @Bindable var store: OppiMacStore

    private var selectedSkillBinding: Binding<String?> {
        Binding(
            get: { store.selectedSkillName },
            set: { newValue in
                Task {
                    await store.selectSkill(newValue)
                }
            }
        )
    }

    private var selectedFileBinding: Binding<String> {
        Binding(
            get: { store.selectedSkillFilePath ?? "SKILL.md" },
            set: { newValue in
                Task {
                    await store.selectSkillFile(newValue == "SKILL.md" ? nil : newValue)
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selectedSkillBinding) {
                ForEach(store.skills) { skill in
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
                    .tag(Optional(skill.name))
                }
            }
            .overlay {
                if store.isLoadingSkills && store.skills.isEmpty {
                    ProgressView("Loading skills…")
                }
            }
        } detail: {
            if let detail = store.selectedSkillDetail {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(detail.skill.name)
                                .font(.title3)
                                .fontWeight(.semibold)
                            Text(detail.skill.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if store.isLoadingSkillDetail || store.isLoadingSkillFile {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if !detail.files.isEmpty {
                        Picker("File", selection: selectedFileBinding) {
                            Text("SKILL.md")
                                .tag("SKILL.md")
                            ForEach(detail.files, id: \.self) { file in
                                Text(file).tag(file)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    ScrollView {
                        Text(store.selectedSkillFileContent.isEmpty ? "(empty)" : store.selectedSkillFileContent)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .background(.background)
                }
                .padding(14)
            } else {
                ContentUnavailableView(
                    "Select a skill",
                    systemImage: "sparkles",
                    description: Text("Choose a skill to inspect SKILL.md and files.")
                )
            }
        }
        .frame(minWidth: 900, minHeight: 540)
        .task {
            await store.loadSkills()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Refresh") {
                    Task {
                        await store.loadSkills()
                    }
                }
            }
        }
    }
}

private struct TimelineColumnView: View {
    @Bindable var store: OppiMacStore
    @FocusState.Binding var focusedColumn: OppiMacStore.FocusColumn?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Timeline")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("\(store.filteredTimelineItems.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Circle()
                        .fill(streamStatusColor)
                        .frame(width: 8, height: 8)
                    Text(streamStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                TextField("Search timeline", text: $store.timelineSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)

                Menu("Kinds") {
                    ForEach(ReviewTimelineKind.allCases) { kind in
                        Toggle(isOn: kindBinding(kind)) {
                            Label(kind.label, systemImage: kind.symbolName)
                        }
                    }
                }

                Menu {
                    Button("Smaller Text") {
                        store.decreaseTimelineTextScale()
                    }

                    Button("Larger Text") {
                        store.increaseTimelineTextScale()
                    }

                    Button("Reset Text Size") {
                        store.resetTimelineTextScale()
                    }
                } label: {
                    Label("\(Int((store.timelineTextScale * 100).rounded()))%", systemImage: "textformat.size")
                }
                .help("Adjust chat text size")

            }

            if !store.selectedSessionPendingPermissions.isEmpty {
                timelinePermissionQueue
            }

            if store.isLoadingTimeline {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading timeline…")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)
            }

            if timelineRows.isEmpty {
                ContentUnavailableView(
                    "No timeline events",
                    systemImage: "text.append",
                    description: Text("Send a prompt or select a different session.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AppKitTimelineView(
                    rows: timelineRows,
                    selectedID: store.selectedTimelineItemID,
                    textScale: CGFloat(store.timelineTextScale),
                    onSelectionChange: { selectedID in
                        store.selectedTimelineItemID = selectedID
                    }
                )
                .focused($focusedColumn, equals: .timeline)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                AppKitComposerTextView(
                    text: $store.composerText,
                    focusToken: store.composerFocusRequestID,
                    textScale: CGFloat(store.timelineTextScale),
                    onSubmit: {
                        Task {
                            await store.sendPromptFromComposer()
                        }
                    }
                )
                .frame(minHeight: 42, maxHeight: 160)

                Button("Send") {
                    Task {
                        await store.sendPromptFromComposer()
                    }
                }
                .disabled(store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSendingPrompt)

                Button("Stop Turn") {
                    Task {
                        await store.sendStopTurn()
                    }
                }
                .disabled(!store.isStreamConnected)
            }
        }
        .padding(12)
    }

    private var timelineRows: [OppiMacTimelineRow] {
        OppiMacTimelineRowBuilder.build(from: store.filteredTimelineItems)
    }

    private var streamStatusText: String {
        if store.isStreamConnected {
            return "Live"
        }
        if store.isStreamConnecting {
            return "Connecting"
        }
        return "Offline"
    }

    private var streamStatusColor: Color {
        if store.isStreamConnected {
            return .green
        }
        if store.isStreamConnecting {
            return .orange
        }
        return .secondary
    }

    private var timelinePermissionQueue: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Pending Permissions", systemImage: "hand.raised.fill")
                    .font(.headline)
                Spacer()
                Text("\(store.selectedSessionPendingPermissions.count)")
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }

            ForEach(store.selectedSessionPendingPermissions) { request in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(request.tool)
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        Text(request.risk.rawValue.uppercased())
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(permissionRiskColor(request.risk).opacity(0.18), in: Capsule())
                            .foregroundStyle(permissionRiskColor(request.risk))

                        Spacer()

                        if request.hasExpiry {
                            Text("Expires \(request.timeoutAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No expiry")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(request.displaySummary)
                        .font(.caption)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        Button("Allow") {
                            Task {
                                await store.respondToPermission(id: request.id, action: .allow)
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Deny", role: .destructive) {
                            Task {
                                await store.respondToPermission(id: request.id, action: .deny)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func permissionRiskColor(_ risk: RiskLevel) -> Color {
        switch risk {
        case .low:
            return .green
        case .medium:
            return .orange
        case .high, .critical:
            return .red
        }
    }

    private func kindBinding(_ kind: ReviewTimelineKind) -> Binding<Bool> {
        Binding(
            get: { store.selectedKinds.contains(kind) },
            set: { _ in store.toggleKind(kind) }
        )
    }
}

private struct InspectorColumnView: View {
    @Bindable var store: OppiMacStore
    @FocusState.Binding var focusedColumn: OppiMacStore.FocusColumn?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.selectedSessionPendingPermissions.isEmpty {
                ScrollView {
                    pendingPermissionsSection
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 6)
                }

                Divider()
            }

            AppKitInspectorDetailView(document: inspectorDocument)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .focused($focusedColumn, equals: .inspector)
    }

    private var inspectorDocument: OppiMacInspectorDocument? {
        guard let item = store.selectedTimelineItem else {
            return nil
        }
        return OppiMacInspectorDocumentBuilder.build(from: item)
    }

    private var pendingPermissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pending Permissions")
                .font(.headline)

            ForEach(store.selectedSessionPendingPermissions) { request in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(request.tool)
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        Text(request.risk.rawValue.uppercased())
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(riskColor(request.risk).opacity(0.18), in: Capsule())
                            .foregroundStyle(riskColor(request.risk))

                        Spacer()

                        if request.hasExpiry {
                            Text("Expires \(request.timeoutAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No expiry")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(request.displaySummary)
                        .font(.caption)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        Button("Allow") {
                            Task {
                                await store.respondToPermission(id: request.id, action: .allow)
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Deny", role: .destructive) {
                            Task {
                                await store.respondToPermission(id: request.id, action: .deny)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func riskColor(_ risk: RiskLevel) -> Color {
        switch risk {
        case .low:
            return .green
        case .medium:
            return .orange
        case .high, .critical:
            return .red
        }
    }
}

