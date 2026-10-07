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
/// `WorkspaceSettingsModel`, so pushed pages never refetch.
struct WorkspaceSettingsRootView: View {
    let workspace: Workspace

    @Environment(\.apiClient) private var apiClient
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    @State private var model: WorkspaceSettingsModel
    @State private var isConfirmingDelete = false
    @State private var isLaunchingOppi = false
    @State private var launchError: String?

    init(workspace: Workspace) {
        self.workspace = workspace
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
        List {
            summarySection

            Section {
                SettingsIndexRow("Instructions", systemImage: "doc.text", value: model.instructionsSummary) {
                    WorkspaceInstructionsPage(model: model)
                }
                .accessibilityIdentifier("workspace.edit.instructions")
                SettingsIndexRow("Skills", systemImage: "sparkles", value: model.skillsSummary) {
                    WorkspaceSkillsPage(model: model)
                }
                .accessibilityIdentifier("workspace.edit.skills")
                SettingsIndexRow("Extensions", systemImage: "puzzlepiece.extension", value: model.extensionsSummary) {
                    WorkspaceExtensionsPage(model: model)
                }
                .accessibilityIdentifier("workspace.edit.extensions")
                SettingsIndexRow("MCP Servers", systemImage: "network", value: model.mcpSummary) {
                    mcpDestination
                }
                .accessibilityIdentifier("workspace.edit.mcpServers")
                SettingsIndexRow("Dictionary", systemImage: "text.book.closed") {
                    DictationDictionaryView(workspaceId: workspace.id)
                }
                .accessibilityIdentifier("workspace.edit.dictionary")
                if model.isSandbox {
                    SettingsIndexRow("Network Access", systemImage: "lock.shield", value: model.networkAccessSummary) {
                        WorkspaceNetworkAccessPage(model: model)
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
            NavigationLink {
                WorkspaceDetailsPage(model: model)
            } label: {
                HStack(spacing: 12) {
                    WorkspaceRuntimeIcon(workspace: current, size: 24, frameSize: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.name)
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

    private var folderSummary: String {
        if let folder = model.savedFolder { return folder }
        return model.isSandbox ? "Sandbox" : "Server home folder"
    }

    /// A host workspace manages its own `.pi/mcp.json`; a sandbox picks from the global servers.
    @ViewBuilder
    private var mcpDestination: some View {
        if model.isSandbox {
            WorkspaceSandboxMcpPage(model: model)
        } else {
            McpServersView(scopeId: workspace.id)
        }
    }

    // MARK: - Actions

    private func deleteWorkspace() async {
        guard let deleted = await model.deleteWorkspace() else { return }
        dismiss()
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
            dismiss()
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
