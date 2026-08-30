import AppKit
import SwiftUI

struct WorkspaceShellList: View {
    let workspaces: [Workspace]
    let summaries: [String: WorkspaceListSummary]
    let isLoading: Bool
    let isCreatingWorkspace: Bool
    let lastError: String?
    let createWorkspaceError: String?
    @Binding var selectedWorkspaceID: String?
    let refresh: () async -> Void
    let createWorkspace: (MacWorkspaceCreationDraft) async -> Workspace?
    let beginCreateControlSession: () async -> Void

    @State private var isPresentingCreateWorkspace = false
    @State private var createDraft = MacWorkspaceCreationDraft()

    var body: some View {
        List(selection: $selectedWorkspaceID) {
            Section("Workspaces") {
                if workspaces.isEmpty {
                    ContentUnavailableView(
                        lastError == nil ? "No workspaces" : "Could not load workspaces",
                        systemImage: "folder",
                        description: Text(lastError ?? "Start or attach the local server to load workspace summaries.")
                    )
                } else {
                    ForEach(workspaces) { workspace in
                        WorkspaceRow(
                            workspace: workspace,
                            summary: summaries[workspace.id]
                        )
                        .tag(workspace.id)
                    }
                }
            }
        }
        .navigationTitle("Workspaces")
        .toolbar {
            ToolbarItem {
                Button {
                    isPresentingCreateWorkspace = true
                } label: {
                    Label("Create Workspace", systemImage: "plus")
                }
                .disabled(isCreatingWorkspace)
            }
            ToolbarItem {
                Button {
                    Task { await beginCreateControlSession() }
                } label: {
                    Label("Ask Oppi", systemImage: "text.bubble")
                }
                .help("Create with Oppi")
                .accessibilityIdentifier("mac.workspace.askOppi")
                .disabled(isCreatingWorkspace)
            }
            ToolbarItem {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh Workspaces", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .sheet(isPresented: $isPresentingCreateWorkspace) {
            MacWorkspaceCreateSheet(
                title: "Create Workspace",
                message: "Add an existing local folder to the Mac client. Leave the folder blank for a server-managed workspace.",
                submitTitle: "Create",
                draft: $createDraft,
                isSaving: isCreatingWorkspace,
                error: createWorkspaceError,
                cancel: {
                    isPresentingCreateWorkspace = false
                    createDraft = MacWorkspaceCreationDraft()
                },
                save: {
                    if let workspace = await createWorkspace(createDraft) {
                        selectedWorkspaceID = workspace.id
                        createDraft = MacWorkspaceCreationDraft()
                        isPresentingCreateWorkspace = false
                    }
                }
            )
        }
        .overlay(alignment: .bottom) {
            if isLoading {
                ProgressView("Loading workspaces...")
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
            }
        }
    }
}

private struct MacWorkspaceCreateSheet: View {
    let title: String
    let message: String
    let submitTitle: String
    @Binding var draft: MacWorkspaceCreationDraft
    let isSaving: Bool
    let error: String?
    let cancel: () -> Void
    let save: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(message)
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Name", text: $draft.name)
                TextField("Local folder path", text: $draft.hostMount)
                TextField("Description", text: $draft.description, axis: .vertical)
                    .lineLimit(2...4)
                Toggle("Show workspace changes in chat", isOn: $draft.gitStatusEnabled)
                Picker("Runtime", selection: $draft.runtime) {
                    Text("Host").tag(WorkspaceRuntime.host)
                    Text("Sandbox").tag(WorkspaceRuntime.sandbox)
                }
                .pickerStyle(.segmented)
                .disabled(true)
                Text("Sandbox creation needs the full VM configuration flow and stays disabled in this Mac slice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            if let message = draft.validationMessage, !draft.canSubmit {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { cancel() }
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(submitTitle)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || !draft.canSubmit)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct WorkspaceRow: View {
    let workspace: Workspace
    let summary: WorkspaceListSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(workspace.name, systemImage: workspace.iconSymbolName)
                .font(.headline)
            HStack(spacing: 8) {
                if let summary {
                    Text("\(summary.activeCount) active")
                    Text("\(summary.stoppedCount) stopped")
                    if summary.hasAttention {
                        Label("Needs attention", systemImage: "exclamationmark.circle")
                            .labelStyle(.titleAndIcon)
                    }
                } else {
                    Text(workspace.hostMount ?? "No summary yet")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct WorkspaceShellDetail: View {
    let workspace: Workspace
    let summary: WorkspaceListSummary?
    let sessions: MacWorkspaceClient.WorkspaceSessionList?
    let isLoadingSessions: Bool
    let isCreatingSession: Bool
    let isSavingWorkspace: Bool
    let isDeletingWorkspace: Bool
    let sessionError: String?
    let createSessionError: String?
    let editWorkspaceError: String?
    let workspaceActionError: String?
    let sessionActionError: (String) -> String?
    let isStoppingSession: (String) -> Bool
    let isDeletingSession: (String) -> Bool
    let refreshSessions: (String) async -> Void
    let createSession: (String, String) async -> Void
    let updateWorkspace: (MacWorkspaceCreationDraft) async -> Workspace?
    let beginReviseControlSession: () async -> Void
    let deleteWorkspace: () async -> Void
    let stopSession: (SessionSummary) async -> Void
    let deleteSession: (SessionSummary) async -> Void
    let selectSession: (SessionSummary) -> Void

    @State private var newSessionPrompt = ""
    @State private var isPresentingEditWorkspace = false
    @State private var editDraft = MacWorkspaceCreationDraft()
    @State private var isConfirmingWorkspaceDeletion = false
    @State private var sessionPendingDeletion: SessionSummary?
    @State private var openPlan: FileViewerPlan?
    @State private var openDescriptor: ToolContentDescriptor?
    @State private var isLoadingDocument = false
    @State private var documentError: String?
    @State private var isImportingLocal = false
    @State private var importLocalError: String?
    @State private var importedLocalPaths: Set<String> = []
    @State private var worktrees: [WorkspaceWorktree] = []
    @State private var selectedWorktreeId = WorkspaceWorktree.mainId
    @State private var isLoadingWorktrees = false

    var body: some View {
        HSplitView {
            workspaceDetail
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)

            if let plan = openPlan {
                MacToolDocumentColumn(
                    plan: plan,
                    descriptor: openDescriptor,
                    isLoading: isLoadingDocument,
                    error: documentError,
                    close: closeDocument
                )
                .frame(
                    minWidth: MacToolDocumentColumnMetrics.minWidth,
                    idealWidth: MacToolDocumentColumnMetrics.idealWidth,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
            }
        }
        .environment(\.macOpenFileViewer, MacOpenFileViewerAction { plan in
            openPlan = plan
        })
        .sheet(isPresented: $isPresentingEditWorkspace) {
            MacWorkspaceCreateSheet(
                title: "Edit Workspace",
                message: "Update the local workspace metadata used for new sessions and workspace lists.",
                submitTitle: "Save",
                draft: $editDraft,
                isSaving: isSavingWorkspace,
                error: editWorkspaceError,
                cancel: {
                    isPresentingEditWorkspace = false
                    editDraft = MacWorkspaceCreationDraft(workspace: workspace)
                },
                save: {
                    if await updateWorkspace(editDraft) != nil {
                        editDraft = MacWorkspaceCreationDraft(workspace: workspace)
                        isPresentingEditWorkspace = false
                    }
                }
            )
        }
        .confirmationDialog(
            "Delete Workspace?",
            isPresented: $isConfirmingWorkspaceDeletion
        ) {
            Button("Delete Workspace", role: .destructive) {
                Task { await deleteWorkspace() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \"\(workspace.name)\" from the local server workspace list. Session history for this workspace may become unreachable from the Mac shell.")
        }
        .confirmationDialog(
            "Delete Session?",
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { if !$0 { sessionPendingDeletion = nil } }
            ),
            presenting: sessionPendingDeletion
        ) { session in
            Button("Delete Session", role: .destructive) {
                Task {
                    await deleteSession(session)
                    sessionPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) {
                sessionPendingDeletion = nil
            }
        } message: { session in
            Text("Delete \"\(session.session.displayTitle)\" from local session history and generated attachments.")
        }
        .onChange(of: workspace.id) { _, _ in
            closeDocument()
            importedLocalPaths = []
            importLocalError = nil
            worktrees = []
            selectedWorktreeId = WorkspaceWorktree.mainId
        }
        .onChange(of: selectedWorktreeId) { _, newId in
            reopenDocumentForSelectedWorktree(newId)
        }
        .task(id: workspace.id) {
            await loadWorktrees()
        }
        .task(id: MacWorkspaceWorktreePresentation.sessionScope(
            workspaceId: workspace.id,
            selectedWorktreeId: selectedWorktreeId
        )) {
            await refreshSessions(selectedWorktreeId)
        }
        .task(id: openPlan) {
            await loadOpenedDocument()
        }
    }

    private var workspaceDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Label(workspace.name, systemImage: workspace.iconSymbolName)
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    editDraft = MacWorkspaceCreationDraft(workspace: workspace)
                    isPresentingEditWorkspace = true
                } label: {
                    Label("Edit Workspace", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSavingWorkspace || isDeletingWorkspace)
                Button {
                    Task { await beginReviseControlSession() }
                } label: {
                    Label("Edit with Oppi", systemImage: "text.bubble")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Revise this Workspace with Oppi")
                .accessibilityIdentifier("mac.workspace.editWithOppi")
                .disabled(isSavingWorkspace || isDeletingWorkspace)
                Button(role: .destructive) {
                    isConfirmingWorkspaceDeletion = true
                } label: {
                    if isDeletingWorkspace {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Delete Workspace", systemImage: "trash")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDeletingWorkspace)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let hostMount = workspace.hostMount, !hostMount.isEmpty {
                    Text(hostMount)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            worktreeSwitcher

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                if let summary {
                    GridRow {
                        Text("Active")
                            .foregroundStyle(.secondary)
                        Text(String(summary.activeCount))
                    }
                    GridRow {
                        Text("Stopped")
                            .foregroundStyle(.secondary)
                        Text(String(summary.stoppedCount))
                    }
                    GridRow {
                        Text("Attention")
                            .foregroundStyle(.secondary)
                        Text(summary.hasAttention ? "Yes" : "No")
                    }
                    if let latestActivity = summary.latestActivity {
                        GridRow {
                            Text("Latest")
                                .foregroundStyle(.secondary)
                            Text(latestActivity.relativeString())
                        }
                    }
                } else {
                    GridRow {
                        Text("Summary")
                            .foregroundStyle(.secondary)
                        Text("Not returned yet")
                    }
                }
            }
            .font(.callout)

            if let workspaceActionError {
                Label(workspaceActionError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            MacWorkspaceFileBrowserView(
                workspace: workspace,
                worktreeId: selectedWorktreeId,
                openPlan: $openPlan
            )

            MacWorkspaceGitStatusView(
                workspace: workspace,
                worktreeId: selectedWorktreeId,
                openPlan: $openPlan,
                openDescriptor: $openDescriptor,
                isLoadingDocument: $isLoadingDocument,
                documentError: $documentError
            )

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Start a local session")
                    .font(.headline)
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Ask Oppi to work in this workspace", text: $newSessionPrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    Button {
                        let prompt = newSessionPrompt
                        newSessionPrompt = ""
                        Task { await createSession(prompt, selectedWorktreeId) }
                    } label: {
                        if isCreatingSession {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Start")
                        }
                    }
                    .disabled(isCreatingSession || newSessionPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let createSessionError {
                    Label(createSessionError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Divider()

            HStack {
                Text("Recent sessions")
                    .font(.headline)
                if isImportingLocal {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button {
                    Task { await refreshSessions(selectedWorktreeId) }
                } label: {
                    Label("Refresh Sessions", systemImage: "arrow.clockwise")
                }
                .disabled(isLoadingSessions || isImportingLocal)
            }

            if let importLocalError {
                Label(importLocalError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if isLoadingSessions {
                ProgressView("Loading sessions...")
            } else if let sessionError {
                ContentUnavailableView(
                    "Could not load sessions",
                    systemImage: "exclamationmark.triangle",
                    description: Text(sessionError)
                )
            } else if sessions != nil, showsSessionList {
                List {
                    if !filteredActiveSessions.isEmpty {
                        Section("Active") {
                            ForEach(filteredActiveSessions, id: \.id) { session in
                                WorkspaceSessionActionRow(
                                    summary: session,
                                    actionError: sessionActionError(session.id),
                                    isStopping: isStoppingSession(session.id),
                                    isDeleting: isDeletingSession(session.id),
                                    selectSession: { selectSession(session) },
                                    stopSession: { await stopSession(session) },
                                    requestDelete: { sessionPendingDeletion = session }
                                )
                            }
                        }
                    }
                    if !filteredStoppedSessions.isEmpty || !visibleImportableSessions.isEmpty {
                        Section("Stopped") {
                            ForEach(filteredStoppedSessions, id: \.id) { session in
                                WorkspaceSessionActionRow(
                                    summary: session,
                                    actionError: sessionActionError(session.id),
                                    isStopping: isStoppingSession(session.id),
                                    isDeleting: isDeletingSession(session.id),
                                    selectSession: { selectSession(session) },
                                    stopSession: { await stopSession(session) },
                                    requestDelete: { sessionPendingDeletion = session }
                                )
                            }
                            ForEach(visibleImportableSessions) { local in
                                Button {
                                    Task { await importLocal(local) }
                                } label: {
                                    MacLocalSessionRow(session: local)
                                }
                                .buttonStyle(.plain)
                                .disabled(isImportingLocal)
                                .accessibilityIdentifier(
                                    MacWorkspaceLocalSessionPresentation.accessibilityIdentifier(for: local)
                                )
                                .contextMenu {
                                    Button("Import") {
                                        Task { await importLocal(local) }
                                    }
                                    .disabled(isImportingLocal)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView(
                    "No recent sessions",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Recent local workspace sessions and importable Pi TUI sessions appear here after the server returns activity for this workspace.")
                )
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var visibleWorktrees: [WorkspaceWorktree] {
        MacWorkspaceWorktreePresentation.visibleWorktrees(
            fetched: worktrees,
            hostMount: workspace.hostMount
        )
    }

    private var selectedWorktreeDisplayName: String {
        visibleWorktrees.first { $0.id == selectedWorktreeId }?.displayName ?? "Main"
    }

    private var canSwitchWorktrees: Bool {
        MacWorkspaceWorktreePresentation.canSwitch(
            visibleWorktrees: visibleWorktrees,
            isLoading: isLoadingWorktrees
        )
    }

    private var filteredActiveSessions: [SessionSummary] {
        MacWorkspaceWorktreePresentation.filterSessions(
            sessions?.active ?? [],
            selectedId: selectedWorktreeId
        )
    }

    private var filteredStoppedSessions: [SessionSummary] {
        MacWorkspaceWorktreePresentation.filterSessions(
            sessions?.stopped ?? [],
            selectedId: selectedWorktreeId
        )
    }

    private var visibleImportableSessions: [LocalSession] {
        (sessions?.importableSessions ?? []).filter { !importedLocalPaths.contains($0.path) }
    }

    private var showsSessionList: Bool {
        guard sessions != nil else { return false }
        return !filteredActiveSessions.isEmpty
            || !filteredStoppedSessions.isEmpty
            || !visibleImportableSessions.isEmpty
    }

    @ViewBuilder
    private var worktreeSwitcher: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Worktree")
                .foregroundStyle(.secondary)
            if canSwitchWorktrees {
                Picker("Worktree", selection: $selectedWorktreeId) {
                    ForEach(visibleWorktrees) { worktree in
                        Text(MacWorkspaceWorktreePresentation.menuTitle(for: worktree))
                            .tag(worktree.id)
                            .accessibilityLabel(WorkspaceWorktreeMenuFormatting.accessibilityLabel(for: worktree))
                            .accessibilityIdentifier("workspace.worktree.\(worktree.id)")
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Switch worktree, current worktree \(selectedWorktreeDisplayName)")
                .accessibilityIdentifier("workspace.worktree.menu")
            } else {
                Text(selectedWorktreeDisplayName)
                    .accessibilityLabel("Current worktree \(selectedWorktreeDisplayName)")
                    .accessibilityIdentifier("workspace.worktree.title")
                if isLoadingWorktrees {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            Spacer()
        }
        .font(.callout)
    }

    private func closeDocument() {
        openPlan = nil
        openDescriptor = nil
        documentError = nil
        isLoadingDocument = false
    }

    private func reopenDocumentForSelectedWorktree(_ worktreeId: String) {
        guard let plan = openPlan else { return }
        guard case .workspaceFile(let workspaceID, let path) = plan.source,
              workspaceID == workspace.id else { return }
        let updated = FileViewerPlan.workspaceFile(
            workspaceID: workspaceID,
            path: path,
            worktreeId: worktreeId
        )
        if updated != plan {
            openPlan = updated
        }
    }

    private func loadWorktrees() async {
        guard let client = MacWorkspaceClient.localOwner() else { return }
        isLoadingWorktrees = worktrees.isEmpty
        defer { isLoadingWorktrees = false }

        do {
            let fetched = try await client.listWorkspaceWorktrees(workspaceId: workspace.id)
            worktrees = fetched
            selectedWorktreeId = MacWorkspaceWorktreePresentation.resolvedSelectedId(
                selectedWorktreeId,
                in: fetched
            )
        } catch {
            // Worktree discovery is best-effort for older servers. Keep the main checkout visible.
            if worktrees.isEmpty {
                worktrees = MacWorkspaceWorktreePresentation.visibleWorktrees(
                    fetched: [],
                    hostMount: workspace.hostMount
                )
            }
        }
    }

    private func importLocal(_ local: LocalSession) async {
        guard !isImportingLocal else { return }
        isImportingLocal = true
        importLocalError = nil
        defer { isImportingLocal = false }

        guard let client = MacWorkspaceClient.localOwner() else {
            importLocalError = "Local server config is not initialized yet."
            return
        }

        do {
            let response = try await client.createWorkspaceSessionFromLocal(
                workspaceId: workspace.id,
                piSessionFile: local.path,
                worktreeId: selectedWorktreeId
            )
            importedLocalPaths.insert(local.path)
            await refreshSessions(selectedWorktreeId)
            selectSession(SessionSummary(from: response.session))
        } catch {
            importLocalError = "Import failed: \(error.localizedDescription)"
        }
    }

    private func loadOpenedDocument() async {
        guard let plan = openPlan else {
            openDescriptor = nil
            documentError = nil
            isLoadingDocument = false
            return
        }
        guard plan.loadsFileBytes else { return }
        openDescriptor = nil
        documentError = nil
        isLoadingDocument = true
        if !FileViewerDescriptorBuilder.needsFileBytes(path: plan.path) {
            guard openPlan == plan, !Task.isCancelled else { return }
            isLoadingDocument = false
            openDescriptor = FileViewerDescriptorBuilder.descriptor(path: plan.path, data: Data())
            documentError = nil
            return
        }
        let data = await MacMarkdownWorkspaceFileLoader.data(
            for: plan,
            sessionID: nil
        )
        guard openPlan == plan, !Task.isCancelled else { return }
        isLoadingDocument = false
        guard let data else {
            documentError = "Could not load \(plan.fileName)."
            openDescriptor = nil
            return
        }
        openDescriptor = FileViewerDescriptorBuilder.descriptor(path: plan.path, data: data)
        documentError = nil
    }
}

/// Workspace-list chrome for importable local pi TUI sessions.
enum MacWorkspaceLocalSessionPresentation {
    static let badgeTitle = "Terminal"

    static func accessibilityIdentifier(for session: LocalSession) -> String {
        "localSession.nav.\(session.piSessionId)"
    }

    static func messageCountLabel(for session: LocalSession) -> String? {
        session.messageCount > 0 ? "\(session.messageCount) msgs" : nil
    }

    static func showsList(_ list: MacWorkspaceClient.WorkspaceSessionList) -> Bool {
        list.hasVisibleSessions
    }
}

struct MacLocalSessionRow: View {
    let session: LocalSession

    private var modelSummary: SessionModelSummary? {
        SessionModelSummaryBuilder.summaries(primaryModel: session.model).first
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.themeFgDim)
                .frame(width: 20, height: 20)
                .frame(width: 24, height: 24)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.displayTitle)
                        .font(.body)
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)
                        .layoutPriority(1)

                    Spacer(minLength: 4)

                    Text(session.lastModified.relativeString())
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                        .fixedSize()
                }

                HStack(spacing: 6) {
                    Text(MacWorkspaceLocalSessionPresentation.badgeTitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.themeComment)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.themeComment.opacity(0.15))
                        )

                    if let modelSummary {
                        if !modelSummary.provider.isEmpty {
                            ProviderGlyph(provider: modelSummary.provider, size: 11, color: .themeFgDim)
                        }
                        Text(modelSummary.label)
                            .truncationMode(.middle)
                    }

                    if let countLabel = MacWorkspaceLocalSessionPresentation.messageCountLabel(for: session) {
                        Text(countLabel)
                    }
                }
                .font(.caption)
                .foregroundStyle(.themeFgDim)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct WorkspaceSessionActionRow: View {
    let summary: SessionSummary
    var includeWorkspaceContext: Bool = false
    let actionError: String?
    let isStopping: Bool
    let isDeleting: Bool
    let selectSession: () -> Void
    let stopSession: () async -> Void
    let requestDelete: () -> Void

    var body: some View {
        // Stop/Delete are context-menu only. Inline flags stay off in
        // `MacSessionInboxRowChrome` so the home and workspace lists match iPad.
        let chrome = MacSessionInboxRowChrome.make(status: summary.status)
        let presentation = MacSessionInboxPresentation.rowPresentation(
            for: summary,
            includeWorkspaceContext: includeWorkspaceContext
        )

        VStack(alignment: .leading, spacing: 4) {
            Button {
                selectSession()
            } label: {
                WorkspaceSessionSummaryRow(presentation: presentation)
            }
            .buttonStyle(.plain)

            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .contextMenu {
            Button("Open") { selectSession() }
            if chrome.showsContextMenuStop {
                Button("Stop Session") { Task { await stopSession() } }
                    .disabled(isStopping || isDeleting)
            }
            if chrome.showsContextMenuDelete {
                Button("Delete Session", role: .destructive) { requestDelete() }
                    .disabled(isDeleting || isStopping)
            }
        }
    }
}

private extension Workspace {
    var iconSymbolName: String {
        guard case .symbol(let name) = icon,
              NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else {
            return "folder"
        }
        return name
    }
}
