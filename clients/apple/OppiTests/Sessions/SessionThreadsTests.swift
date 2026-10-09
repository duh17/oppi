import Foundation
import Testing
@testable import Oppi

@Suite("Session threads")
struct SessionThreadsTests {
    private func session(
        _ id: String,
        parent: String? = nil,
        workspace: String = "ws",
        status: SessionStatus = .stopped,
        created: TimeInterval,
        last: TimeInterval? = nil,
        cost: Double = 1
    ) -> Session {
        Session(
            id: id,
            workspaceId: workspace,
            name: id,
            status: status,
            createdAt: Date(timeIntervalSince1970: created),
            lastActivity: Date(timeIntervalSince1970: last ?? created + 1),
            currentTurnStartedAt: status == .busy ? Date(timeIntervalSince1970: created) : nil,
            messageCount: 3,
            tokens: TokenUsage(input: 0, output: 0),
            cost: cost,
            parentSessionId: parent
        )
    }

    private func attentionFree(_: Session) -> SessionListAttentionCounts { .none }

    // MARK: Grouping

    @Test func groupsDescendantsUnderTheirLoadedRootAndOrphansBecomeRoots() {
        let rollups = SessionThreadGrouping.rollups(from: [
            session("grandchild", parent: "child", created: 30),
            session("root", status: .ready, created: 10),
            session("orphan", parent: "not-loaded", created: 5),
            session("child", parent: "root", created: 20),
        ])

        #expect(rollups.map(\.root.id) == ["root", "orphan"])
        #expect(rollups[0].members.map(\.id) == ["root", "child", "grandchild"])
        #expect(rollups[1].members.map(\.id) == ["orphan"])
    }

    // MARK: List entries

    /// A workspace list: its own sessions are listed, every loaded session feeds the trees.
    @Test func workspaceListShowsThreadsAtTheirRootAndLinksMembersRootedElsewhere() {
        let root = session("root", workspace: "a", status: .ready, created: 10)
        let localChild = session("local-child", parent: "root", workspace: "a", created: 20)
        let remoteChild = session("remote-child", parent: "root", workspace: "b", status: .busy, created: 30)
        let remoteGrandchild = session("remote-grandchild", parent: "remote-child", workspace: "b", created: 40)
        let solo = session("solo", workspace: "b", created: 5)
        let loaded = [root, localChild, remoteChild, remoteGrandchild, solo]

        let inA = SessionListEntries.threads(listed: [root, localChild], loaded: loaded)
        #expect(inA.map(\.id) == ["root"], "A listed child folds under its listed root")
        #expect(inA[0].thread?.members.map(\.id) == ["root", "local-child", "remote-child", "remote-grandchild"])
        #expect(inA[0].thread?.workspaceCount == 2)
        #expect(inA[0].outsideRoot == nil)

        let inB = SessionListEntries.threads(listed: [solo, remoteChild, remoteGrandchild], loaded: loaded)
        #expect(inB.map(\.id) == ["solo", "remote-child", "remote-grandchild"], "Rows keep list order and nothing is hidden")
        #expect(inB[0].thread == nil && inB[0].outsideRoot == nil)
        #expect(inB[1].outsideRoot?.id == "root" && inB[1].thread == nil)
        #expect(inB[2].outsideRoot?.id == "root")
    }

    @Test func flatListAndAllSessionsNeverLinkOutward() {
        let root = session("root", workspace: "a", created: 10)
        let child = session("child", parent: "root", workspace: "b", created: 20)

        let flat = SessionListEntries.flat([root, child])
        #expect(flat.map(\.id) == ["root", "child"])
        #expect(flat.allSatisfy { $0.thread == nil && $0.outsideRoot == nil })

        // All Sessions lists every loaded session, so each thread appears once at its root.
        let all = SessionListEntries.threads(listed: [child, root], loaded: [child, root])
        #expect(all.map(\.id) == ["root"])
        #expect(all[0].thread?.workspaceCount == 2)
    }

