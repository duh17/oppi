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
    ///   - keyboardHeight: the software keyboard's overlap with the pane area's bottom edge.
    ///   - minimumSize: each leaf's minimum, by its content (`PaneMinimumSize`).
    ///   - liveCap: the most leaves that may be live (visible and not collapsed) at once.
    static func resolve(
        _ layout: PaneLayout,
        size: CGSize,
        sidebarWidth: CGFloat,
        keyboardHeight: CGFloat,
        firstResponderLeaf: PaneID?,
        minimumSize: (PaneLeaf) -> CGSize,
        liveCap: Int
    ) -> PanePresentation {
        let area = CGRect(x: 0, y: 0, width: max(0, size.width - sidebarWidth), height: max(0, size.height))
        if let zoomed = layout.zoomed, layout.leaf(zoomed) != nil {
            return PanePresentation(frames: [zoomed: area], overflow: [], zoomedForKeyboard: nil)
        }
        let minimums = Dictionary(uniqueKeysWithValues: layout.leaves.map { ($0.id, minimumSize($0)) })
        let collapsed = Set(layout.collapsed.keys)
        var hidden: Set<PaneID> = []
        // Least recent first; the focused leaf never leaves.
        var candidates = layout.recency.reversed().filter { $0 != layout.focus }

        var live = layout.leaves.count { !collapsed.contains($0.id) }
        while live > max(liveCap, 1), let index = candidates.firstIndex(where: { !collapsed.contains($0) }) {
            hidden.insert(candidates.remove(at: index))
            live -= 1
        }
        var shown = layout.root.pruned(keeping: { !hidden.contains($0) })
        while let tree = shown, !tree.fits(in: area.size, minimums: minimums, collapsed: collapsed), !candidates.isEmpty {
            hidden.insert(candidates.removeFirst())
            shown = layout.root.pruned(keeping: { !hidden.contains($0) })
        }

        var frames: [PaneID: CGRect] = [:]
        shown?.place(in: area, minimums: minimums, collapsed: collapsed, frames: &frames)
        let zoomedForKeyboard = shown.flatMap {
            keyboardZoom(in: $0, frames: &frames, area: area, keyboardHeight: keyboardHeight,
                         firstResponderLeaf: firstResponderLeaf, minimums: minimums)
        }
        return PanePresentation(
            frames: frames,
            overflow: layout.recency.filter(hidden.contains),
            zoomedForKeyboard: zoomedForKeyboard
        )
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

    /// The minimum for a linkable route; nil for `.local`, which only the app can size.
    static func standard(for route: PaneRoute) -> CGSize? {
        switch route {
        case .session, .thread: chat
        case .sessions, .files, .git, .panel, .unsupported: list
        case .file, .commit: document
        case .local: nil
        }
    }
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

    func fits(in size: CGSize, minimums: [PaneID: CGSize], collapsed: Set<PaneID>) -> Bool {
        let needed = minimumSize(minimums: minimums, collapsed: collapsed, parentAxis: nil)
        return needed.width <= size.width && needed.height <= size.height
    }

    /// The smallest size this node can take. A collapsed leaf costs its strip
    /// along its parent's axis and nothing across it.
    func minimumSize(minimums: [PaneID: CGSize], collapsed: Set<PaneID>, parentAxis: PaneAxis?) -> CGSize {
        switch self {
        case .leaf(let leaf):
            guard let parentAxis, collapsed.contains(leaf.id) else { return minimums[leaf.id] ?? .zero }
            let strip = PanePresentation.collapsedThickness
            return parentAxis == .row ? CGSize(width: strip, height: 0) : CGSize(width: 0, height: strip)
        case .split(let axis, let children, _):
            let sizes = children.map { $0.minimumSize(minimums: minimums, collapsed: collapsed, parentAxis: axis) }
            let dividers = PanePresentation.dividerThickness * CGFloat(children.count - 1)
            switch axis {
            case .row:
                return CGSize(width: sizes.map(\.width).reduce(0, +) + dividers, height: sizes.map(\.height).max() ?? 0)
            case .column:
                return CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).reduce(0, +) + dividers)
            }
        }
    }

    func place(in rect: CGRect, minimums: [PaneID: CGSize], collapsed: Set<PaneID>, frames: inout [PaneID: CGRect]) {
        switch self {
        case .leaf(let leaf):
            frames[leaf.id] = rect
        case .split(let axis, let children, let weights):
            let length = axis == .row ? rect.width : rect.height
            let available = max(0, length - PanePresentation.dividerThickness * CGFloat(children.count - 1))
            let fixed: [CGFloat?] = children.map { child in
                if case .leaf(let leaf) = child, collapsed.contains(leaf.id) { return PanePresentation.collapsedThickness }
                return nil
            }
            let floors = children.map { child -> CGFloat in
                let size = child.minimumSize(minimums: minimums, collapsed: collapsed, parentAxis: axis)
                return axis == .row ? size.width : size.height
            }
            let lengths = Self.allocate(available, weights: weights, fixed: fixed, floors: floors)
            var start = axis == .row ? rect.minX : rect.minY
            var exactEnd = start
            for (child, childLength) in zip(children, lengths) {
                exactEnd += childLength
                // Whole points: positions round, so lengths still add up to the split.
                let end = exactEnd.rounded()
                let childRect = axis == .row
                    ? CGRect(x: start, y: rect.minY, width: end - start, height: rect.height)
                    : CGRect(x: rect.minX, y: start, width: rect.width, height: end - start)
                child.place(in: childRect, minimums: minimums, collapsed: collapsed, frames: &frames)
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
