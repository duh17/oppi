import Foundation

// The pane tree as values: what a window shows, independent of UIKit. Today
// it is what restoration saves; Stage 3's host draws it through
// `PanePresentation.resolve`. Links, restoration and layout files name leaf
// content through `PaneRoute`.

/// A leaf's id within one tree: `[a-z0-9-]{1,24}`, so it can appear in a
/// layout file and an accessibility identifier unchanged.
struct PaneID: Hashable, Sendable, CustomStringConvertible {
    let raw: String

    init?(_ raw: String) {
        guard (1...24).contains(raw.utf8.count),
              raw.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D })
        else { return nil }
        self.raw = raw
    }

    var description: String { raw }
}

/// `row` lays children out left to right, `column` top to bottom. Pane order
/// never mirrors in right-to-left languages; content inside a leaf does.
enum PaneAxis: Hashable, Sendable {
    case row, column
}

/// Where a file leaf reads from. A file a session touched encodes as the
/// origin it actually reads from (host or session copy).
enum PaneFileOrigin: Hashable, Sendable {
    case workspace(id: String, worktree: String?)
    case host
    case session(String)
}

/// A screen with no link (Outline, Context, Share, settings pages). The app
/// hands these out and maps them back to its own routes; they are never saved.
struct PaneLocalToken: Hashable, Sendable {
    let raw: String
}

/// What a leaf shows. Every case but `.local` and `.unsupported` has a link
/// (`PaneLinkCodec`).
enum PaneRoute: Hashable, Sendable {
    case sessions(workspace: String?)
    case session(String)
    case thread(String)
    case file(PaneFileOrigin, path: String, line: Int?)
    case files(workspace: String, path: String?)
    /// The server's home folder in the File Browser, at a folder written
    /// `~/…`; nil is the home folder itself.
    case hostFiles(path: String?)
    case git(workspace: String, worktree: String?)
    case commit(workspace: String, sha: String)
    case panel(session: String, id: String)
    /// A web page (http or https). A link or a layout names one by the
    /// `PaneWebAddress` rules; a page the person opened directly may be any
    /// http or https page, and one with no link is not restored.
    case browser(URL)
    /// A Godot game the server discovered, by its project id (Godot pane).
    case godot(project: String)
    case local(PaneLocalToken)
    /// A leaf kind from a newer layout file: kept and restored, never written.
    case unsupported(kind: String, raw: [String: JSONValue])
}

/// One screen in a leaf's stack. `serverId` is the server's identity
/// fingerprint (`PairedServer.id`) for every kind of server, so a tree, a
/// link and Handoff name a server the same way on every device.
struct PaneStackEntry: Hashable, Sendable {
    var serverId: String
    var route: PaneRoute
}

/// How a leaf came to be; decides its compact-width presentation.
enum PaneOrigin: Hashable, Sendable {
    /// Opened from a chat's Files, Git, Outline, Context or Share button:
    /// a sheet on compact width, and closes with its chat.
    case attached
    /// Made by Split or Open in New Pane.
    case split
    /// Opened from a layout.
    case layout
}

struct PaneLeaf: Hashable, Sendable {
    let id: PaneID
    var name: String?
    /// Bottom to top; never empty.
    var stack: [PaneStackEntry]
    /// The chat leaf this leaf closes with.
    var attachedTo: PaneID?
    var origin: PaneOrigin
}

indirect enum PaneNode: Hashable, Sendable {
    case leaf(PaneLeaf)
    case split(axis: PaneAxis, children: [PaneNode], weights: [Double])
}

/// The four sides of a leaf a move can land on.
enum PaneEdge: Hashable, Sendable {
    case left, right, top, bottom

    var axis: PaneAxis { self == .left || self == .right ? .row : .column }
    var isTrailing: Bool { self == .right || self == .bottom }
}

