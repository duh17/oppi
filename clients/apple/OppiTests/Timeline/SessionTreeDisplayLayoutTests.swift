import Testing
@testable import Oppi

@Suite("Session tree display layout")
struct SessionTreeDisplayLayoutTests {
    @Test("keeps linear chain flat until a branch split")
    func keepsLinearChainFlatUntilBranchSplit() {
        let nodes = [
            node(id: "entry-1", parentId: nil, depth: 0),
            node(id: "entry-2", parentId: "entry-1", depth: 1),
            node(id: "entry-3", parentId: "entry-2", depth: 2),
            node(id: "entry-4", parentId: "entry-3", depth: 3),
            node(id: "entry-5", parentId: "entry-2", depth: 2),
            node(id: "entry-6", parentId: "entry-5", depth: 3),
        ]

        let display = SessionTreeDisplayLayout.displayNodes(
            visibleNodes: nodes,
            allNodes: nodes
        )

        #expect(depth(of: "entry-1", in: display) == 0)
        #expect(depth(of: "entry-2", in: display) == 0)
        #expect(depth(of: "entry-3", in: display) == 1)
        #expect(depth(of: "entry-4", in: display) == 2)
        #expect(depth(of: "entry-5", in: display) == 1)
        #expect(depth(of: "entry-6", in: display) == 2)
    }

    @Test("reattaches filtered nodes to nearest visible ancestor")
    func reattachesToNearestVisibleAncestor() {
        let allNodes = [
            node(id: "entry-1", parentId: nil, depth: 0),
            node(id: "entry-2", parentId: "entry-1", depth: 1),
            node(id: "entry-3", parentId: "entry-2", depth: 2),
            node(id: "entry-4", parentId: "entry-3", depth: 3),
        ]

        // Simulate search filtering that hides entry-2.
        let visibleNodes = [
            allNodes[0],
            allNodes[2],
            allNodes[3],
        ]

        let display = SessionTreeDisplayLayout.displayNodes(
            visibleNodes: visibleNodes,
            allNodes: allNodes
        )

        #expect(display.map(\.id) == ["entry-1", "entry-3", "entry-4"])
        #expect(depth(of: "entry-1", in: display) == 0)
        #expect(depth(of: "entry-3", in: display) == 0)
        #expect(depth(of: "entry-4", in: display) == 0)
    }

    @Test("multiple roots use virtual branch indentation")
    func multipleRootsUseVirtualBranchIndentation() {
        let nodes = [
            node(id: "root-a", parentId: nil, depth: 0),
            node(id: "child-a", parentId: "root-a", depth: 1),
            node(id: "root-b", parentId: nil, depth: 0),
            node(id: "child-b", parentId: "root-b", depth: 1),
        ]

        let display = SessionTreeDisplayLayout.displayNodes(
            visibleNodes: nodes,
            allNodes: nodes
        )

        #expect(depth(of: "root-a", in: display) == 0)
        #expect(depth(of: "root-b", in: display) == 0)
        #expect(depth(of: "child-a", in: display) == 1)
        #expect(depth(of: "child-b", in: display) == 1)
    }

    private func node(
        id: String,
        parentId: String?,
        depth: Int
    ) -> SessionTreeNodeSnapshot {
        SessionTreeNodeSnapshot(
            id: id,
            parentId: parentId,
            type: "message",
            timestamp: "2026-04-20T00:00:00.000Z",
            depth: depth,
            isLeafPath: false,
            role: "assistant",
            textPreview: id,
            label: nil
        )
    }

    private func depth(of id: String, in nodes: [SessionTreeDisplayNode]) -> Int? {
        nodes.first(where: { $0.id == id })?.displayDepth
    }
}
