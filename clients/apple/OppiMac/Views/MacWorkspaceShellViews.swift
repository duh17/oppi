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
                TextField("Default model", text: $draft.defaultModel)
                Text("Leave blank to use the server default for new sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                if let defaultModel = workspace.defaultModel, !defaultModel.isEmpty {
                    Text(defaultModel.split(separator: "/").last.map(String.init) ?? defaultModel)
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
    let refreshSessions: () async -> Void
    let createSession: (String) async -> Void
    let updateWorkspace: (MacWorkspaceCreationDraft) async -> Workspace?
    let deleteWorkspace: () async -> Void
    let stopSession: (SessionSummary) async -> Void
    let deleteSession: (SessionSummary) async -> Void
    let selectSession: (SessionSummary) -> Void

    @State private var newSessionPrompt = ""
    @State private var isPresentingEditWorkspace = false
    @State private var editDraft = MacWorkspaceCreationDraft()
    @State private var isConfirmingWorkspaceDeletion = false
    @State private var sessionPendingDeletion: SessionSummary?

    var body: some View {
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
                if let defaultModel = workspace.defaultModel, !defaultModel.isEmpty {
                    Label("Default model: \(defaultModel)", systemImage: "cpu")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

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

            MacWorkspaceFileBrowserView(workspace: workspace)

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
                        Task { await createSession(prompt) }
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
                Spacer()
                Button {
                    Task { await refreshSessions() }
                } label: {
                    Label("Refresh Sessions", systemImage: "arrow.clockwise")
                }
                .disabled(isLoadingSessions)
            }

            if isLoadingSessions {
                ProgressView("Loading sessions...")
            } else if let sessionError {
                ContentUnavailableView(
                    "Could not load sessions",
                    systemImage: "exclamationmark.triangle",
                    description: Text(sessionError)
                )
            } else if let sessions, !sessions.allSummaries.isEmpty {
                List {
                    Section("Active") {
                        ForEach(sessions.active, id: \.id) { session in
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
                    Section("Stopped") {
                        ForEach(sessions.stopped, id: \.id) { session in
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
                .listStyle(.inset)
            } else {
                ContentUnavailableView(
                    "No recent sessions",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Recent local workspace sessions appear here after the server returns activity for this workspace.")
                )
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .task(id: workspace.id) {
            if sessions == nil {
                await refreshSessions()
            }
        }
    }
}

struct WorkspaceSessionActionRow: View {
    let summary: SessionSummary
    let actionError: String?
    let isStopping: Bool
    let isDeleting: Bool
    let selectSession: () -> Void
    let stopSession: () async -> Void
    let requestDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    selectSession()
                } label: {
                    WorkspaceSessionSummaryRow(summary: summary)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                if MacSessionActionPolicy.canStop(summary.status) {
                    Button {
                        Task { await stopSession() }
                    } label: {
                        if isStopping {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Stop", systemImage: "stop.circle")
                                .labelStyle(.iconOnly)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isStopping || isDeleting)
                    .help("Stop session")
                }

                if MacSessionActionPolicy.canDelete(summary.status) {
                    Button(role: .destructive) {
                        requestDelete()
                    } label: {
                        if isDeleting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Delete", systemImage: "trash")
                                .labelStyle(.iconOnly)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isDeleting || isStopping)
                    .help("Delete session")
                }
            }

            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .contextMenu {
            Button("Open") { selectSession() }
            if MacSessionActionPolicy.canStop(summary.status) {
                Button("Stop Session") { Task { await stopSession() } }
                    .disabled(isStopping || isDeleting)
            }
            if MacSessionActionPolicy.canDelete(summary.status) {
                Button("Delete Session", role: .destructive) { requestDelete() }
                    .disabled(isDeleting || isStopping)
            }
        }
    }
}

struct WorkspaceSessionSummaryRow: View {
    let summary: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.session.displayTitle)
                .font(.headline)
            HStack(spacing: 8) {
                Text(summary.status.rawValue.capitalized)
                if let model = summary.model {
                    Text(model.split(separator: "/").last.map(String.init) ?? model)
                }
                Text(summary.lastActivity.relativeString())
                if summary.pendingAskCount > 0 {
                    Label("\(summary.pendingAskCount)", systemImage: "questionmark.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
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