enum PaneLayoutError: Error, Hashable, Sendable {
    case unknownLeaf(PaneID)
    case duplicateLeaf(PaneID)
    case emptyStack(PaneID)
    case emptyTree
    case tooManyLeaves(Int)
    case tooDeep(Int)
    /// A split addressed by a path that names no split.
    case notASplit([Int])
    case invalidWeights
    /// Closing or collapsing would leave the window with nothing to show.
    case lastLeaf
    case sameLeaf
}

struct PaneLayout: Hashable, Sendable {
    static let maximumLeaves = 8
    static let maximumDepth = 3
    static let maximumSplitChildren = 8

    var root: PaneNode
    var focus: PaneID
    /// Most recently focused first; every leaf exactly once. The fit rule
    /// sends the least recent leaves to overflow.
    var recency: [PaneID]
    var zoomed: PaneID?
    /// Collapsed leaves, each with the share of its split it had when it
    /// collapsed; `expand` gives that share back.
    var collapsed: [PaneID: Double]

    init(root: PaneNode, focus: PaneID, recency: [PaneID] = [], zoomed: PaneID? = nil, collapsed: [PaneID: Double] = [:]) {
        self.root = root
        self.focus = focus
        self.recency = recency
        self.zoomed = zoomed
        self.collapsed = collapsed
    }

    /// One leaf showing `leaf`.
    init(single leaf: PaneLeaf) {
        self.init(root: .leaf(leaf), focus: leaf.id, recency: [leaf.id])
    }

    var leaves: [PaneLeaf] { root.leaves }

    func leaf(_ id: PaneID) -> PaneLeaf? {
        leaves.first { $0.id == id }
    }

    // MARK: Normalisation

    /// The same layout with every invariant restored, or the reason it cannot
    /// be: splits have 2–8 children with positive weights summing to 1, a
    /// child split never shares its parent's axis, a split with one child
    /// gives way to it, depth ≤ 3, ≤ 8 leaves with unique ids and non-empty
    /// stacks, `focus` names a leaf (else the most recent one), `recency`
    /// holds each leaf once (missing ones appended in tree order), and zoom
    /// and collapse name only leaves. A zoom also needs another leaf to hide
    /// and a leaf that is not collapsed: a zoomed strip has no grip to exit
    /// it, and a lone zoomed leaf would hide the next split behind it.
    func normalised() throws -> PaneLayout {
        guard let root = Self.normalise(root) else { throw PaneLayoutError.emptyTree }
        let leaves = root.leaves
        guard leaves.count <= Self.maximumLeaves else { throw PaneLayoutError.tooManyLeaves(leaves.count) }
        let depth = root.depth
        guard depth <= Self.maximumDepth else { throw PaneLayoutError.tooDeep(depth) }
        var ids: Set<PaneID> = []
        for leaf in leaves {
            guard ids.insert(leaf.id).inserted else { throw PaneLayoutError.duplicateLeaf(leaf.id) }
            guard !leaf.stack.isEmpty else { throw PaneLayoutError.emptyStack(leaf.id) }
        }
        var seen: Set<PaneID> = []
        var recency = recency.filter { ids.contains($0) && seen.insert($0).inserted }
        recency += leaves.map(\.id).filter { !seen.contains($0) }
        let focus = ids.contains(focus) ? focus : recency[0]
        let collapsed = collapsed.filter { ids.contains($0.key) && $0.value > 0 && $0.value.isFinite }
        return PaneLayout(
            root: root,
            focus: focus,
            recency: recency,
            zoomed: zoomed.flatMap { ids.contains($0) && ids.count > 1 && collapsed[$0] == nil ? $0 : nil },
            collapsed: collapsed
        )
    }

    private static func normalise(_ node: PaneNode) -> PaneNode? {
        guard case .split(let axis, let rawChildren, let rawWeights) = node else { return node }
        let weights = validWeights(rawWeights, count: rawChildren.count) ?? equalWeights(rawChildren.count)
        var children: [PaneNode] = []
        var kept: [Double] = []
        for (child, weight) in zip(rawChildren, weights) {
            guard let child = normalise(child) else { continue }
            if case .split(let childAxis, let grandchildren, let childWeights) = child, childAxis == axis {
                children += grandchildren
                kept += childWeights.map { $0 * weight }
            } else {
                children.append(child)
                kept.append(weight)
            }
        }
        switch children.count {
        case 0: return nil
        case 1: return children[0]
        default: return .split(axis: axis, children: children, weights: scaledToOne(kept))
        }
    }

