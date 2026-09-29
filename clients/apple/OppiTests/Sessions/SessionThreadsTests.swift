import Foundation
import Testing
@testable import Oppi

@Suite("Session threads")
struct SessionThreadsTests {
    private func session(
        _ id: String,
        parent: String? = nil,
        status: SessionStatus = .stopped,
        created: TimeInterval,
        last: TimeInterval? = nil,
        cost: Double = 1
    ) -> Session {
        Session(
            id: id,
            workspaceId: "ws",
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
          "counterparts": []
        }
        """

        let decoded = try JSONDecoder().decode(SessionThreadSnapshot.self, from: Data(json.utf8))

        #expect(decoded.sessions.map(\.parentSessionId) == [nil, "root"])
        #expect(decoded.interactions.map(\.kind) == [.steer])
        #expect(decoded.interactions.first?.at == Date(timeIntervalSince1970: 1.6))
    }
}
