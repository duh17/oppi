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

    // MARK: Thread links

    @Test func aSessionsThreadRootIsTheTopOfItsLoadedChain() {
        let loaded = [
            session("grandchild", parent: "child", created: 30),
            session("root", status: .ready, created: 10),
            session("child", parent: "root", created: 20),
            session("other", status: .ready, created: 5),
        ]

        #expect(SessionThreadGrouping.rootId(of: "grandchild", in: loaded) == "root")
        #expect(SessionThreadGrouping.rootId(of: "root", in: loaded) == "root")
        #expect(SessionThreadGrouping.rootId(of: "other", in: loaded) == "other", "A session with no children is its own root")
        #expect(SessionThreadGrouping.rootId(of: "missing", in: loaded) == nil)
        // With the parent not loaded, the loaded top of the chain stands in for the root.
        #expect(SessionThreadGrouping.rootId(of: "grandchild", in: [loaded[0], loaded[2]]) == "child")
        // A parent cycle resolves both members to the one root the list shows for it.
        let cycle = [session("a", parent: "b", created: 1), session("b", parent: "a", created: 2)]
        let cycleRoot = SessionThreadGrouping.rollups(from: cycle).first?.root.id
        #expect(cycleRoot != nil)
        #expect(SessionThreadGrouping.rootId(of: "a", in: cycle) == cycleRoot)
        #expect(SessionThreadGrouping.rootId(of: "b", in: cycle) == cycleRoot)
    }

    @Test func theMissingAncestorIsTheFirstUnloadedParentOnTheChain() {
        let grandchild = session("grandchild", parent: "child", created: 30)
        let child = session("child", parent: "root", created: 20)
        let root = session("root", status: .ready, created: 10)

        #expect(SessionThreadGrouping.missingAncestorId(of: "grandchild", in: [grandchild]) == "child")
        #expect(SessionThreadGrouping.missingAncestorId(of: "grandchild", in: [grandchild, child]) == "root")
        #expect(SessionThreadGrouping.missingAncestorId(of: "grandchild", in: [grandchild, child, root]) == nil)
        #expect(SessionThreadGrouping.missingAncestorId(of: "absent", in: [root]) == nil)
        // A parent cycle has no end to load.
        let a = session("a", parent: "b", created: 1)
        let b = session("b", parent: "a", created: 2)
        #expect(SessionThreadGrouping.missingAncestorId(of: "a", in: [a, b]) == nil)
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

    /// Live statuses by the kinds the list sorts on, from lifecycle and program status.
    private enum Live { case blocked, working, error, done, idle }

    private func live(
        _ id: String,
        _ kind: Live,
        parent: String? = nil,
        created: TimeInterval,
        last: TimeInterval? = nil
    ) -> Session {
        var member = session(id, parent: parent, status: kind == .working ? .busy : .ready, created: created, last: last)
        let since = Date(timeIntervalSince1970: created)
        switch kind {
        case .blocked: member.programStatus = ProgramStatus(state: .blocked, kind: .question, since: since)
        case .working: member.programStatus = ProgramStatus(state: .working, since: since)
        case .error: member.programStatus = ProgramStatus(state: .error, since: since)
        case .done: member.programStatus = ProgramStatus(state: .done, since: since)
        case .idle: member.programStatus = ProgramStatus(state: .idle, since: since)
        }
        return member
    }

    private func expand(
        _ sessions: [Session],
        roots: Set<String> = ["root"],
        folds: [String: Bool] = [:],
        attention: (Session) -> SessionListAttentionCounts = { _ in .none }
    ) -> [SessionListEntry] {
        SessionListEntries.expanding(
            SessionListEntries.threads(listed: sessions, loaded: []),
            expandedRoots: roots,
            stoppedFolds: folds,
            attention: attention
        )
    }

    /// A row's id, with the Stopped fold written `fold(<count>)` or `fold(<count>, open)`.
    private func label(_ row: SessionListEntry) -> String {
        guard let fold = row.stoppedFold else { return row.id }
        return "fold(\(fold.count)\(fold.isOpen ? ", open" : ""))"
    }

    @Test func anOpenThreadListsLiveMembersFirstByKindAndFoldsTheStoppedOnes() {
        let root = session("root", status: .ready, created: 0)
        // Launch order puts the stopped workers first and the live ones last, as in a big thread.
        let sessions = [
            root,
            session("stopped-old", parent: "root", created: 10, last: 20),
            session("stopped-new", parent: "root", created: 11, last: 500),
            live("idle", .idle, parent: "root", created: 30, last: 300),
            live("done-old", .done, parent: "root", created: 31, last: 100),
            live("done-new", .done, parent: "root", created: 32, last: 400),
            live("error", .error, parent: "root", created: 33, last: 50),
            live("working-old", .working, parent: "root", created: 34, last: 600),
            live("working-new", .working, parent: "root", created: 35, last: 60),
            live("blocked", .blocked, parent: "root", created: 36, last: 10),
        ]

        let rows = expand(sessions)

        // The list's own order: Your Turn (blocked first, then the oldest activity), then Working
        // (newest launched first).
        #expect(rows.map(label) == [
            "root", "blocked", "error", "done-old", "idle", "done-new", "working-new", "working-old", "fold(2)",
        ])
        #expect(rows.map(\.isExpanded) == [true] + Array(repeating: false, count: 8))
        #expect(rows.dropFirst().allSatisfy { $0.thread == nil && $0.outsideRoot == nil }, "Children are ordinary rows")
        #expect(rows.last?.session.id == "root", "The fold row stands for the thread root")
    }

    @Test func aPendingQuestionRanksAMemberBlockedWithoutProgressStatus() {
        let sessions = [
            session("root", status: .ready, created: 0),
            session("busy", parent: "root", status: .busy, created: 10),
            session("asking", parent: "root", status: .ready, created: 5),
        ]

        let rows = expand(sessions) { SessionListAttentionCounts(askCount: $0.id == "asking" ? 1 : 0) }

        #expect(rows.map(\.id) == ["root", "asking", "busy"])
    }

    @Test func theStoppedFoldIsClosedUntilOpenedThenListsNewestFirst() {
        let sessions = [
            session("root", status: .ready, created: 0),
            session("old", parent: "root", created: 10, last: 100),
            session("new", parent: "root", created: 11, last: 900),
            session("middle", parent: "root", created: 12, last: 500),
            live("working", .working, parent: "root", created: 20),
        ]

        #expect(expand(sessions).map(label) == ["root", "working", "fold(3)"])
        #expect(expand(sessions, folds: ["root": false]).map(label) == ["root", "working", "fold(3)"])
        #expect(expand(sessions, folds: ["root": true]).map(label) == [
            "root", "working", "fold(3, open)", "new", "middle", "old",
        ])
    }

    @Test func aThreadWithNoStoppedMembersHasNoFold() {
        let rows = expand([
            session("root", status: .ready, created: 0),
            live("a", .done, parent: "root", created: 10),
            live("b", .working, parent: "root", created: 20),
        ])

        #expect(rows.map(label) == ["root", "a", "b"], "Your Turn lists before Working")
        #expect(rows.allSatisfy { $0.stoppedFold == nil })
    }

    @Test func aThreadWithOnlyStoppedMembersShowsJustTheFoldClosedUntilOpened() {
        let sessions = [
            session("root", status: .ready, created: 0),
            session("first", parent: "root", created: 10, last: 100),
            session("second", parent: "root", created: 11, last: 200),
        ]

        #expect(expand(sessions).map(label) == ["root", "fold(2)"], "The fold is closed by default, even with nothing live")
        #expect(expand(sessions, folds: ["root": true]).map(label) == ["root", "fold(2, open)", "second", "first"])
    }

    /// A working member's activity ticks as it streams; its row must not move for that, and a member
    /// that stops or resumes moves between the list and the fold with its row id.
    @Test func rowsKeepTheirPlaceWhileActivityTicksAndMembersMoveInAndOutOfTheFold() {
        func rows(_ sessions: [Session]) -> [String] { expand(sessions, folds: ["root": true]).map(label) }
        var working = live("working", .working, parent: "root", created: 20, last: 30)
        let otherWorking = live("other-working", .working, parent: "root", created: 10, last: 90)
        let done = live("done", .done, parent: "root", created: 5, last: 40)
        let root = session("root", status: .ready, created: 0)
        let before = rows([root, working, otherWorking, done])
        #expect(before == ["root", "done", "working", "other-working"])

        working.lastActivity = Date(timeIntervalSince1970: 500)
        #expect(rows([root, working, otherWorking, done]) == before, "A working member's activity does not reorder it")

        // Stopping moves the member into the fold; resuming brings it back to its place.
        var stopped = working
        stopped.status = .stopped
        #expect(rows([root, stopped, otherWorking, done]) == ["root", "done", "other-working", "fold(1, open)", "working"])
        #expect(rows([root, working, otherWorking, done]) == before)
    }

    @Test func eachThreadKeepsItsOwnFoldChoice() {
        let sessions = [
            session("a", status: .ready, created: 0),
            live("a-live", .working, parent: "a", created: 1),
            session("a-stopped", parent: "a", created: 2),
            session("b", status: .ready, created: 5),
            live("b-live", .working, parent: "b", created: 6),
            session("b-stopped", parent: "b", created: 7),
        ]

        let rows = expand(sessions, roots: ["a", "b"], folds: ["b": true])

        #expect(rows.map(label) == ["a", "a-live", "fold(1)", "b", "b-live", "fold(1, open)", "b-stopped"])
        #expect(Set(rows.map(\.id)).count == rows.count, "Each fold row has an id of its own")
    }

    /// Depth counts listed ancestors: a live child under a live parent keeps its place under it;
    /// a live member whose parent is stopped hangs off its nearest listed ancestor, or at depth 1.
    @Test func depthIsRelativeToTheNearestListedAncestor() {
        let sessions = [
            session("root", status: .ready, created: 0),
            live("parent", .working, parent: "root", created: 10),
            live("child", .working, parent: "parent", created: 11),
            session("stopped-mid", parent: "child", created: 12, last: 20),
            live("under-stopped", .done, parent: "stopped-mid", created: 13),
            session("stopped-top", parent: "root", created: 14, last: 30),
            live("under-stopped-top", .idle, parent: "stopped-top", created: 15),
            session("stopped-leaf", parent: "stopped-mid", created: 16, last: 10),
        ]

        let rows = expand(sessions, folds: ["root": true])

        #expect(rows.map(label) == [
            "root",
            "parent", "child",           // working tree: parent, then its child
            "under-stopped",             // done, under the stopped mid: nearest listed ancestor is `child`
            "under-stopped-top",         // idle, parent stopped: nothing listed above it
            "fold(3, open)",
            "stopped-top", "stopped-mid", "stopped-leaf",
        ])
        #expect(rows.map(\.depth) == [0, 1, 2, 3, 1, 1, 1, 1, 2])
    }

    /// A thread lists where its most urgent member would, so a blocked grandchild stays under
    /// its working parent and drags that pair above an unrelated working member.
    @Test func aLiveTreeSitsWhereItsMostUrgentMemberWould() {
        let sessions = [
            session("root", status: .ready, created: 0),
            live("newer", .working, parent: "root", created: 50),
            live("older", .working, parent: "root", created: 40),
            live("asks", .blocked, parent: "older", created: 45),
            live("newer-child", .done, parent: "newer", created: 60),
        ]

        let rows = expand(sessions)

        #expect(rows.map(\.id) == ["root", "older", "asks", "newer", "newer-child"])
        #expect(rows.map(\.depth) == [0, 1, 2, 1, 2])
    }

    @Test func collapsedAndUnknownRootsListNothingExtra() {
        let root = session("root", status: .ready, created: 0)
        let child = live("child", .working, parent: "root", created: 10)
        let entries = SessionListEntries.threads(listed: [root, child], loaded: [])
        func expanding(_ roots: Set<String>) -> [SessionListEntry] {
            SessionListEntries.expanding(entries, expandedRoots: roots, stoppedFolds: ["root": true], attention: { _ in .none })
        }

        #expect(expanding([]) == entries)
        #expect(expanding(["child", "elsewhere"]) == entries)
        #expect(expanding(["root"]).map(\.id) == ["root", "child"])
    }

    /// A thread is the whole launch tree: members running in another workspace are rows too.
    @Test func expandingAWorkspaceListThreadIncludesMembersFromOtherWorkspaces() {
        let root = session("root", workspace: "a", status: .ready, created: 10)
        let local = session("local", parent: "root", workspace: "a", created: 20)
        let remote = session("remote", parent: "root", workspace: "b", created: 30)
        let remoteChild = session("remote-child", parent: "remote", workspace: "b", created: 40)
        let entries = SessionListEntries.threads(listed: [root, local], loaded: [root, local, remote, remoteChild])

        let rows = SessionListEntries.expanding(
            entries, expandedRoots: ["root"], stoppedFolds: ["root": true], attention: { _ in .none }
        )

        // All stopped, fold opened. The newest member's tree lists first, a parent before its child.
        #expect(rows.map(label) == ["root", "fold(3, open)", "remote", "remote-child", "local"])
        #expect(rows.map(\.depth) == [0, 1, 1, 2, 1])
        #expect(rows.dropFirst(2).map(\.session.workspaceId) == ["b", "b", "a"])
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

        let listing = rollup.listing(attention: { _ in .none })
        #expect(listing.live.isEmpty)
        #expect(Set(listing.stopped.map(\.session.id)) == ["a", "b", "c"])
        #expect(listing.stopped.count == 3)
        #expect(listing.stopped.first { $0.session.id == "c" }?.depth == 1, "An absent parent hangs the member off the root")
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
