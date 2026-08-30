import Foundation
import OSLog

private let workspaceSnapshotLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "OppiMac",
    category: "MacWorkspaceSnapshotStore"
)

private struct SessionLoadRequest: Equatable, Sendable {
    let workspaceId: String
    let worktreeId: String?
    let generation: UInt64
}

@MainActor @Observable
final class MacWorkspaceSnapshotStore {
    private(set) var workspaces: [Workspace] = []
    private(set) var summaries: [String: WorkspaceListSummary] = [:]
    private(set) var sessionsByWorkspace: [String: MacWorkspaceClient.WorkspaceSessionList] = [:]
    private(set) var recentSessionTargets: [MacSelectedSessionTarget] = []
    private(set) var loadingSessionWorkspaceIds: Set<String> = []
    private(set) var isLoadingRecentSessions = false
    private(set) var sessionErrors: [String: String] = [:]
    private(set) var recentSessionsError: String?
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
    private(set) var isImportingLocalSession = false
    private(set) var importLocalSessionError: String?
    private(set) var sessionActionErrors: [String: String] = [:]
    private(set) var lastError: String?
    private(set) var lastLoadedAt: Date?
    private(set) var isStreamingAppEvents = false
    var screenAwakeController: MacScreenAwakeController = .shared
    /// Latest in-flight `loadSessions` per workspace. Overlapping worktree
    /// switches keep the newest (workspaceId, worktreeId, generation).
    private var currentSessionLoadByWorkspace: [String: SessionLoadRequest] = [:]
    private var recentSessionLoadGeneration: UInt64 = 0

    var hasLoaded: Bool { lastLoadedAt != nil }

    var sessionTargets: [MacSelectedSessionTarget] {
        recentSessionTargets.sorted { lhs, rhs in
            if lhs.summary.status != rhs.summary.status {
                if lhs.summary.status == .busy || lhs.summary.status == .starting { return true }
                if rhs.summary.status == .busy || rhs.summary.status == .starting { return false }
            }
            return lhs.summary.lastActivity > rhs.summary.lastActivity
        }
    }

    var isLoadingAnySessions: Bool { isLoadingRecentSessions || !loadingSessionWorkspaceIds.isEmpty }

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
        guard let client = MacWorkspaceClient.localOwner() else {
            workspaces = []
            summaries = [:]
            sessionsByWorkspace = [:]
            recentSessionTargets = []
            lastError = "Local server config is not initialized yet."
            return
        }

        await load(client: client)
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

    func loadSessionsFromLocalConfig(workspaceId: String, worktreeId: String? = nil) async {
        guard let client = MacWorkspaceClient.localOwner() else {
            sessionErrors[workspaceId] = "Local server config is not initialized yet."
            return
        }

        await loadSessions(workspaceId: workspaceId, worktreeId: worktreeId, client: client)
    }

    /// Session home uses one GET `/sessions/recent`. Do not loop workspaces
    /// here. Workspace detail still calls `loadSessionsFromLocalConfig`.
    func loadRecentSessionsForLoadedWorkspacesFromLocalConfig() async {
        guard let client = MacWorkspaceClient.localOwner() else {
            recentSessionTargets = []
            recentSessionsError = "Local server config is not initialized yet."
            return
        }

        await loadRecentSessions(client: client)
    }

    func loadRecentSessions(client: MacWorkspaceClient, recentDays: Int = 3) async {
        recentSessionLoadGeneration &+= 1
        let generation = recentSessionLoadGeneration
        isLoadingRecentSessions = true
        recentSessionsError = nil
        do {
            let summaries = try await client.listRecentSessions(recentDays: recentDays)
            guard generation == recentSessionLoadGeneration else { return }
            recentSessionTargets = Self.homeTargets(from: summaries)
            screenAwakeController.reconcileSessionActivity(
                sessionIds: Set(summaries.filter { $0.status.isRunning }.map(\.id))
            )
        } catch {
            guard generation == recentSessionLoadGeneration else { return }
            workspaceSnapshotLogger.warning("Recent session load failed: \(error.localizedDescription, privacy: .public)")
            recentSessionsError = error.localizedDescription
        }
        isLoadingRecentSessions = false
    }

