import Foundation

/// Builds a parent-child tree from a flat list of sessions using `parentSessionId`.
///
/// Sessions without a `parentSessionId` are root nodes. Children are grouped under
/// their parent. Grandchildren nest under their child-parent. The tree depth
/// in practice is limited to 2 by the spawn_agent server implementation.
enum SessionTreeHelper {

    /// A node in the session tree.
    struct TreeNode: Identifiable {
        let session: Session
        let depth: Int
        let children: [Self]
        /// Whether this node is the last child of its parent at this depth.
        let isLastChild: Bool

        var id: String { session.id }
        var hasChildren: Bool { !children.isEmpty }
    }

    /// Flatten a tree into display rows with depth information.
    struct FlatRow: Identifiable {
        let session: Session
        let depth: Int
        let hasChildren: Bool
        let childCount: Int
        /// Whether this row is the last sibling at its depth level.
        let isLastChild: Bool
        /// Whether the parent-level tree line should continue through this row (for grandchildren).
        let parentLinesContinue: [Int]

        var id: String { session.id }
    }

    /// Build tree nodes from a flat session list.
    /// Only root sessions (no parentSessionId, or parent not in the list) appear as top-level nodes.
    static func buildTree(from sessions: [Session]) -> [TreeNode] {
        let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let childrenByParent = Dictionary(grouping: sessions.filter { $0.parentSessionId != nil }) {
            $0.parentSessionId ?? ""
        }

        // A session is a root if it has no parent, or its parent isn't in this list
        let roots = sessions.filter { session in
            guard let parentId = session.parentSessionId else { return true }
            return byId[parentId] == nil
        }.sorted { $0.createdAt < $1.createdAt }

        func buildNode(session: Session, depth: Int, isLast: Bool, visited: inout Set<String>) -> TreeNode {
            // Guard against circular references and self-referential parentSessionId
            guard !visited.contains(session.id) else {
                // If we've already visited this session, return a node with no children to break the cycle
                return TreeNode(session: session, depth: depth, children: [], isLastChild: isLast)
            }

            visited.insert(session.id)
            defer { visited.remove(session.id) }
            let kids = (childrenByParent[session.id] ?? []).sorted { $0.createdAt < $1.createdAt }
            let childNodes = kids.enumerated().map { index, child in
                buildNode(session: child, depth: depth + 1, isLast: index == kids.count - 1, visited: &visited)
            }
            return TreeNode(session: session, depth: depth, children: childNodes, isLastChild: isLast)
        }

        return roots.enumerated().map { index, session in
            var visited = Set<String>()
            return buildNode(session: session, depth: 0, isLast: index == roots.count - 1, visited: &visited)
        }
    }

    /// Flatten tree nodes into display rows, respecting expansion state.
    /// `isExpanded` closure determines whether a parent node's children should be shown.
    ///
    /// `continuingLines` tracks which depth levels have a vertical tree line continuing
    /// through the current row. A line at depth D continues when the ancestor at depth D
    /// has more children below the current branch.
    static func flattenTree(
        nodes: [TreeNode],
        isExpanded: (String) -> Bool
    ) -> [FlatRow] {
        var result: [FlatRow] = []

        func visit(node: TreeNode, continuingLines: Set<Int>) {
            let row = FlatRow(
                session: node.session,
                depth: node.depth,
                hasChildren: node.hasChildren,
                childCount: countAllChildren(node),
                isLastChild: node.isLastChild,
                parentLinesContinue: continuingLines.sorted()
            )
            result.append(row)

            if node.hasChildren, isExpanded(node.session.id) {
                for (index, child) in node.children.enumerated() {
                    let isLast = index == node.children.count - 1
                    // Build the set of continuing lines for child rows.
                    // The child inherits all parent continuing lines, plus
                    // we add this node's depth if the child is NOT the last sibling
                    // (meaning the vertical connector at this depth keeps going).
                    var childLines = continuingLines
                    if !isLast {
                        childLines.insert(node.depth)
                    } else {
                        // Last child — the vertical line at this depth stops here
                        childLines.remove(node.depth)
                    }
                    let childNode = TreeNode(
                        session: child.session,
                        depth: child.depth,
                        children: child.children,
                        isLastChild: isLast
                    )
                    visit(node: childNode, continuingLines: childLines)
                }
            }
        }

        for node in nodes {
            visit(node: node, continuingLines: [])
        }
        return result
    }

    /// Count all descendants (children + grandchildren) of a node.
    static func countAllChildren(_ node: TreeNode) -> Int {
        node.children.reduce(0) { $0 + 1 + countAllChildren($1) }
    }

    /// Determine default expansion: expanded if any child (recursive) is not stopped.
    static func hasActiveChild(_ node: TreeNode) -> Bool {
        for child in node.children {
            if child.session.status != .stopped { return true }
            if hasActiveChild(child) { return true }
        }
        return false
    }

    /// Aggregate child status counts for a collapsed badge.
    struct StatusCounts: Equatable {
        var working: Int = 0
        var done: Int = 0
        var error: Int = 0
        var total: Int = 0
    }

    /// Count child statuses recursively.
    static func childStatusCounts(_ node: TreeNode) -> StatusCounts {
        var counts = StatusCounts()
        func visit(_ n: TreeNode) {
            for child in n.children {
                counts.total += 1
                switch child.session.status {
                case .starting, .busy, .stopping:
                    counts.working += 1
                case .ready, .stopped:
                    counts.done += 1
                case .error:
                    counts.error += 1
                }
                visit(child)
            }
        }
        visit(node)
        return counts
    }

    // periphery:ignore - used by SessionTreeHelperTests via @testable import
    /// Get all immediate child session IDs for a given parent session.
    static func childSessions(of parentId: String, in sessions: [Session]) -> [Session] {
        sessions.filter { $0.parentSessionId == parentId }
    }
}
