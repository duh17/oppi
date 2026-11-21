import UIKit
import UniformTypeIdentifiers

/// What a pane drag carries inside the app: an entry a dragged row opens (a
/// File Browser row), or a pane its grip moves (`gripPanned`). A drag with
/// one of these lights the pane zones; anything else (a file from Files, a
/// photo) can only drop on a chat.
final class PaneDragPayload: NSObject {
    enum Content: Equatable {
        case entry(PaneStackEntry)
        case pane(PaneID)
    }

    let content: Content

    init(entry: PaneStackEntry) {
        content = .entry(entry)
    }
}

/// Where a drop over the window's panes lands (build plan §1.9): the outer
/// quarter of a pane is its nearest edge, the middle the pane itself. An
/// entry opens in a new pane at that edge, or in the pane; a lifted pane
/// moves to that edge, or swaps with the pane; a chat takes a drop on its
/// middle or its composer, a file of its workspace as a reference and an
/// outside item as an attachment.
enum PaneDropTarget: Equatable {
    case split(PaneID, PaneEdge)
    case open(PaneID)
    case move(PaneID, PaneEdge)
    case swap(PaneID)
    case chat

    /// The zone of `cell` under `point`: its nearest edge within the outer
    /// quarter (by share of the pane's width or height), else the middle.
    static func zone(at point: CGPoint, in cell: CGRect) -> PaneEdge? {
        guard cell.width > 0, cell.height > 0 else { return nil }
        let distances: [(PaneEdge, CGFloat)] = [
            (.left, (point.x - cell.minX) / cell.width),
            (.right, (cell.maxX - point.x) / cell.width),
            (.top, (point.y - cell.minY) / cell.height),
            (.bottom, (cell.maxY - point.y) / cell.height),
        ]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < 0.25 else { return nil }
        return nearest.0
    }
}

extension PaneHostController: UIDropInteractionDelegate {
    func installDropInteraction() {
        view.addInteraction(UIDropInteraction(delegate: self))
        dropHighlight.isUserInteractionEnabled = false
        dropHighlight.isHidden = true
        dropHighlight.layer.cornerRadius = 12
        dropHighlight.layer.borderWidth = 2
        dropHighlight.accessibilityIdentifier = "pane.dropZone"
        view.addSubview(dropHighlight)
    }

    private func payload(of session: UIDropSession) -> PaneDragPayload.Content? {
        session.localDragSession?.items.lazy.compactMap { ($0.localObject as? PaneDragPayload)?.content }.first
    }

    /// The chat in front in the primary's cell, shown or not: the window's
    /// current chat, which a pane beside it hands things to.
    var routedChat: ChatViewController? {
        (frontScreen(ofCell: panes.mainLeafID) as? ChatRouteViewController)?.chat
    }

    /// The chat in the primary's cell, while it shows.
    private var shownChat: ChatViewController? {
        guard routedCell.width > 0, !primary.view.isHidden else { return nil }
        return routedChat
    }

    /// Brings the primary's cell into view and gives it focus: out of
    /// another cell's zoom, and in place of the pane a compact window shows.
    func showRoutedCell() {
        if let zoomed = panes.cellLayout.zoomed, zoomed != panes.mainLeafID { zoom(nil) }
        focus(cell: panes.mainLeafID)
    }

    /// Where a drop at `point` would land, and the zone it lights (nil when
    /// what it fills would land out of sight); nil where it would do nothing.
    func dropTarget(at point: CGPoint, payload: PaneDragPayload.Content?) -> (target: PaneDropTarget, zone: CGRect?)? {
        guard let presentation = cellPresentation,
              let (id, cell) = presentation.frames.first(where: { $0.value.contains(point) }) else { return nil }
        let edge = PaneDropTarget.zone(at: point, in: cell)
        if case .pane(let moving)? = payload {
            guard moving != id else { return nil }
            let target: PaneDropTarget = edge.map { .move(id, $0) } ?? .swap(id)
            return (target, landingFrame(of: target, payload: payload))
        }
        let entry: PaneStackEntry? = if case .entry(let entry)? = payload { entry } else { nil }
        let chat = id == panes.mainLeafID && primary.view.frame.contains(point) ? shownChat : nil
        let chatTakes = chat.map { chat in entry.map(chat.canReference) ?? true } ?? false
        // The composer always takes a drop: it sits in the chat's bottom
        // quarter, which would otherwise split.
        if chatTakes, let chat, let bar = chat.composerDropArea(in: view), bar.contains(point) {
            return (.chat, primary.view.frame)
        }
        // Only pane entries make or fill panes (G1); a file from outside
        // never lights a pane zone.
        if entry != nil, let edge, canSplit {
            let target = PaneDropTarget.split(id, edge)
            return (target, landingFrame(of: target, payload: payload))
        }
        if chatTakes, edge == nil || entry == nil {
            return (.chat, primary.view.frame)
        }
        if entry != nil, edge == nil, splitLeaves[id] != nil {
            let target = PaneDropTarget.open(id)
            return (target, landingFrame(of: target, payload: payload))
        }
        return nil
    }

    /// Stands in for the leaf a split drop would make, which has no id until
    /// it lands.
    private static let droppedLeafID: PaneID = {
        guard let id = PaneID("dropping") else { preconditionFailure("dropping is not a pane id") }
        return id
    }()

