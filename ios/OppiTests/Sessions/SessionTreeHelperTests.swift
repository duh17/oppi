import Foundation
import Testing
@testable import Oppi

@Suite("SessionTreeHelper")
struct SessionTreeHelperTests {

    // MARK: - Test helpers

    private func makeSession(
        id: String,
        parentId: String? = nil,
        status: SessionStatus = .busy,
        name: String? = nil,
        createdAt: Date = Date()
    ) -> Session {
        Session(
            id: id,
            workspaceId: "ws1",
            workspaceName: "Test",
            name: name ?? "Session \(id)",
            status: status,
            createdAt: createdAt,
            lastActivity: Date(),
            model: "test/model",
            messageCount: 5,
            tokens: TokenUsage(input: 100, output: 50),
            cost: 0.10,
            parentSessionId: parentId
        )
    }

    // MARK: - buildTree

    @Test func buildTree_standaloneSessionsAreRoots() {
        let sessions = [
            makeSession(id: "a"),
            makeSession(id: "b"),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        #expect(tree.count == 2)
        #expect(tree[0].children.isEmpty)
        #expect(tree[1].children.isEmpty)
        #expect(tree[0].depth == 0)
    }

    @Test func buildTree_parentChildRelationship() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "child1", parentId: "parent"),
            makeSession(id: "child2", parentId: "parent"),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        #expect(tree.count == 1)
        #expect(tree[0].session.id == "parent")
        #expect(tree[0].children.count == 2)
        #expect(tree[0].children[0].depth == 1)
        #expect(tree[0].children[1].depth == 1)
    }

    @Test func buildTree_grandchildRelationship() {
        let sessions = [
            makeSession(id: "root"),
            makeSession(id: "child", parentId: "root"),
            makeSession(id: "grandchild", parentId: "child"),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        #expect(tree.count == 1)
        #expect(tree[0].children.count == 1)
        #expect(tree[0].children[0].children.count == 1)
        #expect(tree[0].children[0].children[0].session.id == "grandchild")
        #expect(tree[0].children[0].children[0].depth == 2)
    }

    @Test func buildTree_orphanedChildIsRoot() {
        // Parent not in the list → child becomes a root
        let sessions = [
            makeSession(id: "child", parentId: "missing-parent"),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        #expect(tree.count == 1)
        #expect(tree[0].session.id == "child")
        #expect(tree[0].depth == 0)
    }

    @Test func buildTree_mixedStandaloneAndTree() {
        let sessions = [
            makeSession(id: "standalone"),
            makeSession(id: "parent"),
            makeSession(id: "child", parentId: "parent"),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        #expect(tree.count == 2)
        // Standalone has no children
        let standaloneNode = tree.first { $0.session.id == "standalone" }
        #expect(standaloneNode?.children.isEmpty == true)
        // Parent has child
        let parentNode = tree.first { $0.session.id == "parent" }
        #expect(parentNode?.children.count == 1)
    }

    // MARK: - flattenTree

    @Test func flattenTree_expandedParent() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "child1", parentId: "parent"),
            makeSession(id: "child2", parentId: "parent"),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        let rows = SessionTreeHelper.flattenTree(nodes: tree) { _ in true }
        #expect(rows.count == 3)
        #expect(rows[0].session.id == "parent")
        #expect(rows[0].depth == 0)
        #expect(rows[0].hasChildren == true)
        #expect(rows[0].childCount == 2)
        #expect(rows[1].depth == 1)
        #expect(rows[2].depth == 1)
        #expect(rows[2].isLastChild == true)
    }

    @Test func flattenTree_collapsedParent() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "child1", parentId: "parent"),
            makeSession(id: "child2", parentId: "parent"),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        let rows = SessionTreeHelper.flattenTree(nodes: tree) { _ in false }
        #expect(rows.count == 1)
        #expect(rows[0].session.id == "parent")
        #expect(rows[0].childCount == 2)
    }

    @Test func flattenTree_nestedExpansion() {
        let sessions = [
            makeSession(id: "root"),
            makeSession(id: "child", parentId: "root"),
            makeSession(id: "grandchild", parentId: "child"),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        let rows = SessionTreeHelper.flattenTree(nodes: tree) { _ in true }
        #expect(rows.count == 3)
        #expect(rows[0].depth == 0)
        #expect(rows[1].depth == 1)
        #expect(rows[2].depth == 2)
    }

    @Test func flattenTree_partialExpansion() {
        // Expand root but collapse child
        let sessions = [
            makeSession(id: "root"),
            makeSession(id: "child", parentId: "root"),
            makeSession(id: "grandchild", parentId: "child"),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        let rows = SessionTreeHelper.flattenTree(nodes: tree) { id in id == "root" }
        #expect(rows.count == 2)
        #expect(rows[0].session.id == "root")
        #expect(rows[1].session.id == "child")
        #expect(rows[1].hasChildren == true)
        #expect(rows[1].childCount == 1)
    }

    // MARK: - hasActiveChild

    @Test func hasActiveChild_allStopped() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "child1", parentId: "parent", status: .stopped),
            makeSession(id: "child2", parentId: "parent", status: .stopped),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        #expect(SessionTreeHelper.hasActiveChild(tree[0]) == false)
    }

    @Test func hasActiveChild_oneActive() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "child1", parentId: "parent", status: .stopped),
            makeSession(id: "child2", parentId: "parent", status: .busy),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        #expect(SessionTreeHelper.hasActiveChild(tree[0]) == true)
    }

    @Test func hasActiveChild_activeGrandchild() {
        let sessions = [
            makeSession(id: "root"),
            makeSession(id: "child", parentId: "root", status: .stopped),
            makeSession(id: "grandchild", parentId: "child", status: .busy),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        #expect(SessionTreeHelper.hasActiveChild(tree[0]) == true)
    }

    // MARK: - childStatusCounts

    @Test func childStatusCounts_mixed() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "c1", parentId: "parent", status: .busy),
            makeSession(id: "c2", parentId: "parent", status: .stopped),
            makeSession(id: "c3", parentId: "parent", status: .error),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        let counts = SessionTreeHelper.childStatusCounts(tree[0])
        #expect(counts.working == 1)
        #expect(counts.done == 1)
        #expect(counts.error == 1)
        #expect(counts.total == 3)
    }

    @Test func childStatusCounts_includesGrandchildren() {
        let sessions = [
            makeSession(id: "root"),
            makeSession(id: "child", parentId: "root", status: .busy),
            makeSession(id: "grandchild", parentId: "child", status: .error),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        let counts = SessionTreeHelper.childStatusCounts(tree[0])
        #expect(counts.working == 1)
        #expect(counts.error == 1)
        #expect(counts.total == 2)
    }

    @Test func childStatusCounts_readyIsDone() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "c1", parentId: "parent", status: .ready),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        let counts = SessionTreeHelper.childStatusCounts(tree[0])
        #expect(counts.done == 1)
    }

    @Test func childStatusCounts_startingIsWorking() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "c1", parentId: "parent", status: .starting),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        let counts = SessionTreeHelper.childStatusCounts(tree[0])
        #expect(counts.working == 1)
    }

    // MARK: - childSessions

    @Test func childSessions_findsDirectChildren() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "child1", parentId: "parent"),
            makeSession(id: "child2", parentId: "parent"),
            makeSession(id: "other"),
        ]
        let children = SessionTreeHelper.childSessions(of: "parent", in: sessions)
        #expect(children.count == 2)
        #expect(children.allSatisfy { $0.parentSessionId == "parent" })
    }

    @Test func childSessions_excludesGrandchildren() {
        let sessions = [
            makeSession(id: "parent"),
            makeSession(id: "child", parentId: "parent"),
            makeSession(id: "grandchild", parentId: "child"),
        ]
        let children = SessionTreeHelper.childSessions(of: "parent", in: sessions)
        #expect(children.count == 1)
        #expect(children[0].id == "child")
    }

    // MARK: - countAllChildren

    @Test func countAllChildren_recursive() {
        let sessions = [
            makeSession(id: "root"),
            makeSession(id: "child", parentId: "root"),
            makeSession(id: "grandchild", parentId: "child"),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        #expect(SessionTreeHelper.countAllChildren(tree[0]) == 2)
    }

    // MARK: - FlatRow parentLinesContinue

    @Test func flatRow_parentLinesContinue_forGrandchild() {
        // When a grandchild row is visible, parent tree lines should continue through it
        let sessions = [
            makeSession(id: "root"),
            makeSession(id: "child1", parentId: "root"),
            makeSession(id: "grandchild", parentId: "child1"),
            makeSession(id: "child2", parentId: "root"),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        let rows = SessionTreeHelper.flattenTree(nodes: tree) { _ in true }
        // grandchild row should have parent line at depth 0 (root's line continues)
        let grandchildRow = rows.first { $0.session.id == "grandchild" }
        #expect(grandchildRow != nil)
        // child1 is NOT the last child of root, so depth 0 line continues
        #expect(grandchildRow?.parentLinesContinue.contains(0) == true)
    }

    // MARK: - Safety and determinism tests

    @Test func buildTree_selfReferentialParent() {
        // Session with parentId pointing to itself should not crash and should be filtered out
        let sessions = [
            makeSession(id: "self-ref", parentId: "self-ref"),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        // Self-referential session is filtered out because its parent exists in the list (itself)
        #expect(tree.isEmpty)
    }

    @Test func buildTree_circularReferences() {
        // A→B, B→A circular reference should not crash
        let sessions = [
            makeSession(id: "a", parentId: "b"),
            makeSession(id: "b", parentId: "a"),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        // Both sessions are filtered out because their parents exist in the list
        #expect(tree.isEmpty)
    }

    @Test func buildTree_multipleIndependentTrees() {
        // Multiple root sessions each with their own children
        let sessions = [
            makeSession(id: "root1"),
            makeSession(id: "child1a", parentId: "root1"),
            makeSession(id: "child1b", parentId: "root1"),
            makeSession(id: "root2"),
            makeSession(id: "child2a", parentId: "root2"),
            makeSession(id: "root3"),
            makeSession(id: "child3a", parentId: "root3"),
            makeSession(id: "child3b", parentId: "root3"),
            makeSession(id: "child3c", parentId: "root3"),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        #expect(tree.count == 3) // Three independent trees

        let tree1 = tree.first { $0.session.id == "root1" }
        let tree2 = tree.first { $0.session.id == "root2" }
        let tree3 = tree.first { $0.session.id == "root3" }

        #expect(tree1?.children.count == 2)
        #expect(tree2?.children.count == 1)
        #expect(tree3?.children.count == 3)
    }

    @Test func buildTree_childOrderingStability() {
        // Children should be sorted by createdAt in ascending order
        let baseTime = Date()
        let sessions = [
            makeSession(id: "parent", createdAt: baseTime),
            makeSession(id: "child-third", parentId: "parent", createdAt: baseTime.addingTimeInterval(30)),
            makeSession(id: "child-first", parentId: "parent", createdAt: baseTime.addingTimeInterval(10)),
            makeSession(id: "child-second", parentId: "parent", createdAt: baseTime.addingTimeInterval(20)),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        #expect(tree.count == 1)
        #expect(tree[0].children.count == 3)

        // Should be ordered by createdAt: first, second, third
        #expect(tree[0].children[0].session.id == "child-first")
        #expect(tree[0].children[1].session.id == "child-second")
        #expect(tree[0].children[2].session.id == "child-third")
    }

    @Test func buildTree_rootOrderingStability() {
        // Root sessions should be sorted by createdAt in ascending order
        let baseTime = Date()
        let sessions = [
            makeSession(id: "root-third", createdAt: baseTime.addingTimeInterval(30)),
            makeSession(id: "root-first", createdAt: baseTime.addingTimeInterval(10)),
            makeSession(id: "root-second", createdAt: baseTime.addingTimeInterval(20)),
        ]
        let tree = SessionTreeHelper.buildTree(from: sessions)
        #expect(tree.count == 3)

        // Should be ordered by createdAt: first, second, third
        #expect(tree[0].session.id == "root-first")
        #expect(tree[1].session.id == "root-second")
        #expect(tree[2].session.id == "root-third")
    }

    @Test func buildTree_emptySessions() {
        // Empty sessions array should return empty tree
        let sessions: [Session] = []
        let tree = SessionTreeHelper.buildTree(from: sessions)
        #expect(tree.isEmpty)
    }
}
