@testable import OppiMac
import XCTest

final class OppiMacSessionTreeBuilderTests: XCTestCase {
    func testBuildUsesGraphParentChain() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let root = makeSession(id: "sess-root", lastActivity: base.addingTimeInterval(300))
        let childA = makeSession(id: "sess-child-a", lastActivity: base.addingTimeInterval(200))
        let childB = makeSession(id: "sess-child-b", lastActivity: base.addingTimeInterval(100))

        let graph = WorkspaceGraphResponse.SessionGraph(
            nodes: [
                makeNode(id: root.id, parentId: nil, createdAt: base, attached: [root.id], active: [root.id]),
                makeNode(id: childA.id, parentId: root.id, createdAt: base.addingTimeInterval(10), attached: [childA.id], active: [childA.id]),
                makeNode(id: childB.id, parentId: childA.id, createdAt: base.addingTimeInterval(20), attached: [childB.id], active: [childB.id]),
            ],
            edges: [
                .init(from: root.id, to: childA.id, type: .fork),
                .init(from: childA.id, to: childB.id, type: .fork),
            ],
            roots: [root.id]
        )

        let roots = OppiMacSessionTreeBuilder.build(
            sessions: [root, childA, childB],
            graph: graph
        )

        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots.first?.session.id, root.id)
        XCTAssertEqual(roots.first?.children.map(\.session.id), [childA.id])
        XCTAssertEqual(roots.first?.children.first?.children.map(\.session.id), [childB.id])
    }

    func testBuildWithoutGraphFallsBackToFlatRecencyOrder() {
        let base = Date(timeIntervalSince1970: 1_700_100_000)
        let stopped = makeSession(
            id: "sess-stopped",
            status: .stopped,
            lastActivity: base.addingTimeInterval(500)
        )
        let ready = makeSession(
            id: "sess-ready",
            status: .ready,
            lastActivity: base.addingTimeInterval(200)
        )
        let busy = makeSession(
            id: "sess-busy",
            status: .busy,
            lastActivity: base.addingTimeInterval(400)
        )

        let roots = OppiMacSessionTreeBuilder.build(
            sessions: [stopped, ready, busy],
            graph: nil
        )

        XCTAssertEqual(roots.map(\.session.id), [busy.id, ready.id, stopped.id])
        XCTAssertTrue(roots.allSatisfy { $0.children.isEmpty })
    }

    func testBuildTreatsMissingParentAsRoot() {
        let base = Date(timeIntervalSince1970: 1_700_200_000)
        let child = makeSession(id: "sess-child", lastActivity: base.addingTimeInterval(100))

        let graph = WorkspaceGraphResponse.SessionGraph(
            nodes: [
                makeNode(
                    id: child.id,
                    parentId: "missing-parent",
                    createdAt: base,
                    attached: [child.id],
                    active: [child.id]
                ),
            ],
            edges: [
                .init(from: "missing-parent", to: child.id, type: .fork),
            ],
            roots: []
        )

        let roots = OppiMacSessionTreeBuilder.build(
            sessions: [child],
            graph: graph
        )

        XCTAssertEqual(roots.map(\.session.id), [child.id])
        XCTAssertEqual(roots.first?.children.count, 0)
    }

    private func makeSession(
        id: String,
        status: SessionStatus = .ready,
        lastActivity: Date,
        createdAt: Date? = nil
    ) -> Session {
        Session(
            id: id,
            userId: "user-1",
            workspaceId: "ws-1",
            workspaceName: "Workspace",
            name: id,
            status: status,
            createdAt: createdAt ?? lastActivity.addingTimeInterval(-60),
            lastActivity: lastActivity,
            model: "anthropic/claude-sonnet-4-0",
            runtime: "container",
            messageCount: 0,
            tokens: .init(input: 0, output: 0),
            cost: 0,
            changeStats: nil,
            contextTokens: nil,
            contextWindow: nil,
            lastMessage: nil,
            thinkingLevel: nil
        )
    }

    private func makeNode(
        id: String,
        parentId: String?,
        createdAt: Date,
        attached: [String],
        active: [String]
    ) -> WorkspaceGraphResponse.SessionGraph.Node {
        WorkspaceGraphResponse.SessionGraph.Node(
            id: id,
            createdAt: createdAt,
            parentId: parentId,
            workspaceId: "ws-1",
            attachedSessionIds: attached,
            activeSessionIds: active
        )
    }
}
