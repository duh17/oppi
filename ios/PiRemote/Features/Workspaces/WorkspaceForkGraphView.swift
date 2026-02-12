import SwiftUI

/// Workspace-level fork/lineage explorer.
///
/// Renders:
/// - session lineage tree (`sessionGraph`)
/// - branch entry list for selected pi session (`entryGraph`)
struct WorkspaceForkGraphView: View {
    let workspace: Workspace
    var focusSessionId: String?

    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var sessionStore

    @State private var graph: WorkspaceGraphResponse?
    @State private var selectedNodeId: String?
    @State private var isLoading = false
    @State private var error: String?

    private struct SessionTreeNode: Identifiable {
        let node: WorkspaceGraphResponse.SessionGraph.Node
        var children: [SessionTreeNode]
        var id: String { node.id }
        var childNodes: [SessionTreeNode]? { children.isEmpty ? nil : children }
    }

    private var sessionNamesById: [String: String] {
        let sessions = sessionStore.sessions.filter { $0.workspaceId == workspace.id }
        var result: [String: String] = [:]
        for session in sessions {
            let title = session.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let title, !title.isEmpty {
                result[session.id] = title
            } else {
                result[session.id] = "Session \(String(session.id.prefix(8)))"
            }
        }
        return result
    }

    private var treeRoots: [SessionTreeNode] {
        guard let graph else { return [] }
        let nodesById = Dictionary(uniqueKeysWithValues: graph.sessionGraph.nodes.map { ($0.id, $0) })

        let childrenByParent = Dictionary(grouping: graph.sessionGraph.nodes) { node in
            node.parentId ?? ""
        }

        let rootIDs: [String] = if graph.sessionGraph.roots.isEmpty {
            graph.sessionGraph.nodes
                .filter { $0.parentId == nil || nodesById[$0.parentId ?? ""] == nil }
                .map(\.id)
        } else {
            graph.sessionGraph.roots
        }

        return rootIDs.compactMap { id in
            buildTreeNode(
                id: id,
                nodesById: nodesById,
                childrenByParent: childrenByParent
            )
        }
    }