    // MARK: Operations

    /// Splits `target` along `axis`, putting `leaf` after it. In a split of
    /// the same axis the new leaf takes half of the target's share; otherwise
    /// the target is wrapped in a new split that takes its share. The new leaf
    /// is the least recent; focus does not move.
    func split(_ target: PaneID, axis: PaneAxis, inserting leaf: PaneLeaf) throws -> PaneLayout {
        try inserting(leaf, beside: target, axis: axis, after: true)
    }

    /// Closes `id` and every leaf attached to it. A closed leaf's share goes
    /// to the sibling before it (after it, when it was first). Focus moves to
    /// the most recent remaining leaf when its leaf closed.
    func close(_ id: PaneID) throws -> PaneLayout {
        guard leaf(id) != nil else { throw PaneLayoutError.unknownLeaf(id) }
        var closing: Set<PaneID> = [id]
        // Attached leaves close with their chat, and so do leaves attached to them.
        while true {
            let more = leaves.filter { $0.attachedTo.map(closing.contains) == true && !closing.contains($0.id) }
            if more.isEmpty { break }
            closing.formUnion(more.map(\.id))
        }
        guard closing.count < leaves.count else { throw PaneLayoutError.lastLeaf }
        var layout = self
        for leafID in leaves.map(\.id) where closing.contains(leafID) {
            // Unwrap a split left with one child before the next removal reads it.
            guard let root = try Self.normalise(layout.root.removing(leafID)) else { throw PaneLayoutError.lastLeaf }
            layout.root = root
        }
        layout.recency.removeAll { closing.contains($0) }
        if closing.contains(focus) { layout.focus = layout.recency[0] }
        if let zoomed, closing.contains(zoomed) { layout.zoomed = nil }
        layout.collapsed = layout.collapsed.filter { !closing.contains($0.key) }
        return try layout.normalised()
    }

    /// Moves `id` to `edge` of `target`, by the split arithmetic. Focus,
    /// recency and collapse stay with the leaf.
    func move(_ id: PaneID, to target: PaneID, edge: PaneEdge) throws -> PaneLayout {
        guard id != target else { throw PaneLayoutError.sameLeaf }
        guard let moving = leaf(id) else { throw PaneLayoutError.unknownLeaf(id) }
        guard leaf(target) != nil else { throw PaneLayoutError.unknownLeaf(target) }
        guard let remaining = try Self.normalise(root.removing(id)) else { throw PaneLayoutError.lastLeaf }
        var removed = self
        removed.root = remaining
        var moved = try removed.inserting(moving, beside: target, axis: edge.axis, after: edge.isTrailing)
        moved.focus = focus
        moved.recency = recency
        moved.zoomed = zoomed
        moved.collapsed = collapsed
        return moved
    }

    /// Trades the places of two leaves. The weights stay with the places;
    /// focus, zoom and collapse stay with their leaves.
    func swap(_ first: PaneID, _ second: PaneID) throws -> PaneLayout {
        guard first != second else { throw PaneLayoutError.sameLeaf }
        guard let a = leaf(first) else { throw PaneLayoutError.unknownLeaf(first) }
        guard let b = leaf(second) else { throw PaneLayoutError.unknownLeaf(second) }
        var layout = self
        layout.root = root.mapLeaves { $0.id == first ? b : ($0.id == second ? a : $0) }
        return layout
    }

    /// Sets the weights of the split at `path` (child indexes from the root).
    /// Weights must be positive and as many as the children; they are scaled
    /// to sum to 1.
    func setWeights(at path: [Int], _ weights: [Double]) throws -> PaneLayout {
        guard case .split(let axis, let children, _) = root.node(at: path) else { throw PaneLayoutError.notASplit(path) }
        guard let valid = Self.validWeights(weights, count: children.count) else { throw PaneLayoutError.invalidWeights }
        var layout = self
        layout.root = root.replacing(at: path, with: .split(axis: axis, children: children, weights: Self.scaledToOne(valid)))
        return layout
    }

