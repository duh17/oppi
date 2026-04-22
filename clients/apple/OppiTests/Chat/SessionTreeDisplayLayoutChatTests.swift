import Testing
@testable import Oppi

@Suite("Session tree display layout (chat)")
struct SessionTreeDisplayLayoutChatTests {
    @Test("keeps single-child chains flat after the first branch generation")
    func keepsSingleChildChainsFlatAfterBranch() {
        let nodes = [
            node(id: "root", parentId: nil),
            node(id: "a1", parentId: "root"),
            node(id: "a2", parentId: "a1"),
            node(id: "a3", parentId: "a2"),
            node(id: "b1", parentId: "root"),
        ]

        let displayNodes = SessionTreeDisplayLayout.displayNodes(
            visibleNodes: nodes,
            allNodes: nodes
        )

        #expect(displayNodes.map(\.id) == ["root", "a1", "a2", "a3", "b1"])
        #expect(displayNodes.map(\.displayDepth) == [0, 1, 2, 2, 1])
    }

    @Test("reattaches filtered descendants to the nearest visible ancestor without drifting right")
    func reattachesFilteredDescendantsWithoutExtraIndent() {
        let allNodes = [
            node(id: "root", parentId: nil),
            node(id: "hidden-mid", parentId: "root"),
            node(id: "visible-leaf", parentId: "hidden-mid"),
        ]
        let visibleNodes = [allNodes[0], allNodes[2]]

        let displayNodes = SessionTreeDisplayLayout.displayNodes(
            visibleNodes: visibleNodes,
            allNodes: allNodes
        )

        #expect(displayNodes.map(\.id) == ["root", "visible-leaf"])
        #expect(displayNodes.map(\.displayDepth) == [0, 0])
        #expect(displayNodes.last?.visibleParentId == "root")
    }

    private func node(id: String, parentId: String?) -> SessionTreeNodeSnapshot {
        SessionTreeNodeSnapshot(
            id: id,
            parentId: parentId,
            type: "message",
            timestamp: "2026-04-21T12:00:00.000Z",
            depth: 0,
            isLeafPath: true,
            role: "user",
            textPreview: id,
            label: nil
        )
    }
}