    @Test func threadRowSortsByItsLatestMember() {
        let root = session("root", created: 10, last: 11)
        let child = session("child", parent: "root", created: 20, last: 90)
        let entry = SessionListEntries.threads(listed: [root, child], loaded: [])[0]

        #expect(entry.representative.lastActivity == Date(timeIntervalSince1970: 90))
        #expect(entry.session.lastActivity == Date(timeIntervalSince1970: 11), "The row still shows the root itself")
    }

    @Test func parentCycleStillYieldsOneThread() {
        let rollups = SessionThreadGrouping.rollups(from: [
            session("a", parent: "b", created: 1),
            session("b", parent: "a", created: 2),
        ])

        #expect(rollups.count == 1)
        #expect(Set(rollups[0].members.map(\.id)) == ["a", "b"])
    }

    @Test(arguments: [
        // Idle orchestrator whose child works is Working, not Your Turn.
        ([SessionStatus.ready, .busy, .stopped], nil as Int?, SessionListActiveSectionKind.working as SessionListActiveSectionKind?),
        // A question anywhere beats work elsewhere.
        ([.ready, .busy, .ready], 2, .yourTurn),
        // A detached child still working after its root stopped keeps the thread visible.
        ([.stopped, .busy], nil, .working),
        // Idle root with only finished children waits on the user.
        ([.ready, .stopped, .stopped], nil, .yourTurn),
        ([.stopped, .stopped], nil, nil),
    ])
    func threadSectionFollowsEveryMember(
        statuses: [SessionStatus],
        attentionIndex: Int?,
        expected: SessionListActiveSectionKind?
    ) {
        let members = statuses.enumerated().map { index, status in
            session("s\(index)", parent: index == 0 ? nil : "s0", status: status, created: TimeInterval(index))
        }
        let rollup = SessionThreadGrouping.rollups(from: members)[0]

        let kind = SessionThreadGrouping.sectionKind(for: rollup) { member in
            member.id == attentionIndex.map { "s\($0)" }
                ? SessionListAttentionCounts(askCount: 1)
                : .none
        }

        #expect(kind == expected)
    }

    @Test func blockedChildPutsTheThreadInYourTurnEvenWhileOthersWork() {
        var members = [
            session("s0", status: .busy, created: 0),
            session("s1", parent: "s0", status: .busy, created: 1),
            session("s2", parent: "s0", status: .ready, created: 2),
        ]
        members[2].programStatus = ProgramStatus(state: .blocked, kind: .permission, since: Date())
        let rollup = SessionThreadGrouping.rollups(from: members)[0]

        #expect(SessionThreadGrouping.sectionKind(for: rollup, attention: attentionFree) == .yourTurn)
        #expect(SessionThreadGrouping.isBlocked(rollup, attention: attentionFree))
    }

    @Test func lanesAndWaterfallTakeEachMembersStatus() {
        var members = orchestration
        members[3].status = .ready
        members[3].programStatus = ProgramStatus(state: .blocked, kind: .question, since: Date(timeIntervalSince1970: 60))
        members[1].programStatus = ProgramStatus(state: .done, since: Date(timeIntervalSince1970: 30))
        let thread = snapshot(members)

        func status(_ member: Session) -> SessionStatusKind {
            SessionStatusKind.resolve(session: member, seenAt: nil)
        }
        let waterfall = SessionThreadWaterfall.build(snapshot: thread, now: Date(timeIntervalSince1970: 100), status: status)
        let graph = SessionThreadLaneGraph.layout(
            members: members, rootId: "root", now: Date(timeIntervalSince1970: 100), status: status
        )

        #expect(waterfall.rows.first { $0.id == "review" }?.status == .question)
        #expect(waterfall.rows.first { $0.id == "master" }?.status == .working)
        #expect(graph.segments.first { $0.id == "review" }?.status == .question)
        // Done, still unseen, and stopped lifecycle: the outcome shows until seen.
        #expect(graph.segments.first { $0.id == "fix" }?.status == .done)
    }

    // MARK: Timeline

    private func snapshot(
        _ sessions: [Session],
        interactions: [SessionInteraction] = [],
        counterparts: [SessionThreadCounterpart] = []
    ) -> SessionThreadSnapshot {
        SessionThreadSnapshot(rootSessionId: "root", sessions: sessions, interactions: interactions, counterparts: counterparts)
    }

