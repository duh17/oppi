import SwiftUI

struct ServerSkillFileTreeNode: Identifiable, Hashable {
    enum Kind: Hashable {
        case directory
        case file
    }

    let name: String
    let path: String
    let kind: Kind
    let children: [ServerSkillFileTreeNode]

    var id: String { "\(kind == .directory ? "directory" : "file"):\(path)" }
    var outlineChildren: [ServerSkillFileTreeNode]? { children.isEmpty ? nil : children }
}

enum ServerSkillFileTree {
    static func build(paths: [String]) -> [ServerSkillFileTreeNode] {
        let root = MutableNode(name: "", path: "", kind: .directory)

        for path in Set(paths) {
            guard !path.hasPrefix("/"), !path.contains("\\") else { continue }
            let components = path
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard !components.isEmpty,
                  components.allSatisfy({ $0 != "." && $0 != ".." }) else { continue }

            var parent = root
            for (index, component) in components.enumerated() {
                let childPath = components.prefix(index + 1).joined(separator: "/")
                let kind: ServerSkillFileTreeNode.Kind = index == components.count - 1
                    ? .file
                    : .directory
                let child = parent.children[component] ?? MutableNode(
                    name: component,
                    path: childPath,
                    kind: kind
                )
                parent.children[component] = child
                parent = child
            }
        }

        return root.frozenChildren()
    }

    private final class MutableNode {
        let name: String
        let path: String
        let kind: ServerSkillFileTreeNode.Kind
        var children: [String: MutableNode] = [:]

        init(name: String, path: String, kind: ServerSkillFileTreeNode.Kind) {
            self.name = name
            self.path = path
            self.kind = kind
        }

        func frozenChildren() -> [ServerSkillFileTreeNode] {
            children.values
                .sorted {
                    if $0.kind != $1.kind { return $0.kind == .directory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                .map { child in
                    ServerSkillFileTreeNode(
                        name: child.name,
                        path: child.path,
                        kind: child.kind,
                        children: child.frozenChildren()
                    )
                }
        }
    }
}

struct ServerSkillBrowserScopedDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    let target: ServerSkillBrowserNavTarget

    @State private var scopedConnection: ServerConnection?

    var body: some View {
        Group {
            if let scopedConnection {
                ServerSkillBrowserView(target: target)
                    .withServerScopedEnvironment(scopedConnection)
            } else {
                ProgressView("Connecting…")
            }
        }
        .task(id: target.serverId) {
            guard await coordinator.switchToServerReady(target.serverId) else { return }
            scopedConnection = coordinator.connection(for: target.serverId)
        }
    }
}

struct ServerSkillBrowserView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.theme) private var theme

    let target: ServerSkillBrowserNavTarget

    @State private var detail: ServerSkillDetail?
    @State private var isLoading = true
    @State private var error: String?

    private var tree: [ServerSkillFileTreeNode] {
        ServerSkillFileTree.build(paths: detail?.files ?? [])
    }

    var body: some View {
        Group {
            if let detail {
                if tree.isEmpty {
                    ContentUnavailableView(
                        "No Skill Files",
                        systemImage: "folder",
                        description: Text("This skill did not expose any browsable files.")
                    )
                } else {
                    List {
                        Section {
                            OutlineGroup(tree, children: \.outlineChildren) { node in
                                fileTreeRow(node)
                            }
                        } footer: {
                            Text("Files are read-only and come from \(detail.summary.provenance.label).")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .themedListSurface()
                }
            } else if isLoading {
                ProgressView("Loading skill files…")
            } else {
                ContentUnavailableView {
                    Label("Files Unavailable", systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(error ?? "The skill files could not be loaded.")
                } actions: {
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .background(theme.bg.primary)
        .navigationTitle(detail?.summary.name ?? "Skill Files")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: target) { await load() }
    }

    @ViewBuilder
    private func fileTreeRow(_ node: ServerSkillFileTreeNode) -> some View {
        switch node.kind {
        case .directory:
            Label(node.name, systemImage: "folder")
                .foregroundStyle(.themeFg)
                .frame(minHeight: 44)
        case .file:
            Button {
                navigation.openServerSkillFile(ServerSkillFileNavTarget(
                    serverId: target.serverId,
                    resourceId: target.resourceId,
                    path: node.path
                ))
            } label: {
                Label(node.name, systemImage: fileIcon(for: node.path))
                    .foregroundStyle(.themeFg)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(node.path)")
            .accessibilityIdentifier("skills.file.\(node.path)")
        }
    }

    private func load() async {
        guard let apiClient else {
            error = "Not connected"
            isLoading = false
            return
        }

        if detail == nil { isLoading = true }
        error = nil
        do {
            let response = try await apiClient.getServerSkill(id: target.resourceId)
            guard !Task.isCancelled else { return }
            detail = response
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func fileIcon(for path: String) -> String {
        if path.hasSuffix(".md") { return "doc.text" }
        if path.hasSuffix(".json") || path.hasSuffix(".yml") || path.hasSuffix(".yaml") {
            return "curlybraces"
        }
        if path.hasSuffix(".sh") { return "terminal" }
        if path.hasSuffix(".swift") || path.hasSuffix(".ts") || path.hasSuffix(".js") || path.hasSuffix(".py") {
            return "chevron.left.forwardslash.chevron.right"
        }
        return "doc"
    }
}
