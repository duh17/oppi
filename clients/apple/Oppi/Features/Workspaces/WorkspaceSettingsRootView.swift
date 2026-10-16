import Foundation
import SwiftUI

enum WorkspaceDeleteConfirmationPolicy {
    static let swipeButtonRole: ButtonRole? = nil

    static func confirm(
        workspace: Workspace,
        clearPending: () -> Void,
        performDelete: (Workspace) -> Void
    ) {
        clearPending()
        performDelete(workspace)
    }

    static func deleteMessage(for workspace: Workspace) -> String {
        "This removes the Oppi workspace record for \"\(workspace.name)\". Files on disk stay. Sessions in this workspace may become unreachable."
    }
}

/// Workspace Settings root: a summary of the workspace that opens Details, one
/// index row per focused page, Show Changes in Chat, and Delete Workspace.
///
/// Toggles and pickers apply as soon as they change. Only the Details page,
/// the Instructions editor, and the Network Access hosts editor are drafts
/// with their own Save. Data for every page comes from one
/// `WorkspaceSettingsModel`, so pushed pages never refetch. Each pushed page
/// starts from the app root (the active server), so it gets this screen's
/// server scope explicitly.
struct WorkspaceSettingsRootView: View {
    let workspace: Workspace
    /// Closes this screen after Delete Workspace or Use Oppi Session when it
    /// was pushed onto another screen. As a shell route it leaves through the
    /// `AppNavigation` change that follows instead.
    var onLeave: (() -> Void)?

