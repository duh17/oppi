import CoreGraphics
import Foundation
import Observation

/// A Rex session's terminal panes as the pane strip and the minimap show them,
/// derived from `session.view`: the strip's order (windows in view order,
/// then each window's panes in layout order) and, per window, where each pane
/// sits in the tiled layer.
///
/// Only terminal blocks count: another kind of block (Rex's walkthrough) has
/// no stream this client can show.
struct RexSessionLayout: Equatable, Sendable {
    struct Pane: Equatable, Sendable {
        let blockID: String
        let windowID: String
        /// Rex's label for the block.
        let label: String?
    }

    /// A pane's place in its window; `rect` is a fraction of the window.
    struct Cell: Equatable, Sendable {
        let blockID: String
        let rect: CGRect
    }

    let panes: [Pane]
    /// The tiled layer's places per window.
    private let cells: [String: [Cell]]

    init(view: RexView) {
        var panes: [Pane] = []
        var cells: [String: [Cell]] = [:]
        for window in view.windows ?? [] {
            let layers = window.layers ?? []
            var labels: [String: String] = [:]
            var listed: [String] = []
            for block in layers.flatMap({ $0.blocks ?? [] }) {
                guard let id = block.blockID, block.creatorName == RexEvent.terminalCreator, !listed.contains(id) else { continue }
                labels[id] = block.label
                listed.append(id)
            }
            // The tiled layer first, then floating layers back to front, each
            // in layout order; a block no layout names (a tree this build
            // could not read) follows in the order the layer lists it.
            var ordered: [String] = []
            func place(_ id: String) {
                if listed.contains(id), !ordered.contains(id) { ordered.append(id) }
            }
            for layer in layers { layer.layout?.leaves.forEach { place($0.id) } }
            listed.forEach(place)
            panes += ordered.map { Pane(blockID: $0, windowID: window.windowID, label: labels[$0]) }
            let tiled = layers.first { $0.kind == "tiled" } ?? layers.first
            cells[window.windowID] = (tiled?.layout?.leaves ?? []).compactMap { leaf in
                guard listed.contains(leaf.id), leaf.rect.count == 4 else { return nil }
                return Cell(blockID: leaf.id, rect: CGRect(x: leaf.rect[0], y: leaf.rect[1], width: leaf.rect[2], height: leaf.rect[3]))
            }
        }
        self.panes = panes
        self.cells = cells
    }

    func contains(_ blockID: String) -> Bool { panes.contains { $0.blockID == blockID } }

    /// Where the panes of `blockID`'s window sit, for the minimap. Empty when
    /// the window has no tiled layout this build could read.
    func minimap(around blockID: String) -> [Cell] {
        guard let window = panes.first(where: { $0.blockID == blockID })?.windowID else { return [] }
        return cells[window] ?? []
    }

    /// Where the person lands when `blockID` goes away: the pane after it in
    /// strip order, else the one before, among `surviving`.
    static func neighbour(of blockID: String, in order: [String], surviving: Set<String>) -> String? {
        guard let index = order.firstIndex(of: blockID) else { return nil }
        let after = order[(index + 1)...]
        let before = order[..<index].reversed()
        return (Array(after) + Array(before)).first { surviving.contains($0) }
    }
}

/// What a Rex session terminal shows of its session: the strip, the minimap,
/// and which pane is on screen.
struct RexSessionState: Equatable, Sendable {
    struct Pane: Equatable, Sendable {
        let blockID: String
        /// What the strip and the switcher call the pane.
        let name: String
    }

    var panes: [Pane]
    /// The pane on screen, or the one just asked for.
    var shown: String
    /// The shown pane's window, one cell per pane.
    var minimap: [RexSessionLayout.Cell]

    var shownName: String { panes.first { $0.blockID == shown }?.name ?? "Terminal" }

    /// The strip is for a session with more than one pane.
    var showsStrip: Bool { panes.count > 1 }
    var showsMinimap: Bool { minimap.count > 1 }

    /// The pane `delta` places from the shown one in strip order, or nil past
    /// either end: a swipe past the last pane does nothing.
    func pane(offsetBy delta: Int) -> String? {
        guard let index = panes.firstIndex(where: { $0.blockID == shown }) else { return nil }
        let target = index + delta
        return panes.indices.contains(target) ? panes[target].blockID : nil
    }
}

/// The main-actor face of a Rex session terminal: what the pane strip, the
/// minimap, and the swipe read and ask for. The connection (`RexSessionConnection`)
/// owns the work, so a gesture, a tap, a minimap cell, and VoiceOver's custom
/// action all reach `show` the same way.
@MainActor @Observable
final class RexSessionModel {
    let sessionID: String
    private(set) var state: RexSessionState
    @ObservationIgnored private let connection: RexSessionConnection
    @ObservationIgnored private var reader: Task<Void, Never>?

    init(connection: RexSessionConnection) {
        sessionID = connection.sessionID
        state = connection.state
        self.connection = connection
        let updates = connection.updates
        reader = Task { [weak self] in
            for await next in updates {
                guard let self else { return }
                if next != state { state = next }
            }
        }
    }

    isolated deinit { reader?.cancel() }

    /// The pane on screen, named: what a new connection reopens.
    var shownTarget: RexPaneTarget {
        RexPaneTarget(sessionID: sessionID, blockID: state.shown, label: state.shownName)
    }

    /// Shows `blockID`. Taking it for size and opening its stream is the
    /// connection's work, in order with every other request.
    func show(_ blockID: String) { connection.show(blockID) }

    /// Moves `delta` panes along the strip from the pane last asked for (so
    /// two quick swipes go two panes); false past either end.
    @discardableResult
    func step(_ delta: Int) -> Bool { connection.step(delta) }
}
