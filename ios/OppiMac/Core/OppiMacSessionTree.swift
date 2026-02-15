import Foundation

struct OppiMacSessionTreeNode: Identifiable, Equatable, Sendable {
    let session: Session
    let children: [OppiMacSessionTreeNode]

    var id: String { session.id }
}

enum OppiMacSessionTreeBuilder {
    static func build(
        sessions: [Session],
        graph: WorkspaceGraphResponse.SessionGraph?
    ) -> [OppiMacSessionTreeNode] {
        guard !sessions.isEmpty else { return [] }

        guard let graph, !graph.nodes.isEmpty else {
            return sessions
                .sorted(by: sessionSort)
                .map { OppiMacSessionTreeNode(session: $0, children: []) }
        }

        let sortedNodes = graph.nodes.sorted(by: nodeSort)

        var activeNodeBySessionID: [String: String] = [:]
        var attachedNodeBySessionID: [String: String] = [:]

        for node in sortedNodes {
            for sessionID in node.attachedSessionIds where attachedNodeBySessionID[sessionID] == nil {
                attachedNodeBySessionID[sessionID] = node.id
            }

            for sessionID in node.activeSessionIds where activeNodeBySessionID[sessionID] == nil {
                activeNodeBySessionID[sessionID] = node.id
            }
        }

        var nodeIDBySessionID: [String: String] = [:]
        var sessionsByNodeID: [String: [Session]] = [:]

        for session in sessions {
            if let nodeID = activeNodeBySessionID[session.id] ?? attachedNodeBySessionID[session.id] {
                nodeIDBySessionID[session.id] = nodeID
                sessionsByNodeID[nodeID, default: []].append(session)
            }
        }

        var representativeSessionByNodeID: [String: String] = [:]
        for (nodeID, nodeSessions) in sessionsByNodeID {
            let sorted = nodeSessions.sorted(by: sessionSort)
            representativeSessionByNodeID[nodeID] = sorted.first?.id
        }

        let nodeByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        var childSessionIDsByParentSessionID: [String: [String]] = [:]
        var rootSessionIDs: [String] = []

        for session in sessions {
            let parentSessionID: String?
            if let nodeID = nodeIDBySessionID[session.id],
               let parentNodeID = nodeByID[nodeID]?.parentId,
               let representativeParent = representativeSessionByNodeID[parentNodeID],
               representativeParent != session.id {
                parentSessionID = representativeParent
            } else {
                parentSessionID = nil
            }

            if let parentSessionID,
               sessionsByID[parentSessionID] != nil {
                childSessionIDsByParentSessionID[parentSessionID, default: []].append(session.id)
            } else {
                rootSessionIDs.append(session.id)
            }
        }

        rootSessionIDs = dedupSortedSessionIDs(rootSessionIDs, sessionsByID: sessionsByID)
        for (parentSessionID, childIDs) in childSessionIDsByParentSessionID {
            childSessionIDsByParentSessionID[parentSessionID] = dedupSortedSessionIDs(
                childIDs,
                sessionsByID: sessionsByID
            )
        }

        var visited = Set<String>()

        func buildNode(sessionID: String) -> OppiMacSessionTreeNode? {
            guard let session = sessionsByID[sessionID] else { return nil }

            if visited.contains(sessionID) {
                return OppiMacSessionTreeNode(session: session, children: [])
            }

            visited.insert(sessionID)

            let children = (childSessionIDsByParentSessionID[sessionID] ?? [])
                .compactMap(buildNode(sessionID:))

            return OppiMacSessionTreeNode(session: session, children: children)
        }

        var roots: [OppiMacSessionTreeNode] = rootSessionIDs.compactMap(buildNode(sessionID:))

        var includedSessionIDs = Set<String>()
        for root in roots {
            collectSessionIDs(root, into: &includedSessionIDs)
        }

        if includedSessionIDs.count != sessions.count {
            for session in sessions.sorted(by: sessionSort) {
                if includedSessionIDs.contains(session.id) {
                    continue
                }

                if let supplemental = buildNode(sessionID: session.id) {
                    roots.append(supplemental)
                    collectSessionIDs(supplemental, into: &includedSessionIDs)
                }
            }
        }

        return roots
    }

    private static func nodeSort(
        lhs: WorkspaceGraphResponse.SessionGraph.Node,
        rhs: WorkspaceGraphResponse.SessionGraph.Node
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id < rhs.id
    }

    private static func sessionSort(lhs: Session, rhs: Session) -> Bool {
        let lhsError = lhs.status == .error
        let rhsError = rhs.status == .error
        if lhsError != rhsError {
            return lhsError
        }

        let lhsActive = lhs.status != .stopped
        let rhsActive = rhs.status != .stopped
        if lhsActive != rhsActive {
            return lhsActive
        }

        if lhs.lastActivity != rhs.lastActivity {
            return lhs.lastActivity > rhs.lastActivity
        }

        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }

        return lhs.id < rhs.id
    }

    private static func dedupSortedSessionIDs(
        _ sessionIDs: [String],
        sessionsByID: [String: Session]
    ) -> [String] {
        let unique = Set(sessionIDs)
        return unique.sorted { lhs, rhs in
            guard let lhsSession = sessionsByID[lhs],
                  let rhsSession = sessionsByID[rhs] else {
                return lhs < rhs
            }
            return sessionSort(lhs: lhsSession, rhs: rhsSession)
        }
    }

    private static func collectSessionIDs(_ node: OppiMacSessionTreeNode, into output: inout Set<String>) {
        output.insert(node.session.id)
        for child in node.children {
            collectSessionIDs(child, into: &output)
        }
    }
}
