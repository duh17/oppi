import Foundation

/// A chat leaf's reading position when its window last settled: the item at
/// the top of the timeline and its offset from the viewport's top, or the
/// live tail (no item).
struct PaneChatScroll: Hashable, Sendable, Codable {
    var sessionId: String
    var itemId: String?
    var relativeY: Double
}

/// What a window saves of its panes so a relaunch shows them again: the tree
/// with its weights, focus, recency, zoom and collapse, each stack entry as
/// its server and link, and the chat leaves' reading positions. Screens with
/// no link (`.local`, a web page no link may name) are not saved, and a leaf
/// left with no restorable entry is dropped with the leaves attached to it.
///
/// The JSON is versioned (`schemaVersion`); a different version, a link that
/// no longer decodes as a pane link, or a tree that breaks an invariant
/// decodes to nil, and the window starts fresh.
struct PaneLayoutArchive: Hashable, Sendable {
    static let schemaVersion = 1

    let layout: PaneLayout
    /// Reading positions by chat leaf.
    let chatScroll: [PaneID: PaneChatScroll]
    /// The share of the window an attached companion last settled at, by its
    /// pairing's key (a chat and a reader, the File Browser and its file),
    /// kept whether or not one is open, so the next of that pairing opens at it.
    let companionShares: [String: Double]

    /// `layout` without what cannot be restored; nil when nothing is left.
    init?(
        restorable layout: PaneLayout,
        chatScroll: [PaneID: PaneChatScroll] = [:],
        companionShares: [String: Double] = [:]
    ) {
        guard let restorable = Self.restorable(layout) else { return nil }
        self.layout = restorable
        let ids = Set(restorable.leaves.map(\.id))
        self.chatScroll = chatScroll.filter { ids.contains($0.key) }
        self.companionShares = companionShares.filter { $0.value > 0 && $0.value < 1 }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Stored(self))
    }

    static func decode(_ data: Data) -> Self? {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.v == schemaVersion,
              let layout = stored.layout() else { return nil }
        return Self(restorable: layout, chatScroll: stored.chatScrollByLeaf, companionShares: stored.companionShares ?? [:])
    }

    /// Drops entries with no link, then each leaf with nothing left, closing
    /// the leaves attached to it as Close Pane would.
    private static func restorable(_ layout: PaneLayout) -> PaneLayout? {
        func isLocal(_ entry: PaneStackEntry) -> Bool {
            switch entry.route {
            case .local: true
            case .unsupported: false
            default: PaneLinkCodec.encode(PaneLink(server: nil, route: entry.route)) == nil
            }
        }
        guard var layout = try? layout.normalised() else { return nil }
        // Closed while their stacks are whole, so `close` sees a valid tree.
        for leaf in layout.leaves where leaf.stack.allSatisfy(isLocal) {
            guard layout.leaf(leaf.id) != nil else { continue }
            guard let closed = try? layout.close(leaf.id) else { return nil }
            layout = closed
        }
        layout.root = layout.root.mapLeaves { leaf in
            var leaf = leaf
            leaf.stack.removeAll(where: isLocal)
            return leaf
        }
        return try? layout.normalised()
    }
}

// MARK: - Stored form

private extension PaneLayoutArchive {
    struct Stored: Codable {
        let v: Int
        let root: Node
        let focus: String
        let recency: [String]
        let zoomed: String?
        let collapsed: [String: Double]
        let chatScroll: [String: PaneChatScroll]
        let companionShares: [String: Double]?

        init(_ archive: PaneLayoutArchive) {
            v = PaneLayoutArchive.schemaVersion
            root = Node(archive.layout.root)
            focus = archive.layout.focus.raw
            recency = archive.layout.recency.map(\.raw)
            zoomed = archive.layout.zoomed?.raw
            collapsed = Dictionary(uniqueKeysWithValues: archive.layout.collapsed.map { ($0.key.raw, $0.value) })
            chatScroll = Dictionary(uniqueKeysWithValues: archive.chatScroll.map { ($0.key.raw, $0.value) })
            companionShares = archive.companionShares
        }