    @Environment(\.apiClient) private var apiClient
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.screenNavigator) private var navigator

    @State private var model: WorkspaceSettingsModel
    @State private var isConfirmingDelete = false
    @State private var isLaunchingOppi = false
    @State private var launchError: String?
    @State private var locks = ScopedLockService.shared

    init(workspace: Workspace, onLeave: (() -> Void)? = nil) {
        self.workspace = workspace
        self.onLeave = onLeave
        _model = State(initialValue: WorkspaceSettingsModel(seed: workspace))
    }

    #if DEBUG
    /// Screenshot harness entry: renders a fixture model without a server.
    init(workspace: Workspace, model: WorkspaceSettingsModel) {
        self.workspace = workspace
        _model = State(initialValue: model)
    }
    #endif

    private var current: Workspace { model.workspace }

    private var scopeKey: String {
        [workspace.id, connection.workspaceStore.activeServerId ?? connection.currentServerId ?? ""]
            .joined(separator: "|")
    }

    var body: some View {
        // Copied here: the destinations run later, in the pushed screens.
        let model = model
        let scoped = pageScope
        let workspaceId = workspace.id
        List {
            summarySection

            Section {
                SettingsIndexRow("Instructions", systemImage: "doc.text", value: model.instructionsSummary) {
                    scoped(WorkspaceInstructionsPage(model: model))
                }
                .accessibilityIdentifier("workspace.edit.instructions")
                SettingsIndexRow("Skills", systemImage: "sparkles", value: model.skillsSummary) {
                    scoped(WorkspaceSkillsPage(model: model))
                }
                .accessibilityIdentifier("workspace.edit.skills")
                SettingsIndexRow("Extensions", systemImage: "puzzlepiece.extension", value: model.extensionsSummary) {
                    scoped(WorkspaceExtensionsPage(model: model))
                }
                .accessibilityIdentifier("workspace.edit.extensions")
                SettingsIndexRow("MCP Servers", systemImage: "network", value: model.mcpSummary) {
                    scoped(Self.mcpDestination(model: model, workspaceId: workspaceId))
                }
                .accessibilityIdentifier("workspace.edit.mcpServers")
                SettingsIndexRow("Dictionary", systemImage: "text.book.closed") {
                    scoped(DictationDictionaryView(workspaceId: workspaceId))
                }
                .accessibilityIdentifier("workspace.edit.dictionary")
                if model.isSandbox {
                    SettingsIndexRow("Network Access", systemImage: "lock.shield", value: model.networkAccessSummary) {
                        scoped(WorkspaceNetworkAccessPage(model: model))
                    }
                    .accessibilityIdentifier("workspace.edit.networkAccess")
                }
            }

            if let projectTrust = model.projectTrust {
                Section {
                    LabeledContent("Project Trust", value: projectTrust.title)
                        .accessibilityIdentifier("workspace.edit.projectTrust")
                } footer: {
                    Text(projectTrust.explanation)
                }
            }

            Section {
                Toggle(
                    "Show Changes in Chat",
                    isOn: Binding(
                        get: { model.gitStatusEnabled },
                        set: { newValue in
                            Task { await model.setGitStatusEnabled(newValue) }
                        }
                    )
                )
                .disabled(model.isSavingGitStatus || model.isDeleting)
                .accessibilityIdentifier("workspace.edit.gitStatus")
            } footer: {
                Text("Shows branch, changed files, and line stats above the chat.")
            }

            if let lockScope {
                Section {
                    ScopedLockToggle(title: "Lock Workspace", scope: lockScope)
                        .accessibilityIdentifier("workspace.edit.lock")
                } footer: {
                    Text(ScopedLockToggle.footer(for: "this workspace and its sessions"))
                }
            }

            if connection.controlSessionsAvailable, apiClient != nil {
                Section {
                    UseOppiSessionRow(
                        supportingText: "Work with Oppi to revise this Workspace.",
                        isLoading: isLaunchingOppi
                    ) {
                        Task { await launchOppiSession() }
                    }
                    .accessibilityIdentifier("workspace.edit.useOppiSession")
                }
            }

            if let message = model.error ?? launchError {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.themeRed)
                        .accessibilityIdentifier("workspace.edit.error")
                }
            }

            Section {
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label {
                        Text("Delete Workspace")
                    } icon: {
                        Image(systemName: "trash")
                            .foregroundStyle(.themeRed)
                    }
                }
                .tint(.themeRed)
                // A queued write could otherwise land after the delete.
                .disabled(model.isDeleting || !model.isWriteQueueIdle)
                .accessibilityIdentifier("workspace.edit.delete")
            }
        }
        .settingsPage("Workspace Settings")
        .accessibilityIdentifier("workspace.edit.list")
        .task(id: scopeKey) {
            model.attach(connection: connection, workspace: workspace)
            await model.loadPiResourcesIfNeeded()
        }
        .confirmationDialog(
            "Delete Workspace?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Workspace", role: .destructive) {
                WorkspaceDeleteConfirmationPolicy.confirm(
                    workspace: current,
                    clearPending: { isConfirmingDelete = false },
                    performDelete: { _ in
                        Task { await deleteWorkspace() }
                    }
                )
            }
            Button("Cancel", role: .cancel) {
                isConfirmingDelete = false
            }
        } message: {
            Text(WorkspaceDeleteConfirmationPolicy.deleteMessage(for: current))
        }
    }

    // MARK: - Summary

    private var summarySection: some View {
        Section {
            SettingsIndexActionRow {
                let model = model
                let scoped = pageScope
                navigator.push { scoped(WorkspaceDetailsPage(model: model)) }
            } label: {
                HStack(spacing: 12) {
                    WorkspaceRuntimeIcon(workspace: current, size: 24, frameSize: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(current.name)
                            if let lockScope {
                                LockBadge(state: locks.badge(.workspace(serverId: lockScope.serverId, workspaceId: workspace.id)))
                            }
                        }
                        Text(folderSummary)
                            .font(.footnote)
                            .foregroundStyle(.themeComment)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .accessibilityIdentifier("workspace.edit.details")
        }
    }

    private var pageScope: WorkspaceSettingsPageScope {
        WorkspaceSettingsPageScope(connection: connection, apiClient: apiClient, navigation: navigation)
    }

    private var lockScope: ScopedLockScope? {
        (connection.currentServerId ?? connection.workspaceStore.activeServerId)
            .map { .workspace(serverId: $0, workspaceId: workspace.id) }
    }

    private var folderSummary: String {
        if let folder = model.savedFolder { return folder }
        return model.isSandbox ? "Sandbox" : "No folder"
    }

    /// A host workspace manages its own `.pi/mcp.json`; a sandbox picks from the global servers.
    @ViewBuilder
    private static func mcpDestination(model: WorkspaceSettingsModel, workspaceId: String) -> some View {
        if model.isSandbox {
            WorkspaceSandboxMcpPage(model: model)
        } else {
            McpServersView(scopeId: workspaceId)
        }
    }

    // MARK: - Actions

    private func deleteWorkspace() async {
        guard await AppLockService.shared.authorizeProtectedAction(
            reason: String(localized: "Delete \(current.name)")
        ) else { return }
        guard let deleted = await model.deleteWorkspace() else { return }
        ScopedLockService.shared.forgetWorkspace(
            serverId: deleted.serverId,
            workspaceId: deleted.workspaceId,
            sessionIds: sessionStore.listProjectionSessions(workspaceId: deleted.workspaceId).map(\.id)
        )
        onLeave?()
        navigation.leaveDeletedWorkspace(serverId: deleted.serverId, workspaceId: deleted.workspaceId)
    }

    @MainActor
    private func launchOppiSession() async {
        guard let apiClient, !isLaunchingOppi else { return }
        isLaunchingOppi = true
        launchError = nil
        defer { isLaunchingOppi = false }
        do {
            let response = try await apiClient.createControlSession(.init(
                domain: .workspaces,
                intent: .revise,
                targetId: workspace.id,
                targetName: current.name,
                name: "Revise \(current.name)",
                prompt: ControlSessionStarterPrompt.make(
                    domain: .workspaces,
                    intent: .revise,
                    targetId: workspace.id,
                    targetName: current.name
                )
            ))
            sessionStore.cacheSessionForNavigation(response.session)
            guard let serverId = connection.currentServerId ?? sessionStore.activeServerId else { return }
            onLeave?()
            await Task.yield()
            navigation.openWorkspaceSession(.init(
                serverId: serverId,
                sessionId: response.session.id,
                routeScope: .control
            ))
        } catch {
            guard WorkspacePiResourceErrorPolicy.shouldPresent(error) else { return }
            launchError = error.localizedDescription
        }
    }
}

/// The workspace's server services, copied for the pages Workspace Settings
/// pushes: a pushed page starts from the app root (the active server).
@MainActor
private struct WorkspaceSettingsPageScope {
    let connection: ServerConnection
    let apiClient: APIClient?
    let navigation: AppNavigation

    func callAsFunction(_ page: some View) -> some View {
        page.presenterScope(connection: connection, apiClient: apiClient, navigation: navigation)
    }
}