    /// Pushes `entry` on `target`'s stack, unless it is already on top.
    func open(_ entry: PaneStackEntry, in target: PaneID) throws -> PaneLayout {
        guard leaf(target) != nil else { throw PaneLayoutError.unknownLeaf(target) }
        var layout = self
        layout.root = root.mapLeaves { leaf in
            guard leaf.id == target, leaf.stack.last != entry else { return leaf }
            var leaf = leaf
            leaf.stack.append(entry)
            return leaf
        }
        return layout
    }

    /// Zooms `id` to fill the window and focuses it; nil restores.
    func zoom(_ id: PaneID?) throws -> PaneLayout {
        guard let id else {
            var layout = self
            layout.zoomed = nil
            return layout
        }
        var layout = try focusing(id)
        layout.zoomed = id
        return layout
    }

    /// Collapses `id` to a strip, remembering its share. A focused leaf hands
    /// focus to the most recent leaf still open.
    func collapse(_ id: PaneID) throws -> PaneLayout {
        guard let path = root.path(of: id) else { throw PaneLayoutError.unknownLeaf(id) }
        guard collapsed[id] == nil else { return self }
        guard let parentPath = path.parentPath,
              case .split(_, _, let weights) = root.node(at: parentPath),
              let index = path.last
        else { throw PaneLayoutError.lastLeaf }
        guard let nextFocus = recency.first(where: { $0 != id && collapsed[$0] == nil }) else {
            throw PaneLayoutError.lastLeaf
        }
        var layout = self
        layout.collapsed[id] = weights[index]
        if focus == id { layout = try layout.focusing(nextFocus) }
        if zoomed == id { layout.zoomed = nil }
        return layout
    }

    /// Expands a collapsed leaf back to the share it had; its siblings scale
    /// to fill the rest.
    func expand(_ id: PaneID) throws -> PaneLayout {
        guard let path = root.path(of: id) else { throw PaneLayoutError.unknownLeaf(id) }
        guard let share = collapsed[id] else { return self }
        var layout = self
        layout.collapsed[id] = nil
        guard let parentPath = path.parentPath, let index = path.last,
              case .split(let axis, let children, let weights) = root.node(at: parentPath)
        else { return layout }
        let others = weights.enumerated().filter { $0.offset != index }.map(\.element).reduce(0, +)
        let restored = weights.enumerated().map { offset, weight in
            offset == index ? share : weight / others * (1 - share)
        }
        layout.root = root.replacing(at: parentPath, with: .split(axis: axis, children: children, weights: restored))
        return layout
    }

    /// Focuses `id`, making it the most recent. A hidden leaf is shown: a
    /// collapsed one expands and another leaf's zoom ends.
    func focusing(_ id: PaneID) throws -> PaneLayout {
        guard leaf(id) != nil else { throw PaneLayoutError.unknownLeaf(id) }
        var layout = collapsed[id] == nil ? self : try expand(id)
        layout.focus = id
        layout.recency.removeAll { $0 == id }
        layout.recency.insert(id, at: 0)
        if let zoomed, zoomed != id { layout.zoomed = nil }
        return layout
    }

    /// Another whole layout (Open Layout, Undo, Reset Panes), checked first.
    func replace(with layout: PaneLayout) throws -> PaneLayout {
        try layout.normalised()
    }

    // MARK: Helpers