    private var orchestration: [Session] {
        [
            session("root", status: .ready, created: 0, last: 50),
            session("fix", parent: "root", created: 10, last: 30),
            session("master", parent: "root", status: .busy, created: 20, last: 90),
            session("review", parent: "root", created: 40, last: 60),
            session("worker", parent: "master", created: 70, last: 80),
        ]
    }

    @Test func lanesReuseFreedSlotsAndBranchFromTheLaunchingSession() {
        let timeline = SessionThreadTimeline.build(snapshot: snapshot(orchestration), now: Date(timeIntervalSince1970: 100))

        #expect(timeline.laneBySessionId == ["root": 0, "fix": 1, "master": 2, "review": 1, "worker": 1])
        let workerLaunch = timeline.rows.first { $0.id == "launch:worker" }
        #expect(workerLaunch?.kind == .launch(parentLane: 2))
        let fixEnd = timeline.rows.first { $0.id == "end:fix" }
        #expect(fixEnd?.kind == .end(parentLane: 0))
        #expect(fixEnd?.lanesBelow.contains(1) == false)
        #expect(timeline.rows.last?.kind == .working(lanes: [2]))
    }

    @Test func aLockedMemberEndsWithoutItsCost() {
        let timeline = SessionThreadTimeline.build(
            snapshot: snapshot(orchestration),
            now: Date(timeIntervalSince1970: 100),
            hidesCost: { $0.id == "fix" }
        )

        #expect(timeline.rows.first { $0.id == "end:fix" }?.detail == "stopped")
        #expect(timeline.rows.first { $0.id == "end:review" }?.detail?.contains("$") == true)
    }

    @Test func idleRootLaneTurnsDashedAfterItsLastActivity() {
        let timeline = SessionThreadTimeline.build(snapshot: snapshot(orchestration), now: Date(timeIntervalSince1970: 100))

        #expect(timeline.rows.first { $0.id == "launch:review" }?.idleLanes.isEmpty == true)
        #expect(timeline.rows.first { $0.id == "end:review" }?.idleLanes == [0])
    }

    @Test func hidingAPrimitiveKeepsLaneContinuity() {
        let timeline = SessionThreadTimeline.build(
            snapshot: snapshot(orchestration),
            now: Date(timeIntervalSince1970: 100),
            filter: [.ends]
        )

        #expect(timeline.rows.map(\.id) == ["end:fix", "end:review", "end:worker", "now"])
        // Master launched at t=20 with its row hidden; its lane still runs through later rows.
        #expect(timeline.rows[0].lanesAbove.contains(2))
        #expect(timeline.rows[1].lanesBelow.contains(2))
    }

    @Test func interactionsSplitIntoInThreadAndCrossThreadRows() {
        let counterpart = SessionThreadCounterpart(
            id: "outside", name: "Sonnet max", status: .stopped, rootSessionId: "other-root", rootName: "Modularity"
        )
        let thread = snapshot(
            orchestration,
            interactions: [
                SessionInteraction(id: 1, at: Date(timeIntervalSince1970: 15), fromSessionId: "root", toSessionId: "outside", kind: .steer),
                SessionInteraction(id: 2, at: Date(timeIntervalSince1970: 75), fromSessionId: "master", toSessionId: "worker", kind: .followUp),
            ],
            counterparts: [counterpart]
        )

        let all = SessionThreadTimeline.build(snapshot: thread, now: Date(timeIntervalSince1970: 100))
        let cross = all.rows.first { $0.id == "interaction:1" }
        #expect(cross?.kind == .crossThread(.steer, counterpart: counterpart, outgoing: true))
        #expect(cross?.title == "steered Sonnet max")
        #expect(cross?.detail == "from root · in Modularity")
        #expect(all.rows.first { $0.id == "interaction:2" }?.kind == .interaction(.followUp, fromLane: 2))

        let messagesOnly = SessionThreadTimeline.build(snapshot: thread, now: Date(timeIntervalSince1970: 100), filter: [.messages])
        #expect(messagesOnly.rows.map(\.id) == ["interaction:2", "now"])
    }

