import Testing
import Foundation
@testable import Oppi

private func decodeSessionSummaryJSON(_ json: String) throws -> SessionSummary {
    let data = Data(json.utf8)
    return try JSONDecoder().decode(SessionSummary.self, from: data)
}

@Suite("SessionStore Partitioning")
@MainActor
struct SessionStorePartitioningTests {

    // MARK: - Server partitioning

    @Test func sessionsPartitionedByServer() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "s1"))

        store.switchServer(to: "srv2")
        store.upsert(makeTestSession(id: "s2"))

        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].id == "s2")

        store.switchServer(to: "srv1")
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].id == "s1")
    }

    @Test func sessionsForSpecificServer() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "s1"))
        store.switchServer(to: "srv2")
        store.upsert(makeTestSession(id: "s2"))

        #expect(store.sessions(forServer: "srv1").count == 1)
        #expect(store.sessions(forServer: "srv1")[0].id == "s1")
        #expect(store.sessions(forServer: "nonexistent").isEmpty)
    }

    @Test func listProjectionPartitionedByServerAndWorkspace() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "s1", workspaceId: "w1"))
        store.upsert(makeTestSession(id: "s2", workspaceId: "w2"))

        store.switchServer(to: "srv2")
        store.upsert(makeTestSession(id: "s3", workspaceId: "w1"))

        #expect(store.listProjectionSessions.map(\.id) == ["s3"])
        #expect(store.listProjectionSessions(workspaceId: "w1").map(\.id) == ["s3"])

        store.switchServer(to: "srv1")
        #expect(Set(store.listProjectionSessions.map(\.id)) == Set(["s1", "s2"]))
        #expect(store.listProjectionSessions(workspaceId: "w1").map(\.id) == ["s1"])
    }

    @Test func listProjectionMirrorsSnapshotAndRemove() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "local", workspaceId: "w1", status: .busy))

        store.applyServerSnapshot([
            makeTestSession(id: "remote", workspaceId: "w1", status: .ready)
        ])

        #expect(Set(store.listProjectionSessions.map(\.id)) == Set(["local", "remote"]))

        store.remove(id: "local")
        #expect(store.listProjectionSessions.map(\.id) == ["remote"])
    }

    @Test func upsertManyAppliesOneMergedBatch() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "existing", workspaceId: "w1", status: .ready))

        let didMutate = store.upsertMany([
            makeTestSession(id: "new-a", workspaceId: "w1", status: .busy),
            makeTestSession(id: "existing", workspaceId: "w1", status: .stopped),
            makeTestSession(id: "new-b", workspaceId: "w2", status: .ready)
        ])

        #expect(didMutate)
        #expect(store.session(id: "existing")?.status == .stopped)
        #expect(Set(store.listProjectionSessions.map(\.id)) == Set(["existing", "new-a", "new-b"]))
        #expect(Set(store.listProjectionSessions(workspaceId: "w1").map(\.id)) == Set(["existing", "new-a"]))
    }

    @Test func upsertManyReturnsFalseForUnchangedBatch() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        let session = makeTestSession(id: "s1", workspaceId: "w1", status: .ready)
        store.upsert(session)

        #expect(!store.upsertMany([session]))
    }

    @Test func upsertManySummariesStoresAttentionCountsByServer() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        var summary = SessionSummary(from: makeTestSession(id: "s1", workspaceId: "w1", status: .ready))
        summary.pendingAskCount = 1

        #expect(store.upsertManySummaries([summary]))
        #expect(store.listPendingAskCount(for: "s1") == 1)

        store.switchServer(to: "srv2")
        #expect(store.listPendingAskCount(for: "s1") == 0)

        store.switchServer(to: "srv1")
        summary.pendingAskCount = 0
        #expect(store.upsertManySummaries([summary]))
        #expect(store.listPendingAskCount(for: "s1") == 0)
    }

    @Test func summaryMissingPendingAskCountPreservesExistingAttention() throws {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        var initial = SessionSummary(from: makeTestSession(id: "s1", workspaceId: "w1", status: .busy))
        initial.pendingAskCount = 2
        store.upsertManySummaries([initial])

        let missingCountSummary = try decodeSessionSummaryJSON(
            #"""
            {
              "id": "s1",
              "workspaceId": "w1",
              "status": "busy",
              "createdAt": 1700000000000,
              "lastActivity": 1700000001000,
              "messageCount": 1,
              "tokens": { "input": 0, "output": 0 },
              "cost": 0
            }
            """#
        )
        #expect(!missingCountSummary.hasPendingAskCount)

        store.applySummary(missingCountSummary)

        #expect(store.listPendingAskCount(for: "s1") == 2)
    }

    @Test func summaryPendingAskCountZeroAuthoritativelyClearsAttention() throws {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        var initial = SessionSummary(from: makeTestSession(id: "s1", workspaceId: "w1", status: .busy))
        initial.pendingAskCount = 2
        store.upsertManySummaries([initial])

        let clearingSummary = try decodeSessionSummaryJSON(
            #"""
            {
              "id": "s1",
              "workspaceId": "w1",
              "status": "busy",
              "createdAt": 1700000000000,
              "lastActivity": 1700000001000,
              "messageCount": 1,
              "tokens": { "input": 0, "output": 0 },
              "cost": 0,
              "pendingAskCount": 0
            }
            """#
        )
        #expect(clearingSummary.hasPendingAskCount)

        store.applySummary(clearingSummary)

        #expect(store.listPendingAskCount(for: "s1") == 0)
    }

    @Test func allSessionsSpansServers() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "s1", lastActivity: Date(timeIntervalSince1970: 100)))
        store.switchServer(to: "srv2")
        store.upsert(makeTestSession(id: "s2", lastActivity: Date(timeIntervalSince1970: 200)))

        let all = store.allSessions
        #expect(all.count == 2)
        #expect(all[0].id == "s2")
    }

    @Test func findSessionAcrossServers() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "s1"))
        store.switchServer(to: "srv2")
        store.upsert(makeTestSession(id: "s2"))

        let found = store.findSession(id: "s1")
        #expect(found?.session.id == "s1")
        #expect(found?.serverId == "srv1")
        #expect(store.findSession(id: "missing") == nil)
    }

    // MARK: - Upsert

    @Test func upsertReturnsFalseWhenUnchanged() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        let s = makeTestSession(id: "s1")
        store.upsert(s)
        #expect(store.upsert(s) == false)
    }

    @Test func upsertPreservesContextUsageWhenIncomingUpdateOmitsIt() {
        let store = SessionStore()
        store.switchServer(to: "srv1")

        var initial = makeTestSession(id: "s1", status: .busy, model: "anthropic/claude-sonnet-4-0")
        initial.contextTokens = 123_000
        initial.contextWindow = 200_000
        store.upsert(initial)

        let stopped = makeTestSession(id: "s1", status: .stopped, model: "anthropic/claude-sonnet-4-0")
        store.upsert(stopped)

        #expect(store.session(id: "s1")?.status == .stopped)
        #expect(store.session(id: "s1")?.contextTokens == 123_000)
        #expect(store.session(id: "s1")?.contextWindow == 200_000)
    }

    @Test func upsertPreservesLastNonZeroContextUsageWhenIncomingUpdateReportsZero() {
        let store = SessionStore()
        store.switchServer(to: "srv1")

        var initial = makeTestSession(id: "s1", status: .busy, model: "openai-codex/gpt-5.4")
        initial.contextTokens = 142_198
        initial.contextWindow = 272_000
        store.upsert(initial)

        var stopped = makeTestSession(id: "s1", status: .stopped, model: "openai-codex/gpt-5.4")
        stopped.contextTokens = 0
        stopped.contextWindow = 272_000
        store.upsert(stopped)

        #expect(store.session(id: "s1")?.status == .stopped)
        #expect(store.session(id: "s1")?.contextTokens == 142_198)
    }

    @Test func upsertPreservesWorkingTurnStartWhenIncomingBusyUpdateOmitsIt() {
        let store = SessionStore()
        store.switchServer(to: "srv1")

        let turnStart = Date(timeIntervalSince1970: 1_700_000_123)
        let initial = makeTestSession(id: "s1", status: .busy, currentTurnStartedAt: turnStart)
        store.upsert(initial)

        let incoming = makeTestSession(id: "s1", status: .busy, currentTurnStartedAt: nil)
        store.upsert(incoming)

        #expect(store.session(id: "s1")?.currentTurnStartedAt == turnStart)
    }

    @Test func upsertPreservesWorkspaceContextAndModelWhenIncomingUpdateOmitsThem() {
        let store = SessionStore()
        store.switchServer(to: "srv1")

        let initial = makeTestSession(
            id: "s1",
            workspaceId: "w1",
            workspaceName: "Oppi",
            status: .stopped,
            model: "openai-codex/gpt-5.4"
        )
        store.upsert(initial)

        let incoming = makeTestSession(id: "s1", workspaceId: nil, workspaceName: nil, status: .stopped, model: nil)
        store.upsert(incoming)

        #expect(store.session(id: "s1")?.workspaceId == "w1")
        #expect(store.session(id: "s1")?.workspaceName == "Oppi")
        #expect(store.session(id: "s1")?.model == "openai-codex/gpt-5.4")
    }

    @Test func summaryAndFullStateMergesPreserveAgentPresentationSnapshot() {
        let store = SessionStore()
        store.switchServer(to: "srv1")

        var launched = makeTestSession(id: "s1", workspaceId: "w1", status: .busy)
        launched.launch = SessionLaunchMetadata(
            agentId: "agent-reviewer",
            agentIcon: .symbol("checkmark.shield")
        )
        store.upsert(launched)

        let partial = makeTestSession(id: "s1", workspaceId: "w1", status: .ready)
        store.upsert(partial)

        #expect(store.session(id: "s1")?.launch?.agentId == "agent-reviewer")
        #expect(store.session(id: "s1")?.launch?.agentIcon == .symbol("checkmark.shield"))
        #expect(store.listProjectionSessions.first?.launch?.agentIcon == .symbol("checkmark.shield"))
    }

    @Test func partialLaunchMetadataMergesAgentIdentityFieldsIndividually() {
        let store = SessionStore()
        store.switchServer(to: "srv1")

        var launched = makeTestSession(id: "s1", workspaceId: "w1", status: .busy)
        launched.launch = SessionLaunchMetadata(
            agentId: "agent-reviewer",
            agentIcon: .symbol("checkmark.shield")
        )
        store.upsert(launched)

        var sparse = makeTestSession(id: "s1", workspaceId: "w1", status: .ready)
        sparse.launch = SessionLaunchMetadata(agentId: "agent-reviewer", agentIcon: nil)
        store.upsert(sparse)

        #expect(store.session(id: "s1")?.launch?.agentId == "agent-reviewer")
        #expect(store.session(id: "s1")?.launch?.agentIcon == .symbol("checkmark.shield"))
        #expect(store.listProjectionSessions.first?.launch?.agentIcon == .symbol("checkmark.shield"))
    }

    @Test func applyServerSnapshotPreservesWorkspaceContextAndModelWhenSnapshotOmitsThem() {
        let store = SessionStore()
        store.switchServer(to: "srv1")

        let local = makeTestSession(
            id: "s1",
            workspaceId: "w1",
            workspaceName: "Oppi",
            status: .stopped,
            model: "openai-codex/gpt-5.4"
        )
        store.upsert(local)

        let remote = makeTestSession(id: "s1", workspaceId: nil, workspaceName: nil, status: .stopped, model: nil)
        store.applyServerSnapshot([remote])

        #expect(store.session(id: "s1")?.workspaceId == "w1")
        #expect(store.session(id: "s1")?.workspaceName == "Oppi")
        #expect(store.session(id: "s1")?.model == "openai-codex/gpt-5.4")
    }

    @Test func applyWorkspaceRecentSnapshotNormalizesMissingWorkspaceContext() {
        let store = SessionStore()
        store.switchServer(to: "srv1")

        let incoming = makeTestSession(id: "s1", workspaceId: nil, status: .stopped)
        store.applyWorkspaceRecentSnapshot(workspaceId: "w1", summaries: [SessionSummary(from: incoming)])

        #expect(store.session(id: "s1")?.workspaceId == "w1")
    }

    @Test func cacheSessionForNavigationDoesNotAddArchiveRowToListProjection() {
        let store = SessionStore()
        store.switchServer(to: "srv1")

        let hot = makeTestSession(id: "hot", workspaceId: "w1", status: .stopped)
        store.applyWorkspaceRecentSnapshot(workspaceId: "w1", summaries: [SessionSummary(from: hot)])

        let archived = makeTestSession(
            id: "archived",
            workspaceId: "w1",
            status: .stopped,
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            lastActivity: Date(timeIntervalSince1970: 1_600_000_000)
        )
        store.cacheSessionForNavigation(archived)

        #expect(store.session(id: "archived")?.workspaceId == "w1")
        #expect(store.listProjectionSessions(workspaceId: "w1").map(\.id) == ["hot"])
    }

    @Test func applySummaryUsesUpsertMergeSemantics() {
        let store = SessionStore()
        store.switchServer(to: "srv1")

        var initial = makeTestSession(id: "s1", status: .busy, model: "openai-codex/gpt-5.4")
        initial.contextTokens = 99
        store.upsert(initial)

        var projected = makeTestSession(id: "s1", status: .ready, model: "openai-codex/gpt-5.4")
        projected.contextTokens = nil
        let changed = store.applySummary(SessionSummary(from: projected))

        #expect(changed)
        #expect(store.session(id: "s1")?.status == .ready)
        #expect(store.session(id: "s1")?.contextTokens == 99)
    }

    @Test func staleSummaryDoesNotRegressReadySessionToBusy() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        let completedAt = Date(timeIntervalSince1970: 200)
        let turnStartedAt = Date(timeIntervalSince1970: 100)

        store.upsert(makeTestSession(
            id: "s1",
            status: .ready,
            lastActivity: completedAt,
            currentTurnStartedAt: nil
        ))

        let staleBusy = makeTestSession(
            id: "s1",
            status: .busy,
            lastActivity: turnStartedAt,
            currentTurnStartedAt: turnStartedAt
        )
        let changed = store.applySummary(SessionSummary(from: staleBusy))

        #expect(!changed)
        #expect(store.session(id: "s1")?.status == .ready)
        #expect(store.session(id: "s1")?.currentTurnStartedAt == nil)
        #expect(store.session(id: "s1")?.lastActivity == completedAt)
    }

    @Test func staleSummaryDoesNotRegressBusySessionToReady() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        let turnStartedAt = Date(timeIntervalSince1970: 200)
        let staleAt = Date(timeIntervalSince1970: 100)

        store.upsert(makeTestSession(
            id: "s1",
            status: .busy,
            lastActivity: turnStartedAt,
            currentTurnStartedAt: turnStartedAt
        ))

        let staleReady = makeTestSession(
            id: "s1",
            status: .ready,
            lastActivity: staleAt,
            currentTurnStartedAt: nil
        )
        let changed = store.applySummary(SessionSummary(from: staleReady))

        #expect(!changed)
        #expect(store.session(id: "s1")?.status == .busy)
        #expect(store.session(id: "s1")?.currentTurnStartedAt == turnStartedAt)
        #expect(store.session(id: "s1")?.lastActivity == turnStartedAt)
    }

    // MARK: - Remove

    @Test func removeClearsActiveSessionId() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "s1"))
        store.activeSessionId = "s1"

        store.remove(id: "s1")
        #expect(store.activeSessionId == nil)
        #expect(store.sessions.isEmpty)
    }

    // MARK: - Server removal

    @Test func removeServerClearsPartition() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "s1"))
        store.switchServer(to: "srv2")

        store.removeServer("srv1")
        #expect(store.sessions(forServer: "srv1").isEmpty)
    }

    @Test func removeActiveServerClearsId() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.removeServer("srv1")
        #expect(store.activeServerId == nil)
    }

    // MARK: - Snapshot merge

    @Test func snapshotReplacesData() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        // "old" is stopped and old enough to be dropped by the merge window
        store.upsert(makeTestSession(
            id: "old",
            status: .stopped,
            createdAt: Date(timeIntervalSinceNow: -600)
        ))

        let snapshot = [
            makeTestSession(id: "new1", lastActivity: Date(timeIntervalSince1970: 200)),
            makeTestSession(id: "new2", lastActivity: Date(timeIntervalSince1970: 100)),
        ]
        store.applyServerSnapshot(snapshot)

        #expect(store.sessions.count == 2)
        #expect(store.sessions[0].id == "new1")
    }

    @Test func snapshotPreservesActiveSessions() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "local-active", status: .busy))

        store.applyServerSnapshot([makeTestSession(id: "server-only")])

        let ids = Set(store.sessions.map(\.id))
        #expect(ids.contains("server-only"))
        #expect(ids.contains("local-active"))
    }

    @Test func snapshotPreservesRecentStopped() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "recent", status: .stopped, createdAt: Date()))

        store.applyServerSnapshot([makeTestSession(id: "server-only")])

        let ids = Set(store.sessions.map(\.id))
        #expect(ids.contains("recent"))
    }

    @Test func snapshotPreservesLastNonZeroContextUsageWhenServerSnapshotReportsZero() {
        let store = SessionStore()
        store.switchServer(to: "srv1")

        var local = makeTestSession(id: "s1", status: .stopped, model: "openai-codex/gpt-5.4")
        local.contextTokens = 142_198
        local.contextWindow = 272_000
        store.upsert(local)

        var remote = makeTestSession(id: "s1", status: .stopped, model: "openai-codex/gpt-5.4")
        remote.contextTokens = 0
        remote.contextWindow = 272_000
        store.applyServerSnapshot([remote])

        #expect(store.session(id: "s1")?.contextTokens == 142_198)
    }

    @Test func snapshotDropsOldStopped() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(
            id: "old",
            status: .stopped,
            createdAt: Date(timeIntervalSinceNow: -600)
        ))

        store.applyServerSnapshot([makeTestSession(id: "server-only")])

        let ids = Set(store.sessions.map(\.id))
        #expect(!ids.contains("old"))
    }

    // MARK: - Workspace recent snapshots

    @Test func workspaceRecentSnapshotPrunesMissingWorkspaceRows() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        store.upsert(makeTestSession(id: "active-old", workspaceId: "w1", status: .busy, lastActivity: now))
        store.upsert(makeTestSession(
            id: "old-stopped",
            workspaceId: "w1",
            status: .stopped,
            lastActivity: now.addingTimeInterval(-10 * 86_400)
        ))
        store.upsert(makeTestSession(id: "other-workspace", workspaceId: "w2", status: .busy, lastActivity: now))

        store.applyWorkspaceRecentSnapshot(
            workspaceId: "w1",
            summaries: [
                SessionSummary(from: makeTestSession(id: "incoming", workspaceId: "w1", status: .ready, lastActivity: now)),
                SessionSummary(from: makeTestSession(id: "recent-stopped", workspaceId: "w1", status: .stopped, lastActivity: now.addingTimeInterval(-60)))
            ],
            requestStartedAt: now
        )

        let ids = Set(store.sessions.map(\.id))
        #expect(ids.contains("incoming"))
        #expect(ids.contains("recent-stopped"))
        #expect(ids.contains("other-workspace"))
        #expect(!ids.contains("active-old"))
        #expect(!ids.contains("old-stopped"))
    }

    @Test func recentWorkspaceSummariesPruneMissingRowsForKnownWorkspaces() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        store.upsert(makeTestSession(id: "stale-working", workspaceId: "w1", status: .busy, lastActivity: now.addingTimeInterval(-7_200)))
        store.upsert(makeTestSession(id: "fresh-server", workspaceId: "w1", status: .stopped, lastActivity: now))
        store.upsert(makeTestSession(id: "unloaded-workspace", workspaceId: "w3", status: .busy, lastActivity: now))

        store.applyRecentWorkspaceSummaries(
            workspaceIds: Set(["w1", "w2"]),
            summaries: [
                SessionSummary(from: makeTestSession(id: "fresh-server", workspaceId: "w1", status: .stopped, lastActivity: now)),
                SessionSummary(from: makeTestSession(id: "other-known", workspaceId: "w2", status: .ready, lastActivity: now.addingTimeInterval(-60)))
            ],
            requestStartedAt: now
        )

        let ids = Set(store.listProjectionSessions.map(\.id))
        #expect(ids.contains("fresh-server"))
        #expect(ids.contains("other-known"))
        #expect(ids.contains("unloaded-workspace"))
        #expect(!ids.contains("stale-working"))
    }

    @Test func recentWorkspaceSummaryProjectionPrunesListButKeepsCachedSession() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        store.upsert(makeTestSession(id: "open-archive", workspaceId: "w1", status: .stopped, lastActivity: now.addingTimeInterval(-86_400)))
        store.upsert(makeTestSession(id: "fresh-server", workspaceId: "w1", status: .ready, lastActivity: now))
        store.activeSessionId = "open-archive"

        store.applyRecentWorkspaceSummaryProjection(
            workspaceIds: Set(["w1"]),
            summaries: [
                SessionSummary(from: makeTestSession(id: "fresh-server", workspaceId: "w1", status: .ready, lastActivity: now))
            ],
            requestStartedAt: now
        )

        let backingIds = Set(store.sessions.map(\.id))
        let projectionIds = Set(store.listProjectionSessions.map(\.id))
        #expect(backingIds.contains("open-archive"))
        #expect(projectionIds.contains("fresh-server"))
        #expect(!projectionIds.contains("open-archive"))
        #expect(store.activeSessionId == "open-archive")
    }

    @Test func recentWorkspaceSummaryProjectionDropsForeignAndNilWorkspaceRows() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        store.upsert(makeTestSession(id: "foreign-server-row", workspaceId: "w-studio", status: .ready, lastActivity: now.addingTimeInterval(-120)))
        store.upsert(makeTestSession(id: "missing-workspace-row", workspaceId: nil, status: .ready, lastActivity: now.addingTimeInterval(-60)))

        store.applyRecentWorkspaceSummaryProjection(
            workspaceIds: Set(["w-mini"]),
            summaries: [
                SessionSummary(from: makeTestSession(id: "mini-row", workspaceId: "w-mini", status: .ready, lastActivity: now))
            ],
            requestStartedAt: now
        )

        #expect(store.listProjectionSessions.map(\.id) == ["mini-row"])
    }

    @Test func recentWorkspaceSummaryProjectionClearsProjectionForAuthoritativeEmptyCatalog() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        var cached = SessionSummary(from: makeTestSession(id: "contaminated", workspaceId: "w-studio", status: .ready))
        cached.pendingAskCount = 2
        store.upsertManySummaries([cached])

        store.applyRecentWorkspaceSummaryProjection(
            workspaceIds: [],
            summaries: [],
            requestStartedAt: Date(timeIntervalSince1970: 1_700_100_000)
        )

        #expect(store.listProjectionSessions.isEmpty)
        #expect(store.listPendingAskCount(for: "contaminated") == 0)
        #expect(store.sessions.map(\.id) == ["contaminated"])
    }

    @Test func recentWorkspaceSummaryProjectionPreservesRecentOptimisticRows() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let justCreated = now.addingTimeInterval(10)
        store.upsert(makeTestSession(id: "optimistic", workspaceId: "w1", status: .ready, createdAt: justCreated, lastActivity: justCreated))

        store.applyRecentWorkspaceSummaryProjection(
            workspaceIds: Set(["w1"]),
            summaries: [],
            requestStartedAt: now
        )

        #expect(store.listProjectionSessions.map(\.id) == ["optimistic"])
    }

    @Test func workspaceRecentSnapshotPreservesRecentOptimisticLocalRows() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let justCreated = now.addingTimeInterval(10)
        store.upsert(makeTestSession(id: "optimistic", workspaceId: "w1", status: .ready, createdAt: justCreated, lastActivity: justCreated))

        store.applyWorkspaceRecentSnapshot(
            workspaceId: "w1",
            summaries: [],
            requestStartedAt: now
        )

        #expect(store.sessions.map(\.id) == ["optimistic"])
    }

    @Test func workspaceRecentSnapshotDoesNotReaddDeletedSessionFromStaleResponse() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        store.upsert(makeTestSession(id: "ghost", workspaceId: "w1", status: .stopped, lastActivity: now))

        store.remove(id: "ghost")
        store.applyWorkspaceRecentSnapshot(
            workspaceId: "w1",
            summaries: [SessionSummary(from: makeTestSession(id: "ghost", workspaceId: "w1", status: .stopped, lastActivity: now))],
            requestStartedAt: now
        )

        #expect(store.session(id: "ghost") == nil)
    }

    @Test func summaryUpdateDoesNotReaddDeletedSession() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        let session = makeTestSession(id: "ghost", workspaceId: "w1", status: .stopped)
        store.upsert(session)

        store.remove(id: "ghost")
        _ = store.applySummary(SessionSummary(from: session))

        #expect(store.session(id: "ghost") == nil)
    }

    @Test func serverSnapshotDoesNotReaddDeletedSession() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        let session = makeTestSession(id: "ghost", workspaceId: "w1", status: .stopped)
        store.upsert(session)

        store.remove(id: "ghost")
        store.applyServerSnapshot([session])

        #expect(store.session(id: "ghost") == nil)
    }

    // MARK: - Freshness

    @Test func freshnessPerServer() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.markSyncSucceeded()

        store.switchServer(to: "srv2")
        #expect(store.lastSuccessfulSyncAt == nil)

        store.switchServer(to: "srv1")
        #expect(store.lastSuccessfulSyncAt != nil)
    }

    @Test func syncLifecycle() {
        let store = SessionStore()
        store.switchServer(to: "srv1")

        store.markSyncStarted()
        #expect(store.isSyncing == true)

        store.markSyncSucceeded()
        #expect(store.isSyncing == false)
        #expect(store.lastSyncFailed == false)
        #expect(store.lastSuccessfulSyncAt != nil)
    }

    @Test func syncFailure() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.markSyncStarted()
        store.markSyncFailed()
        #expect(store.isSyncing == false)
        #expect(store.lastSyncFailed == true)
    }

    // MARK: - Convenience

    @Test func activeSessionLookup() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "s1"))
        store.activeSessionId = "s1"
        #expect(store.activeSession?.id == "s1")
    }

    @Test func workspaceIdForSession() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "s1", workspaceId: "w42"))
        #expect(store.workspaceId(for: "s1") == "w42")
        #expect(store.workspaceId(for: "missing") == nil)
    }

    @Test func sortByLastActivity() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.upsert(makeTestSession(id: "older", lastActivity: Date(timeIntervalSince1970: 100)))
        store.upsert(makeTestSession(id: "newer", lastActivity: Date(timeIntervalSince1970: 200)))
        store.sort()
        #expect(store.sessions[0].id == "newer")
    }
}

// MARK: - Unread completion tracking

@Suite("SessionStore Unread Completion Tracking")
@MainActor
struct SessionStoreUnreadCompletionTests {

    @Test func recordsUnreadCompletionForInactiveSession() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        let date = Date(timeIntervalSince1970: 3000)

        store.recordUnreadCompletion(sessionId: "s1", at: date)

        #expect(store.unreadCompletionDate(for: "s1") == date)
    }

    @Test func openingSessionClearsUnreadCompletion() {
        let store = SessionStore()
        store.switchServer(to: "srv1")
        store.recordUnreadCompletion(sessionId: "s1", at: Date(timeIntervalSince1970: 3000))

        store.activeSessionId = "s1"

        #expect(store.unreadCompletionDate(for: "s1") == nil)
    }

    @Test func unreadCompletionDatesArePartitionedByServer() {
        let store = SessionStore()
        let serverOneDate = Date(timeIntervalSince1970: 1000)
        let serverTwoDate = Date(timeIntervalSince1970: 2000)

        store.switchServer(to: "srv1")
        store.recordUnreadCompletion(sessionId: "s1", at: serverOneDate)
        store.switchServer(to: "srv2")
        store.recordUnreadCompletion(sessionId: "s1", at: serverTwoDate)

        #expect(store.unreadCompletionDate(for: "s1") == serverTwoDate)
        store.switchServer(to: "srv1")
        #expect(store.unreadCompletionDate(for: "s1") == serverOneDate)
    }
}

// MARK: - Context summary clearing


