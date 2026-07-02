import Foundation
import OSLog

private let workspaceSnapshotLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "OppiMac",
    category: "MacWorkspaceSnapshotStore"
)

@MainActor @Observable
final class MacWorkspaceSnapshotStore {
    private(set) var workspaces: [Workspace] = []
    private(set) var summaries: [String: WorkspaceListSummary] = [:]
    private(set) var sessionsByWorkspace: [String: MacWorkspaceClient.WorkspaceSessionList] = [:]
    private(set) var loadingSessionWorkspaceIds: Set<String> = []
    private(set) var sessionErrors: [String: String] = [:]
    private(set) var isLoading = false
    private(set) var isCreatingWorkspace = false
    private(set) var isCreatingSession = false
    private(set) var deletingWorkspaceIds: Set<String> = []
    private(set) var stoppingSessionIds: Set<String> = []
    private(set) var deletingSessionIds: Set<String> = []
    private(set) var createWorkspaceError: String?
    private(set) var editWorkspaceError: String?
    private(set) var workspaceActionErrors: [String: String] = [:]
    private(set) var createSessionError: String?
    private(set) var sessionActionErrors: [String: String] = [:]
    private(set) var lastError: String?
    private(set) var lastLoadedAt: Date?

    var hasLoaded: Bool { lastLoadedAt != nil }

    var sessionTargets: [MacSelectedSessionTarget] {
        sessionsByWorkspace.flatMap { workspaceId, list in
            list.allSummaries.map { summary in
                MacSelectedSessionTarget(
                    workspaceId: summary.workspaceId ?? workspaceId,
                    sessionId: summary.id,
                    summary: summary
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.summary.status != rhs.summary.status {
                if lhs.summary.status == .busy || lhs.summary.status == .starting { return true }
                if rhs.summary.status == .busy || rhs.summary.status == .starting { return false }
            }
            return lhs.summary.lastActivity > rhs.summary.lastActivity
        }
    }

    var isLoadingAnySessions: Bool { !loadingSessionWorkspaceIds.isEmpty }

    func target(for sessionId: String) -> MacSelectedSessionTarget? {
        sessionTargets.first { $0.sessionId == sessionId }
    }

    func summary(for workspaceId: String) -> WorkspaceListSummary? {
        summaries[workspaceId]
    }

    func sessions(for workspaceId: String) -> MacWorkspaceClient.WorkspaceSessionList? {
        sessionsByWorkspace[workspaceId]
    }

    func isDeletingWorkspace(_ workspaceId: String) -> Bool {
        deletingWorkspaceIds.contains(workspaceId)
    }

    func workspaceActionError(for workspaceId: String) -> String? {
        workspaceActionErrors[workspaceId]
    }

    func isLoadingSessions(for workspaceId: String) -> Bool {
        loadingSessionWorkspaceIds.contains(workspaceId)
    }

    func sessionError(for workspaceId: String) -> String? {
        sessionErrors[workspaceId]
    }

    func isStoppingSession(_ sessionId: String) -> Bool {
        stoppingSessionIds.contains(sessionId)
    }

    func isDeletingSession(_ sessionId: String) -> Bool {
        deletingSessionIds.contains(sessionId)
    }

    func sessionActionError(for sessionId: String) -> String? {
        sessionActionErrors[sessionId]
    }

    func loadFromLocalConfig() async {
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            workspaces = []
            summaries = [:]
            sessionsByWorkspace = [:]
            lastError = "Local server config is not initialized yet."
            return
        }

        await load(client: MacWorkspaceClient(baseURL: baseURL, token: token))
    }

    func load(client: MacWorkspaceClient) async {
        isLoading = true
        lastError = nil
        do {
            let catalog = try await client.listWorkspaceCatalog()
            workspaces = catalog.workspaces.sorted { lhs, rhs in
                let lhsSummary = catalog.summaries[lhs.id]
                let rhsSummary = catalog.summaries[rhs.id]
                switch (lhsSummary?.latestActivity, rhsSummary?.latestActivity) {
                case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                    return lhsDate > rhsDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            }
            summaries = catalog.summaries
            lastLoadedAt = Date()
        } catch {
            workspaceSnapshotLogger.warning("Workspace catalog load failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    func loadSessionsFromLocalConfig(workspaceId: String) async {
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            sessionErrors[workspaceId] = "Local server config is not initialized yet."
            return
        }

        await loadSessions(workspaceId: workspaceId, client: MacWorkspaceClient(baseURL: baseURL, token: token))
    }

    func loadRecentSessionsForLoadedWorkspacesFromLocalConfig() async {
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            let message = "Local server config is not initialized yet."
            for workspace in workspaces {
                sessionErrors[workspace.id] = message
            }
            return
        }

        let client = MacWorkspaceClient(baseURL: baseURL, token: token)
        for workspace in workspaces {
            guard !Task.isCancelled else { break }
            await loadSessions(workspaceId: workspace.id, client: client)
        }
    }

    func createWorkspaceFromLocalConfig(_ draft: MacWorkspaceCreationDraft) async -> Workspace? {
        guard let request = draft.request else {
            createWorkspaceError = draft.validationMessage
            return nil
        }
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            createWorkspaceError = "Local server config is not initialized yet."
            return nil
        }

        return await createWorkspace(request, client: MacWorkspaceClient(baseURL: baseURL, token: token))
    }

    func createWorkspace(
        _ request: CreateWorkspaceRequest,
        client: MacWorkspaceClient
    ) async -> Workspace? {
        isCreatingWorkspace = true
        createWorkspaceError = nil
        defer { isCreatingWorkspace = false }

        do {
            let workspace = try await client.createWorkspace(request)
            workspaces.insert(workspace, at: 0)
            await load(client: client)
            return workspace
        } catch {
            workspaceSnapshotLogger.warning("Workspace creation failed: \(error.localizedDescription, privacy: .public)")
            createWorkspaceError = error.localizedDescription
            return nil
        }
    }

    func updateWorkspaceFromLocalConfig(id: String, draft: MacWorkspaceCreationDraft) async -> Workspace? {
        guard let request = draft.updateRequest else {
            editWorkspaceError = draft.validationMessage
            return nil
        }
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            editWorkspaceError = "Local server config is not initialized yet."
            return nil
        }

        return await updateWorkspace(
            id: id,
            request: request,
            client: MacWorkspaceClient(baseURL: baseURL, token: token)
        )
    }