    private func inserting(_ leaf: PaneLeaf, beside target: PaneID, axis: PaneAxis, after: Bool) throws -> PaneLayout {
        guard let path = root.path(of: target) else { throw PaneLayoutError.unknownLeaf(target) }
        guard self.leaf(leaf.id) == nil else { throw PaneLayoutError.duplicateLeaf(leaf.id) }
        guard !leaf.stack.isEmpty else { throw PaneLayoutError.emptyStack(leaf.id) }
        var layout = self
        if let parentPath = path.parentPath, let index = path.last,
           case .split(let parentAxis, var children, var weights) = root.node(at: parentPath),
           parentAxis == axis {
            let half = weights[index] / 2
            weights[index] = half
            let at = after ? index + 1 : index
            children.insert(.leaf(leaf), at: at)
            weights.insert(half, at: at)
            layout.root = root.replacing(at: parentPath, with: .split(axis: axis, children: children, weights: weights))
        } else {
            guard let targetNode = root.node(at: path) else { throw PaneLayoutError.unknownLeaf(target) }
            let pair: [PaneNode] = after ? [targetNode, .leaf(leaf)] : [.leaf(leaf), targetNode]
            layout.root = root.replacing(at: path, with: .split(axis: axis, children: pair, weights: [0.5, 0.5]))
        }
        return try layout.normalised()
    }

    private static func validWeights(_ weights: [Double], count: Int) -> [Double]? {
        guard weights.count == count, weights.allSatisfy({ $0 > 0 && $0.isFinite }) else { return nil }
        return weights
    }

    private static func equalWeights(_ count: Int) -> [Double] {
        Array(repeating: 1 / Double(max(count, 1)), count: count)
    }

    private static func scaledToOne(_ weights: [Double]) -> [Double] {
        let sum = weights.reduce(0, +)
        return weights.map { $0 / sum }
    }
}

extension PaneNode {
    /// Leaves in tree order (depth first, children in order).
    var leaves: [PaneLeaf] {
        switch self {
        case .leaf(let leaf): [leaf]
        case .split(_, let children, _): children.flatMap(\.leaves)
        }
    }

    /// Nested splits on the deepest path: a lone leaf is 0.
    var depth: Int {
        switch self {
        case .leaf: 0
        case .split(_, let children, _): 1 + (children.map(\.depth).max() ?? 0)
        }
    }

    /// Child indexes from this node to the leaf `id`.
    func path(of id: PaneID) -> [Int]? {
        switch self {
        case .leaf(let leaf):
            return leaf.id == id ? [] : nil
        case .split(_, let children, _):
            for (index, child) in children.enumerated() {
                if let rest = child.path(of: id) { return [index] + rest }
            }
            return nil
        }
    }

    func node(at path: [Int]) -> PaneNode? {
        guard let first = path.first else { return self }
        guard case .split(_, let children, _) = self, children.indices.contains(first) else { return nil }
        return children[first].node(at: Array(path.dropFirst()))
    }

    func replacing(at path: [Int], with node: PaneNode) -> PaneNode {
        guard let first = path.first else { return node }
        guard case .split(let axis, var children, let weights) = self, children.indices.contains(first) else { return self }
        children[first] = children[first].replacing(at: Array(path.dropFirst()), with: node)
        return .split(axis: axis, children: children, weights: weights)
    }

    func mapLeaves(_ transform: (PaneLeaf) -> PaneLeaf) -> PaneNode {
        switch self {
        case .leaf(let leaf): .leaf(transform(leaf))
        case .split(let axis, let children, let weights):
            .split(axis: axis, children: children.map { $0.mapLeaves(transform) }, weights: weights)
        }
    }

    /// Removes the leaf `id`; its share goes to the sibling before it, or
    /// the one after it when it was first. A split left with one child is
    /// left for `normalised()` to unwrap.
    fileprivate func removing(_ id: PaneID) throws -> PaneNode {
        guard let path = path(of: id), let parentPath = path.parentPath, let index = path.last,
              case .split(let axis, var children, var weights) = node(at: parentPath), children.count > 1
        else { throw PaneLayoutError.lastLeaf }
        let recipient = index > 0 ? index - 1 : 1
        weights[recipient] += weights[index]
        children.remove(at: index)
        weights.remove(at: index)
        return replacing(at: parentPath, with: .split(axis: axis, children: children, weights: weights))
    }
}

private extension Array where Element == Int {
    var parentPath: [Int]? { isEmpty ? nil : Array(dropLast()) }
}
