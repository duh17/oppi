import Foundation
import CoreGraphics

/// Where each leaf of a `PaneLayout` goes in one window: the fit rule, as a
/// pure function. The app passes everything platform-dependent (the leaves'
/// minimum sizes and the live cap); nothing here asks the device.
struct PanePresentation: Equatable, Sendable {
    /// Visible leaves, in the pane area's coordinates: origin at its top
    /// leading corner, after a tiled sidebar. A leaf behind a zoom, or hidden
    /// by the keyboard zoom, has no frame and is not in `overflow`.
    var frames: [PaneID: CGRect]
    /// Leaves that did not fit or were over the live cap, most recent first.
    /// No host reads this yet: Stage 3's tree host shows it for layouts and
    /// explicit splits. A pane opened beside another that cannot fit never
    /// lands here: the fit rule (build plan §1.3) opens it full, as
    /// `PaneWidthPolicy.fitsBeside` does today and the tree's `zoomed` will.
    var overflow: [PaneID]
    /// The first responder's leaf, drawn over its whole column because the
    /// keyboard left it below its minimum height.
    var zoomedForKeyboard: PaneID?

    static let dividerThickness: CGFloat = 1
    /// What a collapsed leaf costs along its split.
    static let collapsedThickness: CGFloat = 20

    /// - Parameters:
    ///   - size: the window's content size.
    ///   - sidebarWidth: width a tiled sidebar takes; 0 when it overlays as a drawer or is hidden.
    ///   - bottomInset: the window's bottom safe area, where the system's
    ///     home-indicator swipe starts. A leaf that reaches the bottom keeps
    ///     its minimum height above it, and a collapsed one its strip, so no
    ///     pane's grip, strip or bar sits in that gesture zone.
    ///   - topInset: the window's top safe area (status bar, window
    ///     controls), where the system's pull-down starts. A collapsed leaf
    ///     at the top keeps its strip below it, so a strip there can be
    ///     touched; an open leaf's own bar already clears it.
    ///   - keyboardHeight: the software keyboard's overlap with the pane area's bottom edge.
    ///   - minimumSize: each leaf's minimum, by its content (`PaneMinimumSize`).
    ///   - liveCap: the most leaves that may be live (visible and not collapsed) at once.
    static func resolve(
        _ layout: PaneLayout,
        size: CGSize,
        sidebarWidth: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        keyboardHeight: CGFloat,
        firstResponderLeaf: PaneID?,
        minimumSize: (PaneLeaf) -> CGSize,
        liveCap: Int
    ) -> PanePresentation {
        let area = CGRect(x: 0, y: 0, width: max(0, size.width - sidebarWidth), height: max(0, size.height))
        if let zoomed = layout.zoomed, layout.leaf(zoomed) != nil {
            return PanePresentation(frames: [zoomed: area], overflow: [], zoomedForKeyboard: nil)
        }
        let minimums = PaneMinimums(
            sizes: Dictionary(uniqueKeysWithValues: layout.leaves.map { ($0.id, minimumSize($0)) }),
            collapsed: Set(layout.collapsed.keys),
            topInset: max(0, topInset),
            bottomInset: max(0, bottomInset)
        )
        let collapsed = minimums.collapsed
        var hidden: Set<PaneID> = []
        // Least recent first; the focused leaf never leaves.
        var candidates = layout.recency.reversed().filter { $0 != layout.focus }

        var live = layout.leaves.count { !collapsed.contains($0.id) }
        while live > max(liveCap, 1), let index = candidates.firstIndex(where: { !collapsed.contains($0) }) {
            hidden.insert(candidates.remove(at: index))
            live -= 1
        }
        var shown = layout.root.pruned(keeping: { !hidden.contains($0) })
        while let tree = shown, !tree.fits(in: area.size, minimums: minimums), !candidates.isEmpty {
            hidden.insert(candidates.removeFirst())
            shown = layout.root.pruned(keeping: { !hidden.contains($0) })
        }

        var frames: [PaneID: CGRect] = [:]
        shown?.place(in: area, minimums: minimums, reach: .whole, frames: &frames)
        let zoomedForKeyboard = shown.flatMap {
            keyboardZoom(in: $0, frames: &frames, area: area, keyboardHeight: keyboardHeight,
                         firstResponderLeaf: firstResponderLeaf, minimums: minimums.sizes)
        }
        return PanePresentation(
            frames: frames,
            overflow: layout.recency.filter(hidden.contains),
            zoomedForKeyboard: zoomedForKeyboard
        )
    }