    /// The frame the pane a drop fills will have once it lands: the drop's
    /// own layout change (`performDrop` and `gripPanned` make the same one
    /// through `ScenePanes`) applied to the cells and laid out as the host
    /// lays them out. A pane moved to a neighbour's edge first leaves its
    /// place, so it can take more than half the neighbour's cell. Nil when
    /// the pane would land out of sight, or for a chat drop.
    private func landingFrame(of target: PaneDropTarget, payload: PaneDragPayload.Content?) -> CGRect? {
        let cells = panes.cellLayout
        let landed: (cells: PaneLayout, leaf: PaneID)?
        switch (target, payload) {
        case (.split(let id, let edge), .entry(let entry)?):
            let leaf = PaneLeaf(id: Self.droppedLeafID, name: nil, stack: [entry], attachedTo: nil, origin: .split)
            landed = (try? cells.split(id, edge: edge, inserting: leaf)).map { ($0, leaf.id) }
        case (.open(let id), .entry(let entry)?):
            landed = (try? cells.showing(entry, in: id).focusing(id)).map { ($0, id) }
        case (.move(let id, let edge), .pane(let moving)?):
            landed = (try? cells.move(moving, to: id, edge: edge)).map { ($0, moving) }
        case (.swap(let id), .pane(let moving)?):
            landed = (try? cells.swap(moving, id)).map { ($0, moving) }
        default:
            return nil
        }
        guard let (next, leaf) = landed else { return nil }
        if let frame = shownPresentation(of: next).frames[leaf] { return frame }
        // A split pane that would go straight to overflow takes focus, as
        // `split(_:edge:showing:)` does.
        guard case .split = target, let focused = try? next.focusing(leaf) else { return nil }
        return shownPresentation(of: focused).frames[leaf]
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        payload(of: session) != nil
            || (session.localDragSession == nil && session.hasItemsConforming(toTypeIdentifiers: [UTType.item.identifier]))
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        guard let (target, zone) = dropTarget(at: session.location(in: view), payload: payload(of: session)) else {
            dropHighlight.isHidden = true
            return UIDropProposal(operation: .forbidden)
        }
        showDropZone(zone)
        switch target {
        case .move, .swap: return UIDropProposal(operation: .move)
        case .split, .open, .chat: return UIDropProposal(operation: .copy)
        }
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        dropHighlight.isHidden = true
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        dropHighlight.isHidden = true
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        dropHighlight.isHidden = true
        let payload = payload(of: session)
        guard let (target, _) = dropTarget(at: session.location(in: view), payload: payload) else { return }
        switch (target, payload) {
        case (.split(let id, let edge), .entry(let entry)?):
            split(id, edge: edge, showing: entry)
        case (.open(let id), .entry(let entry)?):
            panes.show(entry, in: id)
            focus(cell: id)
        case (.move(let id, let edge), .pane(let moving)?):
            move(moving, to: id, edge: edge)
        case (.swap(let id), .pane(let moving)?):
            swap(moving, with: id)
        case (.chat, .entry(let entry)?):
            shownChat?.reference(entry)
        case (.chat, nil):
            shownChat?.attachDropped(session.items.map(\.itemProvider))
        default:
            return
        }
    }

    /// A drop on a pane's edge: `entry` in a new pane on that side. As Split
    /// does, a pane that would go straight to overflow takes focus, so the
    /// drop shows what it made.
    func split(_ id: PaneID, edge: PaneEdge, showing entry: PaneStackEntry) {
        guard let made = panes.split(id, edge: edge, showing: entry) else { return }
        syncSplitLeaves()
        relayoutCells()
        if cellFrame(made) == nil { focus(cell: made) }
        announceLayoutChange()
    }

    func showDropZone(_ zone: CGRect?) {
        guard let zone else {
            dropHighlight.isHidden = true
            return
        }
        let accent = view.tintColor ?? .tintColor
        dropHighlight.backgroundColor = accent.withAlphaComponent(0.15)
        dropHighlight.layer.borderColor = accent.cgColor
        dropHighlight.frame = zone.insetBy(dx: 4, dy: 4)
        dropHighlight.isHidden = false
        view.bringSubviewToFront(dropHighlight)
    }
}

/// Dragging a grip moves its pane: the grip follows the finger, the zone
/// under it lights, and the release moves the pane to that edge or swaps it
/// with the pane in the middle. A pan rather than a drag session, because a
/// hold on the grip is its menu's (the button shows its menu on a long
/// press); the grip sits under the bar, so the pan never meets the window's
/// own drag. A zoomed pane, or the only one, does not move.
extension PaneHostController {
    @objc func gripPanned(_ pan: UIPanGestureRecognizer) {
        guard let grip = pan.view as? PaneGripView else { return }
        let movable = panes.zoomedCell == nil && panes.cellLayout.leaves.count > 1
        let point = pan.location(in: view)
        let target = movable ? dropTarget(at: point, payload: .pane(grip.leafID)) : nil
        switch pan.state {
        case .began, .changed:
            let moved = pan.translation(in: view)
            grip.transform = CGAffineTransform(translationX: moved.x, y: moved.y)
            showDropZone(target?.zone)
        case .ended:
            finishGripPan(grip)
            switch target?.target {
            case .move(let id, let edge)?: move(grip.leafID, to: id, edge: edge)
            case .swap(let id)?: swap(grip.leafID, with: id)
            default: break
            }
        default:
            finishGripPan(grip)
        }
    }

    private func finishGripPan(_ grip: PaneGripView) {
        dropHighlight.isHidden = true
        grip.transform = .identity
    }
}
