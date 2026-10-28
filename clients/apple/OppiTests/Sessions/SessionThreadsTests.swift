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

    @Test func lanesTakeEachMembersStatus() {
        var members = orchestration
        members[3].status = .ready
        members[3].programStatus = ProgramStatus(state: .blocked, kind: .question, since: Date(timeIntervalSince1970: 60))
        members[1].programStatus = ProgramStatus(state: .done, since: Date(timeIntervalSince1970: 30))

        func status(_ member: Session) -> SessionStatusKind {
            SessionStatusKind.resolve(session: member, seenAt: nil)
        }
        let graph = SessionThreadLaneGraph.layout(
            members: members, rootId: "root", now: Date(timeIntervalSince1970: 100), status: status
        )

        #expect(graph.segments.first { $0.id == "review" }?.status == .question)
        #expect(graph.segments.first { $0.id == "master" }?.status == .working)
        // Done, still unseen, and stopped lifecycle: the outcome shows until seen.
        #expect(graph.segments.first { $0.id == "fix" }?.status == .done)
    }

    // MARK: Expanded threads

    @Test func expandingAThreadListsEveryDescendantAfterItsRootInOutlineOrder() {
        let root = session("root", status: .ready, created: 0)
        let late = session("late", parent: "root", created: 60)
        let early = session("early", parent: "root", created: 10)
        let grandchild = session("grandchild", parent: "early", created: 12)
        let great = session("great", parent: "grandchild", created: 13)
        let solo = session("solo", created: 5)
        let entries = SessionListEntries.threads(
            listed: [solo, root, late, early, grandchild, great], loaded: []
        )

        let rows = SessionListEntries.expanding(entries, expandedRoots: ["root"])

        #expect(rows.map(\.id) == ["solo", "root", "early", "grandchild", "great", "late"])
        #expect(rows.map(\.depth) == [0, 0, 1, 2, 3, 1])
        #expect(rows.map(\.isExpanded) == [false, true, false, false, false, false])
        #expect(rows.dropFirst(2).allSatisfy { $0.thread == nil && $0.outsideRoot == nil }, "Children are ordinary rows")
    }

    @Test func collapsedAndUnknownRootsListNothingExtra() {
        let root = session("root", status: .ready, created: 0)
        let child = session("child", parent: "root", created: 10)
        let entries = SessionListEntries.threads(listed: [root, child], loaded: [])

        #expect(SessionListEntries.expanding(entries, expandedRoots: []) == entries)
        #expect(SessionListEntries.expanding(entries, expandedRoots: ["child", "elsewhere"]) == entries)
        #expect(SessionListEntries.expanding(entries, expandedRoots: ["root"]).map(\.id) == ["root", "child"])
    }

    /// A thread is the whole launch tree: members running in another workspace are rows too.
    @Test func expandingAWorkspaceListThreadIncludesMembersFromOtherWorkspaces() {
        let root = session("root", workspace: "a", status: .ready, created: 10)
        let local = session("local", parent: "root", workspace: "a", created: 20)
        let remote = session("remote", parent: "root", workspace: "b", created: 30)
        let remoteChild = session("remote-child", parent: "remote", workspace: "b", created: 40)
        let entries = SessionListEntries.threads(listed: [root, local], loaded: [root, local, remote, remoteChild])

        let rows = SessionListEntries.expanding(entries, expandedRoots: ["root"])

        #expect(rows.map(\.id) == ["root", "local", "remote", "remote-child"])
        #expect(rows.map(\.depth) == [0, 1, 1, 2])
        #expect(rows.map(\.session.workspaceId) == ["a", "a", "b", "b"])
    }

    @Test func outlineListsEveryDescendantOnceEvenAroundAParentCycle() {
        let root = session("root", status: .ready, created: 0)
        // a and b name each other as parent; neither reaches the root.
        let rollup = SessionThreadRollup(
            root: root,
            members: [
                root,
                session("a", parent: "b", created: 1),
                session("b", parent: "a", created: 2),
                session("c", parent: "gone", created: 3),
            ]
        )

        let outline = rollup.outline
        #expect(Set(outline.map(\.session.id)) == ["a", "b", "c"])
        #expect(outline.count == 3)
        #expect(outline.first { $0.session.id == "c" }?.depth == 1, "An absent parent hangs the member off the root")
    }

    // MARK: Lanes

    private var orchestration: [Session] {
        [
            session("root", status: .ready, created: 0, last: 50),
            session("fix", parent: "root", created: 10, last: 30),
            session("master", parent: "root", status: .busy, created: 20, last: 90),
            session("review", parent: "root", created: 40, last: 60),
            session("worker", parent: "master", created: 70, last: 80),
        ]
    }

    @Test func lanesReuseSlotsOfStoppedSessions() {
        let members = orchestration
        let lanes = SessionThreadLanes.assign(root: members[0], others: Array(members.dropFirst()))

        #expect(lanes.laneBySessionId == ["root": 0, "fix": 1, "master": 2, "review": 1, "worker": 1])
        #expect(lanes.laneCount == 3)
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
}