        var chatScrollByLeaf: [PaneID: PaneChatScroll] {
            Dictionary(uniqueKeysWithValues: chatScroll.compactMap { key, value in PaneID(key).map { ($0, value) } })
        }

        func layout() -> PaneLayout? {
            guard let root = root.node(), let focus = PaneID(focus) else { return nil }
            return PaneLayout(
                root: root,
                focus: focus,
                recency: recency.compactMap(PaneID.init),
                zoomed: zoomed.flatMap(PaneID.init),
                collapsed: Dictionary(uniqueKeysWithValues: collapsed.compactMap { key, value in
                    PaneID(key).map { ($0, value) }
                })
            )
        }
    }

    /// A leaf, or a split of nodes.
    struct Node: Codable {
        var leaf: Leaf?
        var axis: String?
        var children: [Self]?
        var weights: [Double]?

        init(_ node: PaneNode) {
            switch node {
            case .leaf(let leaf):
                self.leaf = Leaf(leaf)
            case .split(let axis, let children, let weights):
                self.axis = axis == .row ? "row" : "column"
                self.children = children.map(Self.init)
                self.weights = weights
            }
        }

        func node() -> PaneNode? {
            if let leaf { return leaf.leaf().map(PaneNode.leaf) }
            guard let axis, let children, let weights, axis == "row" || axis == "column" else { return nil }
            let nodes = children.compactMap { $0.node() }
            guard nodes.count == children.count else { return nil }
            return .split(axis: axis == "row" ? .row : .column, children: nodes, weights: weights)
        }
    }

    struct Leaf: Codable {
        let id: String
        let name: String?
        let origin: String
        let attachedTo: String?
        let stack: [Entry]

        init(_ leaf: PaneLeaf) {
            id = leaf.id.raw
            name = leaf.name
            origin = switch leaf.origin {
            case .attached: "attached"
            case .split: "split"
            case .layout: "layout"
            }
            attachedTo = leaf.attachedTo?.raw
            stack = leaf.stack.compactMap(Entry.init)
        }

        func leaf() -> PaneLeaf? {
            guard let id = PaneID(id) else { return nil }
            let origin: PaneOrigin
            switch self.origin {
            case "attached": origin = .attached
            case "split": origin = .split
            case "layout": origin = .layout
            default: return nil
            }
            // An entry whose link this build no longer reads goes as a
            // `.local` one does; `restorable` drops it, and a leaf left empty.
            return PaneLeaf(
                id: id,
                name: name,
                stack: stack.map { $0.entry() ?? PaneStackEntry(serverId: $0.server, route: .local(PaneLocalToken(raw: "unreadable"))) },
                attachedTo: attachedTo.flatMap(PaneID.init),
                origin: origin
            )
        }
    }

    /// `server` and either the route's link or an unsupported leaf's kind
    /// and raw object.
    struct Entry: Codable {
        let server: String
        var link: String?
        var unsupported: String?
        var raw: [String: JSONValue]?

        init?(_ entry: PaneStackEntry) {
            server = entry.serverId
            switch entry.route {
            case .local:
                return nil
            case .unsupported(let kind, let raw):
                unsupported = kind
                self.raw = raw
            default:
                guard let url = PaneLinkCodec.encode(PaneLink(server: nil, route: entry.route)) else { return nil }
                link = url.absoluteString
            }
        }

        func entry() -> PaneStackEntry? {
            if let unsupported {
                return PaneStackEntry(serverId: server, route: .unsupported(kind: unsupported, raw: raw ?? [:]))
            }
            guard let link, let url = URL(string: link),
                  case .success(let decoded)? = PaneLinkCodec.decode(url) else { return nil }
            return PaneStackEntry(serverId: server, route: decoded.route)
        }
    }
}