    static func homeTargets(from summaries: [SessionSummary]) -> [MacSelectedSessionTarget] {
        summaries.compactMap { summary in
            if summary.control != nil {
                return MacSelectedSessionTarget(
                    workspaceId: summary.workspaceId ?? "",
                    sessionId: summary.id,
                    summary: summary
                )
            }
            let workspaceId = summary.workspaceId ?? summary.session.workspaceId
            guard let workspaceId, !workspaceId.isEmpty else { return nil }
            return MacSelectedSessionTarget(
                workspaceId: workspaceId,
                sessionId: summary.id,
                summary: summary
            )
        }
    }

    func noteOpenedSession(_ target: MacSelectedSessionTarget) {
        upsertRecentTarget(target)
    }

    func createWorkspaceFromLocalConfig(_ draft: MacWorkspaceCreationDraft) async -> Workspace? {
        guard let request = draft.request else {
            createWorkspaceError = draft.validationMessage
            return nil
        }
        guard let client = MacWorkspaceClient.localOwner() else {
            createWorkspaceError = "Local server config is not initialized yet."
            return nil
        }

        return await createWorkspace(request, client: client)
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
        guard let client = MacWorkspaceClient.localOwner() else {
            editWorkspaceError = "Local server config is not initialized yet."
            return nil
        }

        return await updateWorkspace(
            id: id,
            request: request,
            client: client
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
        guard let client = MacWorkspaceClient.localOwner() else {
            workspaceActionErrors[id] = "Local server config is not initialized yet."
            return false
        }

        return await deleteWorkspace(id: id, client: client)
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
            recentSessionTargets.removeAll { $0.workspaceId == id }
            return true
        } catch {
            workspaceSnapshotLogger.warning("Workspace delete failed: \(error.localizedDescription, privacy: .public)")
            workspaceActionErrors[id] = "Delete failed: \(error.localizedDescription)"
            return false
        }
    }

    func createSessionFromLocalConfig(
        workspaceId: String,
        prompt: String,
        worktreeId: String? = nil
    ) async -> MacSelectedSessionTarget? {
        guard let client = MacWorkspaceClient.localOwner() else {
            createSessionError = "Local server config is not initialized yet."
            return nil
        }

        return await createSession(
            workspaceId: workspaceId,
            prompt: prompt,
            worktreeId: worktreeId,
            client: client
        )
    }