    var body: some View {
        List {
            if let graph {
                overviewSection(graph)
                lineageSection(graph)
                entrySection(graph)
            } else if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Loading fork graph…")
                        Spacer()
                    }
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "No Fork Graph",
                        systemImage: "arrow.triangle.branch",
                        description: Text("No session lineage found for this workspace yet.")
                    )
                }
            }
        }
        .navigationTitle("Fork Graph")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refreshGraph() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isLoading)
            }
        }
        .refreshable {
            await refreshGraph()
        }
        .task {
            await refreshGraph()
        }
        .alert("Fork Graph Error", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "Unknown error")
        }
    }

    @ViewBuilder
    private func overviewSection(_ graph: WorkspaceGraphResponse) -> some View {
        Section("Overview") {
            VStack(alignment: .leading, spacing: 8) {
                Text(workspace.name)
                    .font(.headline)

                HStack(spacing: 8) {
                    Text("\(graph.sessionGraph.nodes.count) branches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text("Updated \(graph.generatedAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let current = graph.current {
                    HStack(spacing: 8) {
                        Label("Current", systemImage: "location.fill")
                            .font(.caption)
                            .foregroundStyle(.tokyoBlue)
                        Text(shortID(current.nodeId ?? current.sessionId))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func lineageSection(_ graph: WorkspaceGraphResponse) -> some View {
        Section("Session Lineage") {
            if treeRoots.isEmpty {
                Text("No lineage data available yet.")
                    .foregroundStyle(.secondary)
            } else {
                OutlineGroup(treeRoots, children: \.childNodes) { item in
                    Button {
                        selectBranch(item.node.id)
                    } label: {
                        SessionLineageRow(
                            node: item.node,
                            isCurrent: graph.current?.nodeId == item.node.id,
                            isSelected: selectedNodeId == item.node.id,
                            sessionNamesById: sessionNamesById
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func entrySection(_ graph: WorkspaceGraphResponse) -> some View {
        Section("Branch Entries") {
            if let entryGraph = graph.entryGraph {
                branchHeader(entryGraph)

                ForEach(orderedEntryNodes(entryGraph)) { node in
                    EntryRow(
                        node: node,
                        isRoot: node.id == entryGraph.rootEntryId,
                        isLeaf: node.id == entryGraph.leafEntryId
                    )
                }
            } else {
                Text("Select a branch to inspect message ancestry.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func branchHeader(_ entryGraph: WorkspaceGraphResponse.EntryGraph) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label("Branch", systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.tokyoPurple)
                Text(shortID(entryGraph.piSessionId))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Text("\(entryGraph.nodes.count) entries")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func orderedEntryNodes(_ graph: WorkspaceGraphResponse.EntryGraph) -> [WorkspaceGraphResponse.EntryGraph.Node] {
        graph.nodes.sorted { lhs, rhs in
            switch (lhs.timestamp, rhs.timestamp) {
            case let (l?, r?) where l != r:
                return l < r
            case (nil, _?):
                return true
            case (_?, nil):
                return false
            default:
                return lhs.id < rhs.id
            }
        }
    }

    private func selectBranch(_ nodeId: String) {
        guard selectedNodeId != nodeId else { return }
        selectedNodeId = nodeId
        Task {
            await refreshGraph()
        }
    }

    private func refreshGraph() async {
        guard let api = connection.apiClient else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            var response = try await api.getWorkspaceGraph(
                workspaceId: workspace.id,
                sessionId: focusSessionId,
                includeEntryGraph: true,
                entrySessionId: selectedNodeId
            )

            // First load fallback: if no selected/current branch could be projected,
            // anchor to first known branch and fetch again with explicit entrySessionId.
            if response.entryGraph == nil {
                let fallbackNodeId = selectedNodeId
                    ?? response.current?.nodeId
                    ?? response.sessionGraph.nodes.first?.id

                if let fallbackNodeId, fallbackNodeId != selectedNodeId {
                    selectedNodeId = fallbackNodeId
                    response = try await api.getWorkspaceGraph(
                        workspaceId: workspace.id,
                        sessionId: focusSessionId,
                        includeEntryGraph: true,
                        entrySessionId: fallbackNodeId
                    )
                }
            }

            if selectedNodeId == nil {
                selectedNodeId = response.entryGraph?.piSessionId
                    ?? response.current?.nodeId
                    ?? response.sessionGraph.nodes.first?.id
            }

            graph = response
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func buildTreeNode(
        id: String,
        nodesById: [String: WorkspaceGraphResponse.SessionGraph.Node],
        childrenByParent: [String: [WorkspaceGraphResponse.SessionGraph.Node]]
    ) -> SessionTreeNode? {
        guard let node = nodesById[id] else { return nil }

        let sortedChildren = (childrenByParent[id] ?? []).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }

        let childNodes = sortedChildren.compactMap { child in
            buildTreeNode(
                id: child.id,
                nodesById: nodesById,
                childrenByParent: childrenByParent
            )
        }

        return SessionTreeNode(node: node, children: childNodes)
    }

    private func shortID(_ value: String) -> String {
        String(value.prefix(8))
    }
}

private struct SessionLineageRow: View {
    let node: WorkspaceGraphResponse.SessionGraph.Node
    let isCurrent: Bool
    let isSelected: Bool
    let sessionNamesById: [String: String]

    private var attachedLabel: String {
        let names = node.attachedSessionIds.compactMap { sessionNamesById[$0] }
        if names.isEmpty {
            return "Detached"
        }
        if names.count == 1 {
            return names[0]
        }
        return "\(names[0]) +\(names.count - 1)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isCurrent ? Color.tokyoBlue : Color.tokyoComment.opacity(0.4))
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(String(node.id.prefix(8)))
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.primary)

                    if isCurrent {
                        Text("Current")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.tokyoBlue.opacity(0.2), in: Capsule())
                            .foregroundStyle(.tokyoBlue)
                    }

                    if !node.activeSessionIds.isEmpty {
                        Text("Active")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.tokyoGreen.opacity(0.2), in: Capsule())
                            .foregroundStyle(.tokyoGreen)
                    }
                }

                HStack(spacing: 6) {
                    Text(attachedLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Text(node.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.tokyoBlue)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct EntryRow: View {
    let node: WorkspaceGraphResponse.EntryGraph.Node
    let isRoot: Bool
    let isLeaf: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(iconColor)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(node.preview ?? node.type)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if isRoot {
                        Text("root")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.tokyoPurple.opacity(0.2), in: Capsule())
                            .foregroundStyle(.tokyoPurple)
                    }

                    if isLeaf {
                        Text("leaf")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.tokyoBlue.opacity(0.2), in: Capsule())
                            .foregroundStyle(.tokyoBlue)
                    }
                }

                HStack(spacing: 6) {
                    Text(String(node.id.prefix(8)))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)

                    if let role = node.role, !role.isEmpty {
                        Text(role)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let timestamp = node.timestamp {
                        Text(timestamp, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch node.type {
        case "message":
            if node.role == "user" { return "person.fill" }
            if node.role == "assistant" { return "cpu" }
            return "message"
        case "model_change":
            return "slider.horizontal.3"
        default:
            return "circle.fill"
        }
    }

    private var iconColor: Color {
        switch node.type {
        case "message":
            if node.role == "user" { return .tokyoBlue }
            if node.role == "assistant" { return .tokyoPurple }
            return .tokyoComment
        case "model_change":
            return .tokyoOrange
        default:
            return .tokyoComment
        }
    }
}
