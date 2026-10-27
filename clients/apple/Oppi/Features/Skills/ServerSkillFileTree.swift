import Foundation

struct ServerSkillFileTreeNode: Identifiable, Hashable {
    enum Kind: Hashable {
        case directory
        case file
    }

    let name: String
    let path: String
    let kind: Kind
    let children: [Self]

    var id: String { "\(kind == .directory ? "directory" : "file"):\(path)" }
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