    @Test func stopRecordedAtTheEndTimeSortsBeforeTheEndRow() throws {
        let stop = SessionInteraction(
            id: 9, at: Date(timeIntervalSince1970: 30), fromSessionId: "root", toSessionId: "fix", kind: .stop
        )
        let timeline = SessionThreadTimeline.build(
            snapshot: snapshot(orchestration, interactions: [stop]),
            now: Date(timeIntervalSince1970: 100)
        )

        let ids = timeline.rows.map(\.id)
        let stopIndex = try #require(ids.firstIndex(of: "interaction:9"))
        let endIndex = try #require(ids.firstIndex(of: "end:fix"))
        #expect(stopIndex < endIndex)
        // The stopped lane is still drawn through the stop row.
        #expect(timeline.rows.first { $0.id == "interaction:9" }?.lanesBelow.contains(1) == true)
    }

    // MARK: Lane graph

    @Test func laneGraphBranchesFromParentsAndFoldsExtraLanes() {
        let now = Date(timeIntervalSince1970: 100)
        let members = [
            session("root", status: .ready, created: 0, last: 50),
            session("a", parent: "root", created: 10, last: 90),
            session("b", parent: "root", status: .busy, created: 20, last: 100),
            session("c", parent: "a", created: 30, last: 60),
            session("d", parent: "root", created: 40, last: 70),
        ]

        let graph = SessionThreadLaneGraph.layout(members: members, rootId: "root", now: now, maxLanes: 3)
        let byId = Dictionary(uniqueKeysWithValues: graph.segments.map { ($0.id, $0) })

        #expect(graph.laneCount == 3)
        #expect(graph.hiddenLaneCount == 2)
        // Nine distinct event times, so each is one eighth of the width.
        #expect(byId["root"]?.parentLane == nil)
        #expect(byId["root"]?.idleFrom == 5.0 / 8)
        #expect(byId["a"]?.parentLane == 0)
        #expect(byId["a"]?.start == 1.0 / 8)
        #expect(byId["a"]?.end == 1)
        // Lanes 3 and 4 fold into the last visible lane, and branch from the right parent.
        #expect(byId["c"]?.lane == 2)
        #expect(byId["c"]?.parentLane == byId["a"]?.lane)
        #expect(byId["d"]?.lane == 2)
        #expect(byId["b"]?.isWorking == true)
        #expect(byId["b"]?.end == 1)
    }

    @Test func laneGraphGivesShortSessionsTheSameWidthAsLongOnes() {
        // A 2-second child and a 2-hour child, hours after the thread went quiet.
        let members = [
            session("root", created: 0, last: 9_000),
            session("short", parent: "root", created: 10, last: 12),
            session("long", parent: "root", created: 20, last: 7_220),
        ]

        let graph = SessionThreadLaneGraph.layout(members: members, rootId: "root", now: Date(timeIntervalSince1970: 90_000))
        let byId = Dictionary(uniqueKeysWithValues: graph.segments.map { ($0.id, $0) })
        let short = try? #require(byId["short"])
        let long = try? #require(byId["long"])

        #expect(byId["root"]?.end == 1)
        #expect(short.map { abs(($0.end - $0.start) - 1.0 / 5) < 1e-9 } == true)
        #expect(long.map { abs(($0.end - $0.start) - 1.0 / 5) < 1e-9 } == true)
    }

    // MARK: Agents and waterfall

    private func withAgent(_ session: Session, _ agentId: String?) -> Session {
        var copy = session
        copy.launch = agentId.map { SessionLaunchMetadata(agentId: $0, agentIcon: .emoji("🛠️")) }
        return copy
    }

    @Test func agentGroupsCountLargestFirstAndTreatNoAgentAsPi() {
        let sessions = [
            withAgent(session("a", created: 1), nil),
            withAgent(session("b", created: 2), "reviewer"),
            withAgent(session("c", created: 3), "worker"),
            withAgent(session("d", created: 4), "worker"),
            withAgent(session("e", created: 5), "reviewer"),
            withAgent(session("f", created: 6), "worker"),
        ]

        let groups = SessionThreadAgentGroup.groups(sessions)

        #expect(groups.map(\.id) == ["worker", "reviewer", "pi"])
        #expect(groups.map(\.count) == [3, 2, 1])
        #expect(groups.first?.agentIcon == .emoji("🛠️"))
    }

