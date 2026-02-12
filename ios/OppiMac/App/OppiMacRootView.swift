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

    private struct SessionTreeRowModel: Identifiable {
        let session: Session
        let depth: Int
        let hasChildren: Bool

        var id: String { session.id }
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

            HStack {
                Text("Workspaces")
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

            List {
                if store.workspaces.isEmpty {
                    Text("No workspaces found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.workspaces) { workspace in
                        let isSelectedWorkspace = store.selectedWorkspaceID == workspace.id

                        Button {
                            Task {
                                await store.selectWorkspace(workspace.id)
                            }
                        } label: {
                            SidebarWorkspaceRow(
                                workspace: workspace,
                                isSelected: isSelectedWorkspace,
                                sessionCount: isSelectedWorkspace ? store.sessions.count : nil
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            isSelectedWorkspace
                                ? Color(nsColor: OppiMacTheme.current.selection).opacity(0.4)
                                : Color.clear
                        )

                        if isSelectedWorkspace {
                            if store.isLoadingSessions {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Loading sessions…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.leading, 24)
                            } else {
                                let rows = flattenedSessionRows(from: store.selectedWorkspaceSessionTree)

                                if rows.isEmpty {
                                    Text("No sessions")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 24)
                                } else {
                                    ForEach(rows) { row in
                                        Button {
                                            Task {
                                                store.selectedSessionID = row.session.id
                                                await store.loadTimelineForCurrentSelection()
                                            }
                                        } label: {
                                            SidebarSessionTreeRow(
                                                session: row.session,
                                                depth: row.depth,
                                                hasChildren: row.hasChildren,
                                                isSelected: row.session.id == store.selectedSessionID,
                                                pendingPermissionCount: pendingPermissionCount(for: row.session.id)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .listRowBackground(
                                            row.session.id == store.selectedSessionID
                                                ? Color(nsColor: OppiMacTheme.current.selection).opacity(0.22)
                                                : Color.clear
                                        )
                                    }
                                }
                            }

                            if store.isLoadingWorkspaceGraph {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Updating session tree…")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.leading, 24)
                            }
                        }
                    }
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

    private func pendingPermissionCount(for sessionID: String) -> Int {
        store.pendingPermissions.filter { $0.sessionId == sessionID }.count
    }

    private func flattenedSessionRows(from roots: [OppiMacSessionTreeNode]) -> [SessionTreeRowModel] {
        var rows: [SessionTreeRowModel] = []
        for root in roots {
            appendSessionRows(node: root, depth: 0, output: &rows)
        }
        return rows
    }

    private func appendSessionRows(
        node: OppiMacSessionTreeNode,
        depth: Int,
        output: inout [SessionTreeRowModel]
    ) {
        output.append(
            .init(
                session: node.session,
                depth: depth,
                hasChildren: !node.children.isEmpty
            )
        )

        for child in node.children {
            appendSessionRows(node: child, depth: depth + 1, output: &output)
        }
    }
}

private struct SidebarWorkspaceRow: View {
    let workspace: Workspace
    let isSelected: Bool
    let sessionCount: Int?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: workspace.runtime == "host" ? "desktopcomputer" : "shippingbox")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)

                Text("\(workspace.runtime.capitalized) · policy \(workspace.policyPreset)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let sessionCount {
                Text("\(sessionCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct SidebarSessionTreeRow: View {
    let session: Session
    let depth: Int
    let hasChildren: Bool
    let isSelected: Bool
    let pendingPermissionCount: Int

    private var title: String {
        if let name = session.name,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return session.id
    }

    private var statusText: String {
        "\(session.status.rawValue.capitalized) · \(session.lastActivity.relativeString())"
    }

    private var statusColor: Color {
        switch session.status {
        case .ready:
            return .green
        case .busy, .starting, .stopping:
            return .orange
        case .stopped:
            return .secondary
        case .error:
            return .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if depth > 0 {
                Color.clear
                    .frame(width: CGFloat(depth) * 16)
            }

            Image(systemName: hasChildren ? "arrow.triangle.branch" : "circle.fill")
                .font(.system(size: hasChildren ? 11 : 6, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)

                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if pendingPermissionCount > 0 {
                Text("\(pendingPermissionCount)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.15), in: Capsule())
            }
        }
        .padding(.vertical, 2)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label("Timeline", systemImage: "text.alignleft")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(itemCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(streamStatusColor)
                        .frame(width: 7, height: 7)
                    Text(streamStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 8) {
                TextField("Search timeline", text: $store.timelineSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)

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

                Spacer()
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

            if store.hiddenTimelineItemCount > 0 {
                HStack(spacing: 10) {
                    Text("\(store.hiddenTimelineItemCount) earlier items hidden")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Show Earlier") {
                        store.showEarlierTimelineItems()
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    autoFollowTail: true,
                    onSelectionChange: { selectedID in
                        store.selectedTimelineItemID = selectedID
                    }
                )
                .focused($focusedColumn, equals: .timeline)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

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
                .buttonStyle(.borderedProminent)
                .disabled(store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSendingPrompt)

                Button("Stop") {
                    Task {
                        await store.sendStopTurn()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!store.isStreamConnected)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(12)
    }

    private var timelineRows: [OppiMacTimelineRow] {
        OppiMacTimelineRowBuilder.build(from: store.renderedTimelineItems)
    }

    private var itemCountLabel: String {
        let visible = store.renderedTimelineItems.count
        let total = store.filteredTimelineItems.count
        if store.hiddenTimelineItemCount > 0 {
            return "\(visible)/\(total) items"
        }
        return "\(total) items"
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
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