    /// The least `node` can take along `axis`, by the same rule `resolve`
    /// fits and places with: a divider drag holds each side there.
    /// `reachesTop`, `reachesBottom`: the node's top or bottom edge is the
    /// pane area's.
    static func minimumLength(
        of node: PaneNode,
        along axis: PaneAxis,
        in layout: PaneLayout,
        topInset: CGFloat,
        bottomInset: CGFloat,
        reachesTop: Bool,
        reachesBottom: Bool,
        minimumSize: (PaneLeaf) -> CGSize
    ) -> CGFloat {
        let minimums = PaneMinimums(
            sizes: Dictionary(uniqueKeysWithValues: node.leaves.map { ($0.id, minimumSize($0)) }),
            collapsed: Set(layout.collapsed.keys),
            topInset: max(0, topInset),
            bottomInset: max(0, bottomInset)
        )
        let reach = PaneEdgeReach(top: reachesTop, bottom: reachesBottom)
        let size = node.minimumSize(minimums: minimums, parentAxis: nil, reach: reach)
        return axis == .row ? size.width : size.height
    }

    /// When the keyboard leaves the first responder's leaf below its minimum
    /// height, that leaf takes its nearest column's whole frame and the
    /// column's other leaves are hidden (not sent to overflow).
    private static func keyboardZoom(
        in tree: PaneNode,
        frames: inout [PaneID: CGRect],
        area: CGRect,
        keyboardHeight: CGFloat,
        firstResponderLeaf: PaneID?,
        minimums: [PaneID: CGSize]
    ) -> PaneID? {
        guard keyboardHeight > 0, let id = firstResponderLeaf, let frame = frames[id],
              let path = tree.path(of: id) else { return nil }
        let visible = max(0, min(frame.maxY, area.maxY - keyboardHeight) - frame.minY)
        guard visible < (minimums[id]?.height ?? 0) else { return nil }
        guard let columnPath = (0..<path.count).reversed().map({ Array(path.prefix($0)) }).first(where: {
            if case .split(.column, _, _) = tree.node(at: $0) { return true }
            return false
        }), let column = tree.node(at: columnPath) else { return nil }
        let columnLeaves = column.leaves.map(\.id)
        let columnFrame = columnLeaves.compactMap { frames[$0] }.reduce(CGRect.null) { $0.union($1) }
        for leaf in columnLeaves { frames[leaf] = nil }
        frames[id] = columnFrame
        return id
    }
}

/// Minimum leaf sizes by content. The app passes them to `resolve`, choosing
/// one for screens without a route (`.local`).
enum PaneMinimumSize {
    /// The width the chat's bars, composer and rows are tested at.
    static let chat = CGSize(width: 375, height: 320)
    /// Session list, Files, Git, Outline, Context, panels.
    static let list = CGSize(width: 320, height: 280)
    /// Reader, editor and diff.
    static let document = CGSize(width: 360, height: 280)
    /// A chat's panel beside it (Files, Git, Outline, Context, Share, a
    /// reader, an extension panel): never narrower than an iPhone (390 pt,
    /// iPhone 12 to 16). With the chat's 375 pt that is 766 pt, so the iPad
    /// mini in portrait (744 pt; 756 pt on the A20 Pro) shows the panel full
    /// over the chat by the fit rule, and landscape (813 pt beside the
    /// sidebar) puts it beside the chat.
    static let attached = CGSize(width: 390, height: 280)
    /// A web page: the narrowest width sites lay out for.
    static let browser = CGSize(width: 320, height: 320)
    /// A game: the smallest a game's viewport is worth drawing at.
    static let godot = CGSize(width: 320, height: 240)