    @Test func waterfallOrdersRowsDepthFirstOnClockTime() {
        let members = [
            session("root", status: .ready, created: 0, last: 40),
            session("late", parent: "root", created: 60, last: 80),
            session("early", parent: "root", created: 10, last: 20),
            session("grandchild", parent: "early", created: 12, last: 18),
        ]
        let thread = snapshot(members, interactions: [
            SessionInteraction(id: 1, at: Date(timeIntervalSince1970: 15), fromSessionId: "early", toSessionId: "grandchild", kind: .steer),
        ])

        let waterfall = SessionThreadWaterfall.build(snapshot: thread, now: Date(timeIntervalSince1970: 100))

        #expect(waterfall.rows.map(\.id) == ["root", "early", "grandchild", "late"])
        #expect(waterfall.rows.map(\.depth) == [0, 1, 2, 1])
        // Clock time from the root's launch to the latest activity (80), not `now`.
        #expect(waterfall.rows[1].start == 10.0 / 80)
        #expect(waterfall.rows[1].end == 20.0 / 80)
        #expect(waterfall.rows[0].idleFrom == 40.0 / 80)
        #expect(waterfall.rows[0].end == 1)
        #expect(waterfall.messages.first.map { [$0.fromRow, $0.toRow] } == [1, 2])
    }

    // MARK: Prompt cache

    @Test(arguments: [
        (SessionStatus.busy, nil as SessionPromptCacheWarmer?, 60.0, SessionPromptCacheEstimate.inUse),
        (.ready, SessionPromptCacheWarmer(state: .scheduled, action: .warm, nextWarmAt: Date(timeIntervalSince1970: 400)), 200.0,
         .keptWarm(nextRefresh: Date(timeIntervalSince1970: 400))),
        (.ready, SessionPromptCacheWarmer(state: .refreshing), 1_000.0, .keptWarm(nextRefresh: nil)),
        // Pi decided to let it expire, or the refresh time passed without a newer snapshot: use the TTL.
        (.ready, SessionPromptCacheWarmer(state: .scheduled, action: .stop, nextWarmAt: Date(timeIntervalSince1970: 400)), 200.0,
         .warm(until: Date(timeIntervalSince1970: 400))),
        (.ready, SessionPromptCacheWarmer(state: .scheduled, action: .warm, nextWarmAt: Date(timeIntervalSince1970: 350)), 1_000.0,
         .cold),
        (.ready, nil, 200.0, .warm(until: Date(timeIntervalSince1970: 400))),
        (.ready, nil, 500.0, .cold),
        // A stopped session's warmer no longer runs; fall back to the TTL.
        (.stopped, SessionPromptCacheWarmer(state: .scheduled), 500.0, .cold),
    ])
    func cacheEstimateFollowsWarmerThenTTL(
        status: SessionStatus,
        warmer: SessionPromptCacheWarmer?,
        now: TimeInterval,
        expected: SessionPromptCacheEstimate
    ) {
        let target = session("s", status: status, created: 0, last: 100)
        let cache = SessionPromptCacheStatus(ttl: 300, lastRequestAt: Date(timeIntervalSince1970: 100), warmer: warmer)

        #expect(SessionPromptCacheEstimate.estimate(session: target, status: cache, now: Date(timeIntervalSince1970: now)) == expected)
    }