    func updateWorkspace(
        id: String,
        request: UpdateWorkspaceRequest,
        client: MacWorkspaceClient
    ) async -> Workspace? {
        isCreatingWorkspace = true
        editWorkspaceError = nil
        defer { isCreatingWorkspace = false }

        do {
            let workspace = try await client.updateWorkspace(id: id, request: request)
            if let index = workspaces.firstIndex(where: { $0.id == id }) {
                workspaces[index] = workspace
            } else {
                workspaces.insert(workspace, at: 0)
            }
            await load(client: client)
            return workspace
        } catch {
            workspaceSnapshotLogger.warning("Workspace update failed: \(error.localizedDescription, privacy: .public)")
            editWorkspaceError = error.localizedDescription
            return nil
        }
    }

    func deleteWorkspaceFromLocalConfig(id: String) async -> Bool {
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            workspaceActionErrors[id] = "Local server config is not initialized yet."
            return false
        }

        return await deleteWorkspace(id: id, client: MacWorkspaceClient(baseURL: baseURL, token: token))
    }

    func deleteWorkspace(id: String, client: MacWorkspaceClient) async -> Bool {
        deletingWorkspaceIds.insert(id)
        workspaceActionErrors[id] = nil
        defer { deletingWorkspaceIds.remove(id) }

        do {
            try await client.deleteWorkspace(id: id)
            workspaces.removeAll { $0.id == id }
            summaries[id] = nil
            sessionsByWorkspace[id] = nil
            sessionErrors[id] = nil
            return true
        } catch {
            workspaceSnapshotLogger.warning("Workspace delete failed: \(error.localizedDescription, privacy: .public)")
            workspaceActionErrors[id] = "Delete failed: \(error.localizedDescription)"
            return false
        }
    }

    func createSessionFromLocalConfig(workspaceId: String, prompt: String) async -> MacSelectedSessionTarget? {
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            createSessionError = "Local server config is not initialized yet."
            return nil
        }

        return await createSession(
            workspaceId: workspaceId,
            prompt: prompt,
            client: MacWorkspaceClient(baseURL: baseURL, token: token)
        )
    }

    func createSession(
        workspaceId: String,
        prompt: String,
        client: MacWorkspaceClient
    ) async -> MacSelectedSessionTarget? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return nil }

        isCreatingSession = true
        createSessionError = nil
        defer { isCreatingSession = false }

        do {
            let response = try await client.createWorkspaceSession(
                workspaceId: workspaceId,
                prompt: trimmedPrompt
            )
            await loadSessions(workspaceId: workspaceId, client: client)
            return MacSelectedSessionTarget(
                workspaceId: response.session.workspaceId ?? workspaceId,
                sessionId: response.session.id,
                summary: SessionSummary(from: response.session)
            )
        } catch {
            workspaceSnapshotLogger.warning("Workspace session creation failed: \(error.localizedDescription, privacy: .public)")
            createSessionError = error.localizedDescription
            return nil
        }
    }

    func stopSessionFromLocalConfig(workspaceId: String, sessionId: String) async -> MacSelectedSessionTarget? {
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            sessionActionErrors[sessionId] = "Local server config is not initialized yet."
            return nil
        }

        return await stopSession(
            workspaceId: workspaceId,
            sessionId: sessionId,
            client: MacWorkspaceClient(baseURL: baseURL, token: token)
        )
    }

    func deleteSessionFromLocalConfig(workspaceId: String, sessionId: String) async -> Bool {
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir),
              let baseURL = MacServerLifecycle.defaultBaseURL else {
            sessionActionErrors[sessionId] = "Local server config is not initialized yet."
            return false
        }

        return await deleteSession(
            workspaceId: workspaceId,
            sessionId: sessionId,
            client: MacWorkspaceClient(baseURL: baseURL, token: token)
        )
    }

    func stopSession(
        workspaceId: String,
        sessionId: String,
        client: MacWorkspaceClient
    ) async -> MacSelectedSessionTarget? {
        stoppingSessionIds.insert(sessionId)
        sessionActionErrors[sessionId] = nil
        defer { stoppingSessionIds.remove(sessionId) }

        do {
            let response = try await client.stopWorkspaceSession(workspaceId: workspaceId, sessionId: sessionId)
            if let session = response.session {
                upsertSession(session, fallbackWorkspaceId: workspaceId)
            }
            await loadSessions(workspaceId: workspaceId, client: client)
            return target(for: sessionId)
        } catch {
            workspaceSnapshotLogger.warning("Workspace session stop failed: \(error.localizedDescription, privacy: .public)")
            sessionActionErrors[sessionId] = "Stop failed: \(error.localizedDescription)"
            return nil
        }
    }

    func deleteSession(
        workspaceId: String,
        sessionId: String,
        client: MacWorkspaceClient
    ) async -> Bool {
        deletingSessionIds.insert(sessionId)
        sessionActionErrors[sessionId] = nil
        defer { deletingSessionIds.remove(sessionId) }

        do {
            try await client.deleteWorkspaceSession(workspaceId: workspaceId, sessionId: sessionId)
            removeSession(workspaceId: workspaceId, sessionId: sessionId)
            return true
        } catch let error as MacWorkspaceClientError {
            if case .server(let status, _) = error, status == 404 {
                removeSession(workspaceId: workspaceId, sessionId: sessionId)
                return true
            }
            workspaceSnapshotLogger.warning("Workspace session delete failed: \(error.localizedDescription, privacy: .public)")
            sessionActionErrors[sessionId] = "Delete failed: \(error.localizedDescription)"
            return false
        } catch {
            workspaceSnapshotLogger.warning("Workspace session delete failed: \(error.localizedDescription, privacy: .public)")
            sessionActionErrors[sessionId] = "Delete failed: \(error.localizedDescription)"
            return false
        }
    }

    func loadSessions(workspaceId: String, client: MacWorkspaceClient) async {
        loadingSessionWorkspaceIds.insert(workspaceId)
        sessionErrors[workspaceId] = nil
        do {
            let until = Date()
            let since = until.addingTimeInterval(-3 * 24 * 60 * 60)
            sessionsByWorkspace[workspaceId] = try await client.getWorkspaceSessions(
                workspaceId: workspaceId,
                since: since,
                until: until
            )
        } catch {
            workspaceSnapshotLogger.warning("Workspace session load failed: \(error.localizedDescription, privacy: .public)")
            sessionErrors[workspaceId] = error.localizedDescription
        }
        loadingSessionWorkspaceIds.remove(workspaceId)
    }

    private func upsertSession(_ session: Session, fallbackWorkspaceId: String) {
        let workspaceId = session.workspaceId ?? fallbackWorkspaceId
        let summary = SessionSummary(from: session)
        guard let list = sessionsByWorkspace[workspaceId] else { return }
        let active = (list.active.filter { $0.id != session.id } + (MacSessionActionPolicy.canDelete(summary.status) ? [] : [summary]))
            .sorted { $0.lastActivity > $1.lastActivity }
        let stopped = (list.stopped.filter { $0.id != session.id } + (MacSessionActionPolicy.canDelete(summary.status) ? [summary] : []))
            .sorted { $0.lastActivity > $1.lastActivity }
        sessionsByWorkspace[workspaceId] = MacWorkspaceClient.WorkspaceSessionList(
            workspaceId: list.workspaceId,
            serverNow: list.serverNow,
            active: active,
            stopped: stopped,
            importableSessions: list.importableSessions
        )
    }

    private func removeSession(workspaceId: String, sessionId: String) {
        guard let list = sessionsByWorkspace[workspaceId] else { return }
        sessionsByWorkspace[workspaceId] = MacWorkspaceClient.WorkspaceSessionList(
            workspaceId: list.workspaceId,
            serverNow: list.serverNow,
            active: list.active.filter { $0.id != sessionId },
            stopped: list.stopped.filter { $0.id != sessionId },
            importableSessions: list.importableSessions
        )
    }

    #if DEBUG
    func _setCatalogForTesting(
        workspaces: [Workspace],
        summaries: [String: WorkspaceListSummary] = [:],
        sessionsByWorkspace: [String: MacWorkspaceClient.WorkspaceSessionList] = [:]
    ) {
        self.workspaces = workspaces
        self.summaries = summaries
        self.sessionsByWorkspace = sessionsByWorkspace
    }
    #endif
}