    /// The minimum for a linkable route; nil for `.local`, which only the app can size.
    static func standard(for route: PaneRoute) -> CGSize? {
        switch route {
        case .session, .thread: chat
        case .sessions, .files, .hostFiles, .git, .panel, .unsupported: list
        case .file, .commit: document
        case .browser: browser
        case .godot: godot
        case .local: nil
        }
    }
}

/// What `resolve` holds each leaf to: its minimum size, which leaves are
/// strips, and the safe areas a leaf or strip at the top or bottom keeps
/// clear of.
private struct PaneMinimums {
    var sizes: [PaneID: CGSize]
    var collapsed: Set<PaneID>
    var topInset: CGFloat
    var bottomInset: CGFloat

    /// What a column's strip costs: its thickness, plus the inset of each
    /// window edge it meets, which it paints but keeps its mark out of.
    func columnStrip(_ reach: PaneEdgeReach) -> CGFloat {
        PanePresentation.collapsedThickness + (reach.top ? topInset : 0) + (reach.bottom ? bottomInset : 0)
    }
}

/// Whether a node's top and bottom edges are the pane area's.
private struct PaneEdgeReach {
    var top: Bool
    var bottom: Bool

    static let whole = Self(top: true, bottom: true)
}

private extension PaneNode {
    /// The tree with only the leaves `keep` accepts; a split left with one
    /// child gives way to it. Weights are kept as they are; `place` scales them.
    func pruned(keeping keep: (PaneID) -> Bool) -> PaneNode? {
        switch self {
        case .leaf(let leaf):
            return keep(leaf.id) ? self : nil
        case .split(let axis, let children, let weights):
            let kept = zip(children, weights).compactMap { child, weight in
                child.pruned(keeping: keep).map { ($0, weight) }
            }
            switch kept.count {
            case 0: return nil
            case 1: return kept[0].0
            default: return .split(axis: axis, children: kept.map(\.0), weights: kept.map(\.1))
            }
        }
    }

    func fits(in size: CGSize, minimums: PaneMinimums) -> Bool {
        let needed = minimumSize(minimums: minimums, parentAxis: nil, reach: .whole)
        return needed.width <= size.width && needed.height <= size.height
    }

    /// Which window edges each child meets: every child of a row meets this
    /// node's; in a column only the first meets its top and the last its bottom.
    func childrenReach(_ reach: PaneEdgeReach) -> [PaneEdgeReach] {
        guard case .split(let axis, let children, _) = self else { return [] }
        return children.indices.map {
            PaneEdgeReach(
                top: reach.top && (axis == .row || $0 == 0),
                bottom: reach.bottom && (axis == .row || $0 == children.count - 1)
            )
        }
    }