    func createSession(
        workspaceId: String,
        prompt: String,
        worktreeId: String? = nil,
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
                prompt: trimmedPrompt,
                worktreeId: worktreeId
            )
            await loadSessions(workspaceId: workspaceId, worktreeId: worktreeId, client: client)
            let target = MacSelectedSessionTarget(
                workspaceId: response.session.workspaceId ?? workspaceId,
                sessionId: response.session.id,
                summary: SessionSummary(from: response.session)
            )
            upsertRecentTarget(target)
            return target
        } catch {
            workspaceSnapshotLogger.warning("Workspace session creation failed: \(error.localizedDescription, privacy: .public)")
            createSessionError = error.localizedDescription
            return nil
        }
    }

    func importLocalSessionFromLocalConfig(
        workspaceId: String,
        local: LocalSession,
        worktreeId: String? = nil
    ) async -> MacSelectedSessionTarget? {
        guard let client = MacWorkspaceClient.localOwner() else {
            importLocalSessionError = "Local server config is not initialized yet."
            return nil
        }

        return await importLocalSession(
            workspaceId: workspaceId,
            local: local,
            worktreeId: worktreeId,
            client: client
        )
    }

    func importLocalSession(
        workspaceId: String,
        local: LocalSession,
        worktreeId: String? = nil,
        client: MacWorkspaceClient
    ) async -> MacSelectedSessionTarget? {
        isImportingLocalSession = true
        importLocalSessionError = nil
        defer { isImportingLocalSession = false }

        do {
            let response = try await client.createWorkspaceSessionFromLocal(
                workspaceId: workspaceId,
                piSessionFile: local.path,
                worktreeId: worktreeId
            )
            removeImportableSession(workspaceId: workspaceId, path: local.path)
            let imported = MacSelectedSessionTarget(
                workspaceId: response.session.workspaceId ?? workspaceId,
                sessionId: response.session.id,
                summary: SessionSummary(from: response.session)
            )
            upsertRecentTarget(imported)
            upsertSession(response.session, fallbackWorkspaceId: workspaceId)
            await loadSessions(workspaceId: workspaceId, worktreeId: worktreeId, client: client)
            removeImportableSession(workspaceId: workspaceId, path: local.path)
            return target(for: response.session.id) ?? imported
        } catch {
            workspaceSnapshotLogger.warning("Local session import failed: \(error.localizedDescription, privacy: .public)")
            importLocalSessionError = "Import failed: \(error.localizedDescription)"
            return nil
        }
    }

    func stopSessionFromLocalConfig(workspaceId: String, sessionId: String) async -> MacSelectedSessionTarget? {
        await stopSessionFromLocalConfig(
            existingTarget(workspaceId: workspaceId, sessionId: sessionId)
        )
    }

    func stopSessionFromLocalConfig(_ target: MacSelectedSessionTarget) async -> MacSelectedSessionTarget? {
        guard let client = MacWorkspaceClient.localOwner() else {
            sessionActionErrors[target.sessionId] = "Local server config is not initialized yet."
            return nil
        }

        return await stopSession(target, client: client)
    }

    func deleteSessionFromLocalConfig(workspaceId: String, sessionId: String) async -> Bool {
        await deleteSessionFromLocalConfig(
            existingTarget(workspaceId: workspaceId, sessionId: sessionId)
        )
    }

    func deleteSessionFromLocalConfig(_ target: MacSelectedSessionTarget) async -> Bool {
        guard let client = MacWorkspaceClient.localOwner() else {
            sessionActionErrors[target.sessionId] = "Local server config is not initialized yet."
            return false
        }

        return await deleteSession(target, client: client)
    }

    func stopSession(
        workspaceId: String,
        sessionId: String,
        client: MacWorkspaceClient
    ) async -> MacSelectedSessionTarget? {
        await stopSession(
            existingTarget(workspaceId: workspaceId, sessionId: sessionId),
            client: client
        )
    }

    func stopSession(
        _ target: MacSelectedSessionTarget,
        client: MacWorkspaceClient
    ) async -> MacSelectedSessionTarget? {
        stoppingSessionIds.insert(target.sessionId)
        sessionActionErrors[target.sessionId] = nil
        defer { stoppingSessionIds.remove(target.sessionId) }

        do {
            let response = try await client.stopSession(
                scope: target.routeScope,
                sessionId: target.sessionId
            )
            if let session = response.session {
                if session.control != nil {
                    noteOpenedSession(MacSelectedSessionTarget.from(session: session) ?? target)
                } else {
                    upsertSession(session, fallbackWorkspaceId: target.workspaceId)
                }
            }
            if case .workspace(let workspaceId) = target.routeScope, !workspaceId.isEmpty {
                let worktreeId = sessionsByWorkspace[workspaceId]?.allSummaries
                    .first { $0.id == target.sessionId }?.worktreeId
                await loadSessions(workspaceId: workspaceId, worktreeId: worktreeId, client: client)
            }
            return self.target(for: target.sessionId)
        } catch {
            workspaceSnapshotLogger.warning("Workspace session stop failed: \(error.localizedDescription, privacy: .public)")
            sessionActionErrors[target.sessionId] = "Stop failed: \(error.localizedDescription)"
            return nil
        }
    }

    func deleteSession(
        workspaceId: String,
        sessionId: String,
        client: MacWorkspaceClient
    ) async -> Bool {
        await deleteSession(
            existingTarget(workspaceId: workspaceId, sessionId: sessionId),
            client: client
        )
    }

    func deleteSession(
        _ target: MacSelectedSessionTarget,
        client: MacWorkspaceClient
    ) async -> Bool {
        deletingSessionIds.insert(target.sessionId)
        sessionActionErrors[target.sessionId] = nil
        defer { deletingSessionIds.remove(target.sessionId) }

        do {
            try await client.deleteSession(scope: target.routeScope, sessionId: target.sessionId)
            removeSession(workspaceId: target.workspaceId, sessionId: target.sessionId)
            return true
        } catch let error as MacWorkspaceClientError {
            if case .server(let status, _) = error, status == 404 {
                removeSession(workspaceId: target.workspaceId, sessionId: target.sessionId)
                return true
            }
            workspaceSnapshotLogger.warning("Workspace session delete failed: \(error.localizedDescription, privacy: .public)")
            sessionActionErrors[target.sessionId] = "Delete failed: \(error.localizedDescription)"
            return false
        } catch {
            workspaceSnapshotLogger.warning("Workspace session delete failed: \(error.localizedDescription, privacy: .public)")
            sessionActionErrors[target.sessionId] = "Delete failed: \(error.localizedDescription)"
            return false
        }
    }

    func loadSessions(
        workspaceId: String,
        worktreeId: String? = nil,
        client: MacWorkspaceClient
    ) async {
        let generation = (currentSessionLoadByWorkspace[workspaceId]?.generation ?? 0) &+ 1
        let request = SessionLoadRequest(
            workspaceId: workspaceId,
            worktreeId: worktreeId,
            generation: generation
        )
        currentSessionLoadByWorkspace[workspaceId] = request
        loadingSessionWorkspaceIds.insert(workspaceId)
        sessionErrors[workspaceId] = nil
        do {
            let until = Date()
            let since = until.addingTimeInterval(-3 * 24 * 60 * 60)
            let list = try await client.getWorkspaceSessions(
                workspaceId: workspaceId,
                since: since,
                until: until,
                worktreeId: worktreeId
            )
            guard isCurrentSessionLoad(request) else { return }
            sessionsByWorkspace[workspaceId] = list
            loadingSessionWorkspaceIds.remove(workspaceId)
        } catch is CancellationError {
            guard isCurrentSessionLoad(request) else { return }
            loadingSessionWorkspaceIds.remove(workspaceId)
        } catch {
            guard isCurrentSessionLoad(request) else { return }
            workspaceSnapshotLogger.warning("Workspace session load failed: \(error.localizedDescription, privacy: .public)")
            sessionErrors[workspaceId] = error.localizedDescription
            loadingSessionWorkspaceIds.remove(workspaceId)
        }
    }

    private func isCurrentSessionLoad(_ request: SessionLoadRequest) -> Bool {
        currentSessionLoadByWorkspace[request.workspaceId] == request
    }

    /// Returns true when the caller must repair from HTTP snapshots.
    @discardableResult
    func applyAppEvent(_ event: AppEventMessage) -> Bool {
        switch event {
        case .connected(_, let snapshotRequired):
            return snapshotRequired

        case .sessionCreated(_, let workspaceId, _, let summary),
             .sessionImported(_, let workspaceId, _, let summary),
             .sessionDiscovered(_, let workspaceId, _, let summary),
             .sessionSummary(_, let workspaceId, _, let summary):
            upsertAppEventSummary(summary, workspaceId: workspaceId)

        case .sessionDeleted(let sessionId, let workspaceId, _):
            removeSession(
                workspaceId: workspaceId ?? target(for: sessionId)?.workspaceId ?? "",
                sessionId: sessionId
            )
            screenAwakeController.clearSessionActivity(sessionId: sessionId)
            MacAttentionNotificationService.shared.cancelAskNotification(sessionId: sessionId)

        case .sessionEnded(let sessionId, let workspaceId, _, _):
            updateSessionStatus(sessionId: sessionId, workspaceId: workspaceId, status: .stopped)
            MacAttentionNotificationService.shared.cancelAskNotification(sessionId: sessionId)

        case .stopRequested(let sessionId, let workspaceId, _, _, _):
            updateSessionStatus(sessionId: sessionId, workspaceId: workspaceId, status: .stopping)

        case .stopConfirmed(let sessionId, let workspaceId, _, _, _):
            updateSessionStatus(
                sessionId: sessionId,
                workspaceId: workspaceId,
                status: .ready,
                onlyFrom: .stopping
            )
            MacAttentionNotificationService.shared.cancelAskNotification(sessionId: sessionId)

        case .stopFailed(let sessionId, let workspaceId, _, _, _):
            updateSessionStatus(
                sessionId: sessionId,
                workspaceId: workspaceId,
                status: .busy,
                onlyFrom: .stopping
            )

        case .sessionError(let sessionId, let workspaceId, _, _, _, let fatal):
            updateSessionStatus(sessionId: sessionId, workspaceId: workspaceId, status: .error)
            if fatal {
                MacAttentionNotificationService.shared.cancelAskNotification(sessionId: sessionId)
            }

        case .extensionUIRequest(let request, _, _):
            if let ask = request.askRequest {
                MacAttentionNotificationService.shared.notifyAskIfNeeded(ask)
            }

        case .extensionUISettled(_, let sessionId, _, _):
            MacAttentionNotificationService.shared.cancelAskNotification(sessionId: sessionId)

        case .extensionUINotification, .workspaceGitChanged, .ignored:
            break
        }
        return false
    }

    func runAppEventStreamFromLocalConfig() async {
        guard let client = MacWorkspaceClient.localOwner() else { return }
        let dataDir = ServerProcessManager.serverDataDir
        guard let token = MacAPIClient.readOwnerToken(dataDir: dataDir) else { return }
        await runAppEventStream(
            socketPath: MacLocalAPISocket.path(dataDir: dataDir),
            token: token,
            onSnapshotRequired: { await self.loadRecentSessions(client: client) }
        )
    }

    func runAppEventStream(
        socketPath: String,
        token: String,
        onSnapshotRequired: @escaping () async -> Void
    ) async {
        while !Task.isCancelled {
            let transport = MacUnixWebSocketTransport(
                socketPath: socketPath,
                path: MacUnixWebSocketTransport.appEventPath(),
                headers: MacUnixWebSocketTransport.ownerHeaders(token: token)
            )
            do {
                try await withTaskCancellationHandler {
                    try await transport.connect()
                } onCancel: {
                    transport.cancel()
                }
                isStreamingAppEvents = true
                while !Task.isCancelled {
                    let message = try await withTaskCancellationHandler {
                        try await transport.receive()
                    } onCancel: {
                        transport.cancel()
                    }
                    let text: String
                    switch message {
                    case .text(let value):
                        text = value
                    case .data(let data):
                        text = String(data: data, encoding: .utf8) ?? ""
                    }
                    let event = try AppEventMessage.decode(from: text)
                    if applyAppEvent(event) {
                        await onSnapshotRequired()
                    }
                }
            } catch is CancellationError {
                await transport.close(code: 1000, reason: nil)
                break
            } catch {
                workspaceSnapshotLogger.debug(
                    "App event stream ended: \(error.localizedDescription, privacy: .public)"
                )
            }
            isStreamingAppEvents = false
            transport.cancel()
            if Task.isCancelled { break }
            try? await Task.sleep(for: .seconds(2))
        }
        isStreamingAppEvents = false
    }

    private func existingTarget(workspaceId: String, sessionId: String) -> MacSelectedSessionTarget {
        if let existing = target(for: sessionId) {
            return MacSelectedSessionTarget(
                workspaceId: workspaceId,
                sessionId: sessionId,
                summary: existing.summary
            )
        }
        return MacSelectedSessionTarget(
            workspaceId: workspaceId,
            sessionId: sessionId,
            summary: SessionSummary(from: Session(
                id: sessionId,
                workspaceId: workspaceId.isEmpty ? nil : workspaceId,
                status: .busy,
                createdAt: Date(),
                lastActivity: Date(),
                messageCount: 0,
                tokens: TokenUsage(input: 0, output: 0),
                cost: 0
            ))
        )
    }

    private func upsertAppEventSummary(_ summary: SessionSummary, workspaceId: String?) {
        var normalized = summary
        if normalized.workspaceId == nil, let workspaceId, !workspaceId.isEmpty {
            normalized.workspaceId = workspaceId
        }
        syncScreenAwake(for: normalized.session, previousStatus: target(for: normalized.id)?.summary.status)
        if normalized.control != nil {
            noteOpenedSession(
                MacSelectedSessionTarget(
                    workspaceId: normalized.workspaceId ?? "",
                    sessionId: normalized.id,
                    summary: normalized
                )
            )
            return
        }
        guard let resolvedWorkspaceId = normalized.workspaceId, !resolvedWorkspaceId.isEmpty else {
            return
        }
        upsertRecentTarget(
            MacSelectedSessionTarget(
                workspaceId: resolvedWorkspaceId,
                sessionId: normalized.id,
                summary: normalized
            )
        )
        upsertSession(normalized.session, fallbackWorkspaceId: resolvedWorkspaceId)
    }

    private func updateSessionStatus(
        sessionId: String,
        workspaceId: String?,
        status: SessionStatus,
        onlyFrom: SessionStatus? = nil
    ) {
        guard var current = target(for: sessionId)?.summary.session else { return }
        if let onlyFrom, current.status != onlyFrom {
            return
        }
        let previousStatus = current.status
        current.status = status
        upsertSession(current, fallbackWorkspaceId: workspaceId ?? current.workspaceId ?? "")
        syncScreenAwake(for: current, previousStatus: previousStatus)
    }

    private func syncScreenAwake(for session: Session, previousStatus: SessionStatus?) {
        if session.status.isRunning {
            screenAwakeController.setSessionActivity(true, sessionId: session.id)
        } else if previousStatus?.isRunning == true {
            screenAwakeController.setSessionActivity(false, sessionId: session.id)
        }
    }

    private func upsertRecentTarget(_ target: MacSelectedSessionTarget) {
        recentSessionTargets.removeAll { $0.sessionId == target.sessionId }
        recentSessionTargets.append(target)
    }

    private func upsertSession(_ session: Session, fallbackWorkspaceId: String) {
        let workspaceId = session.workspaceId ?? fallbackWorkspaceId
        let summary = SessionSummary(from: session)
        upsertRecentTarget(
            MacSelectedSessionTarget(
                workspaceId: workspaceId,
                sessionId: session.id,
                summary: summary
            )
        )
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
        recentSessionTargets.removeAll { $0.sessionId == sessionId }
        guard let list = sessionsByWorkspace[workspaceId] else { return }
        sessionsByWorkspace[workspaceId] = MacWorkspaceClient.WorkspaceSessionList(
            workspaceId: list.workspaceId,
            serverNow: list.serverNow,
            active: list.active.filter { $0.id != sessionId },
            stopped: list.stopped.filter { $0.id != sessionId },
            importableSessions: list.importableSessions
        )
    }

    private func removeImportableSession(workspaceId: String, path: String) {
        guard let list = sessionsByWorkspace[workspaceId] else { return }
        sessionsByWorkspace[workspaceId] = MacWorkspaceClient.WorkspaceSessionList(
            workspaceId: list.workspaceId,
            serverNow: list.serverNow,
            active: list.active,
            stopped: list.stopped,
            importableSessions: list.importableSessions.filter { $0.path != path }
        )
    }

    #if DEBUG
    func _setCatalogForTesting(
        workspaces: [Workspace],
        summaries: [String: WorkspaceListSummary] = [:],
        sessionsByWorkspace: [String: MacWorkspaceClient.WorkspaceSessionList] = [:],
        recentSessionTargets: [MacSelectedSessionTarget] = []
    ) {
        self.workspaces = workspaces
        self.summaries = summaries
        self.sessionsByWorkspace = sessionsByWorkspace
        self.recentSessionTargets = recentSessionTargets
    }
    #endif
}