    @Test func cacheEstimateUsesTheNewestReplyAndNeedsATTL() {
        var target = session("s", status: .ready, created: 0, last: 100)
        target.lastAgentReplyAt = Date(timeIntervalSince1970: 350)
        let cache = SessionPromptCacheStatus(ttl: 300, lastRequestAt: Date(timeIntervalSince1970: 100))
        let now = Date(timeIntervalSince1970: 500)

        #expect(SessionPromptCacheEstimate.estimate(session: target, status: cache, now: now)
            == .warm(until: Date(timeIntervalSince1970: 650)))
        #expect(SessionPromptCacheEstimate.estimate(
            session: target,
            status: SessionPromptCacheStatus(ttl: nil, lastRequestAt: Date(timeIntervalSince1970: 100)),
            now: now
        ) == .unknown)
        #expect(SessionPromptCacheEstimate.estimate(session: target, status: nil, now: now) == .unknown)
    }

    @Test func cacheHitRateCountsReadsAgainstAllPromptTokens() {
        #expect(TokenUsage(input: 100, output: 50, cacheRead: 700, cacheWrite: 200).cacheHitRate == 0.7)
        #expect(TokenUsage(input: 0, output: 10, cacheRead: nil, cacheWrite: nil).cacheHitRate == nil)
    }

    // MARK: Wire

    @Test func snapshotDecodesParentLinksAndSkipsUnknownPrimitives() throws {
        let json = """
        {
          "rootSessionId": "root",
          "sessions": [
            {"id":"root","status":"ready","createdAt":1000,"lastActivity":2000,"messageCount":1,
             "tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"cost":0},
            {"id":"child","status":"busy","createdAt":1500,"lastActivity":2500,"messageCount":1,
             "tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"cost":0.5,"parentSessionId":"root"}
          ],
          "interactions": [
            {"id":1,"at":1600,"fromSessionId":"root","toSessionId":"child","kind":"steer"},
            {"id":2,"at":1700,"fromSessionId":"root","toSessionId":"child","kind":"future_primitive"}
          ],
          "counterparts": [
            {"id":"other","name":"Other","status":"stopped","workspaceId":"ws-2","model":"openai/gpt-6","rootSessionId":"other"}
          ],
          "promptCache": {
            "root": {"retention":"short","ttlMs":300000,"lastRequestAt":2000,"warmer":{"state":"scheduled","action":"warm","nextWarmAt":2270000}},
            "child": {"retention":"long","ttlMs":3600000,"warmer":{"state":"future_state"}}
          }
        }
        """

        let decoded = try JSONDecoder().decode(SessionThreadSnapshot.self, from: Data(json.utf8))

        #expect(decoded.sessions.map(\.parentSessionId) == [nil, "root"])
        #expect(decoded.interactions.map(\.kind) == [.steer])
        #expect(decoded.interactions.first?.at == Date(timeIntervalSince1970: 1.6))
        #expect(decoded.counterparts.first?.workspaceId == "ws-2")
        #expect(decoded.promptCache["root"] == SessionPromptCacheStatus(
            ttl: 300,
            lastRequestAt: Date(timeIntervalSince1970: 2),
            warmer: SessionPromptCacheWarmer(state: .scheduled, action: .warm, nextWarmAt: Date(timeIntervalSince1970: 2_270))
        ))
        // An unknown warmer state reads as inactive instead of failing the thread.
        #expect(decoded.promptCache["child"]?.warmer?.state == .inactive)
    }
}

/// Session Threads is an opt-in experiment: a device that never turned it on
/// must list every session flat, and the choice must survive a relaunch.
@Suite("Session Threads experiment", .serialized)
@MainActor
struct SessionThreadsExperimentTests {
    private func withCleanDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let key = AppPreferences.Experiments.sessionThreadsKey
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)
        body()
    }

    private func session(_ id: String, parent: String? = nil, created: TimeInterval) -> Session {
        Session(
            id: id,
            workspaceId: "ws",
            name: id,
            status: .ready,
            createdAt: Date(timeIntervalSince1970: created),
            lastActivity: Date(timeIntervalSince1970: created + 1),
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0,
            parentSessionId: parent
        )
    }

    @Test func unsetExperimentListsFlatAndEnablingGroupsThreads() {
        withCleanDefaults {
            let sessions = [session("root", created: 10), session("child", parent: "root", created: 20)]

            let fresh = AppNavigation()
            #expect(!fresh.sessionThreadsEnabled)
            let flat = SessionListEntries.entries(
                threadsEnabled: fresh.sessionThreadsEnabled, listed: sessions, loaded: sessions
            )
            #expect(flat.map(\.id) == ["root", "child"])
            #expect(flat.allSatisfy { $0.thread == nil && $0.outsideRoot == nil })

            fresh.sessionThreadsEnabled = true
            let relaunched = AppNavigation()
            #expect(relaunched.sessionThreadsEnabled, "The opt-in is saved on this device")
            let grouped = SessionListEntries.entries(
                threadsEnabled: relaunched.sessionThreadsEnabled, listed: sessions, loaded: sessions
            )
            #expect(grouped.map(\.id) == ["root"])
            #expect(grouped[0].thread?.members.map(\.id) == ["root", "child"])
        }
    }
}