    /// The smallest size this node can take. A collapsed leaf costs its strip
    /// along its parent's axis and nothing across it. A node that reaches
    /// the bottom adds the bottom inset to its height: a leaf's minimum, or
    /// a column's strip, sits above it. A column's strip at the top sits
    /// below the top inset too; an open leaf there clears it with its own bar.
    func minimumSize(minimums: PaneMinimums, parentAxis: PaneAxis?, reach: PaneEdgeReach) -> CGSize {
        switch self {
        case .leaf(let leaf):
            guard let parentAxis, minimums.collapsed.contains(leaf.id) else {
                let size = minimums.sizes[leaf.id] ?? .zero
                return CGSize(width: size.width, height: size.height + (reach.bottom ? minimums.bottomInset : 0))
            }
            return parentAxis == .row
                ? CGSize(width: PanePresentation.collapsedThickness, height: 0)
                : CGSize(width: 0, height: minimums.columnStrip(reach))
        case .split(let axis, let children, _):
            let sizes = zip(children, childrenReach(reach)).map {
                $0.minimumSize(minimums: minimums, parentAxis: axis, reach: $1)
            }
            let dividers = PanePresentation.dividerThickness * CGFloat(children.count - 1)
            switch axis {
            case .row:
                return CGSize(width: sizes.map(\.width).reduce(0, +) + dividers, height: sizes.map(\.height).max() ?? 0)
            case .column:
                return CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).reduce(0, +) + dividers)
            }
        }
    }

    func place(in rect: CGRect, minimums: PaneMinimums, reach: PaneEdgeReach, frames: inout [PaneID: CGRect]) {
        switch self {
        case .leaf(let leaf):
            frames[leaf.id] = rect
        case .split(let axis, let children, let weights):
            let length = axis == .row ? rect.width : rect.height
            let available = max(0, length - PanePresentation.dividerThickness * CGFloat(children.count - 1))
            let reaches = childrenReach(reach)
            let fixed: [CGFloat?] = zip(children, reaches).map { child, reach in
                guard case .leaf(let leaf) = child, minimums.collapsed.contains(leaf.id) else { return nil }
                // A column's last strip sits above the bottom inset, its first below the top inset.
                return axis == .column ? minimums.columnStrip(reach) : PanePresentation.collapsedThickness
            }
            let floors = zip(children, reaches).map { child, reach -> CGFloat in
                let size = child.minimumSize(minimums: minimums, parentAxis: axis, reach: reach)
                return axis == .row ? size.width : size.height
            }
            let lengths = Self.allocate(available, weights: weights, fixed: fixed, floors: floors)
            var start = axis == .row ? rect.minX : rect.minY
            var exactEnd = start
            for (index, (child, childLength)) in zip(children, lengths).enumerated() {
                exactEnd += childLength
                // Whole points: positions round, so lengths still add up to the split.
                let end = exactEnd.rounded()
                let childRect = axis == .row
                    ? CGRect(x: start, y: rect.minY, width: end - start, height: rect.height)
                    : CGRect(x: rect.minX, y: start, width: rect.width, height: end - start)
                child.place(in: childRect, minimums: minimums, reach: reaches[index], frames: &frames)
                start = end + PanePresentation.dividerThickness
                exactEnd += PanePresentation.dividerThickness
            }
        }
    }

    /// Shares `available` by weight, raising any share below its floor to the
    /// floor and dividing what is left among the rest. Fixed lengths (strips)
    /// come off first. When the floors cannot all be met, shares follow the
    /// floors; when every child is fixed, the last takes what is left.
    static func allocate(_ available: CGFloat, weights: [Double], fixed: [CGFloat?], floors: [CGFloat]) -> [CGFloat] {
        var lengths = fixed.map { $0 ?? 0 }
        var flexible = Set(fixed.indices.filter { fixed[$0] == nil })
        var remaining = available - lengths.reduce(0, +)
        guard !flexible.isEmpty else {
            if let last = lengths.indices.last { lengths[last] += max(0, remaining) }
            return lengths
        }
        let flexibleFloors = flexible.map { floors[$0] }.reduce(0, +)
        if flexibleFloors > remaining {
            for index in flexible {
                lengths[index] = flexibleFloors > 0 ? max(0, remaining) * floors[index] / flexibleFloors : 0
            }
            return lengths
        }
        while true {
            let weightSum = flexible.map { weights[$0] }.reduce(0, +)
            let short = flexible.filter { remaining * CGFloat(weights[$0] / weightSum) < floors[$0] }
            if short.isEmpty {
                for index in flexible { lengths[index] = remaining * CGFloat(weights[index] / weightSum) }
                return lengths
            }
            for index in short {
                lengths[index] = floors[index]
                remaining -= floors[index]
                flexible.remove(index)
            }
        }
    }
}