@Suite("Session thread load")
struct SessionThreadLoadTests {
    @Test func threadSnapshotIsNotGatedOnAgentNames() async {
        let gate = NameGate()
        let snapshot = SessionThreadSnapshot(
            rootSessionId: "root", sessions: [], interactions: [], counterparts: []
        )
        let fetch = await completedWithin(.seconds(2)) {
            await SessionThreadLoad.fetch(
                needsAgentNames: true,
                listAgents: { await gate.park() },
                getThread: { snapshot }
            )
        }
        await gate.open()

        #expect(fetch?.snapshot?.rootSessionId == "root")
        #expect(fetch?.failure == nil)
        #expect(await fetch?.agentNames?.value?["a"] == "Ada")
    }

    @Test func threadFailureIsNotGatedOnAgentNames() async {
        let gate = NameGate()
        let fetch = await completedWithin(.seconds(2)) {
            await SessionThreadLoad.fetch(
                needsAgentNames: true,
                listAgents: { await gate.park() },
                getThread: { throw URLError(.timedOut) }
            )
        }
        await gate.open()

        #expect(fetch?.snapshot == nil)
        #expect(fetch?.failure?.errorKind == "timeout")
        #expect(await fetch?.agentNames?.value?["a"] == "Ada")
    }

    @Test func threadFailureKeepsTheThreadErrorWhenNamesAreMissing() async {
        struct ThreadDown: LocalizedError, Sendable {
            var errorDescription: String? { "thread down" }
        }
        let fetch = await SessionThreadLoad.fetch(
            needsAgentNames: true,
            listAgents: { nil },
            getThread: { throw ThreadDown() }
        )

        #expect(fetch.failure?.localizedDescription == "thread down")
        #expect(fetch.failure?.errorKind == "other")
        #expect(fetch.agentNames != nil)
        #expect(await fetch.agentNames?.value == nil)
    }

    @Test func knownAgentNamesSkipTheNameLookup() async {
        let fetch = await SessionThreadLoad.fetch(
            needsAgentNames: false,
            listAgents: { Issue.record("listAgents should not run"); return nil },
            getThread: {
                SessionThreadSnapshot(rootSessionId: "root", sessions: [], interactions: [], counterparts: [])
            }
        )

        #expect(fetch.snapshot?.rootSessionId == "root")
        #expect(fetch.agentNames == nil)
    }

    @Test func threadLoadTagsStayBounded() {
        #expect(ChatSessionTelemetry.threadLoadTags(phase: "refresh", status: "ok", errorKind: "network") == [
            "phase": "refresh",
            "status": "ok",
        ])
        #expect(ChatSessionTelemetry.threadLoadTags(phase: "initial", status: "error", errorKind: "timeout") == [
            "phase": "initial",
            "status": "error",
            "error_kind": "timeout",
        ])
        #expect(ChatSessionTelemetry.threadLoadTags(phase: "session-id", status: "failed", errorKind: " ") == [
            "phase": "initial",
            "status": "error",
            "error_kind": "other",
        ])
    }
}

/// Holds Agent-name lookup open until the test releases it.
private actor NameGate {
    private var isOpen = false
    private var names: [String: String]?
    private var waiters: [CheckedContinuation<[String: String]?, Never>] = []

    func park() async -> [String: String]? {
        if isOpen { return names }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func open(with names: [String: String]? = ["a": "Ada"]) {
        isOpen = true
        self.names = names
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(returning: names) }
    }
}

private func completedWithin<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            let value = await operation()
            return Optional(value)
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let winner = await group.next() ?? nil
        group.cancelAll()
        return winner
    }
}
