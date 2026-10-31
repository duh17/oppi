import CoreGraphics
import Foundation
import Observation

/// A Rex session's terminal panes as the pane switcher and the minimap show them,
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
        /// Rex's label for the window, else `Window N` in view order.
        let windowName: String
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
        for (windowIndex, window) in (view.windows ?? []).enumerated() {
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
            let windowName = window.label ?? "Window \(windowIndex + 1)"
            panes += ordered.map { Pane(blockID: $0, windowID: window.windowID, windowName: windowName, label: labels[$0]) }
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

/// What a Rex session terminal shows of its session: the pane switcher, the
/// minimap, and which pane is on screen.
struct RexSessionState: Equatable, Sendable {
    struct Pane: Equatable, Sendable {
        let blockID: String
        /// What the pane switcher and the terminal switcher call the pane.
        let name: String
        /// The pane's window, once the session's view has been read.
        var windowID: String? = nil
        var windowName: String? = nil
        /// What the pane's program puts first, while it reports OSC 7501 status
        /// (`programName`); nil for a plain shell. The switcher's icon is drawn from it.
        var program: String? = nil
    }

    /// The name a reporting pane's icon starts from: the terminal's title (a
    /// program puts its own mark first in it: `π - …`), else the `app` its
    /// status names, else Rex's label. Nil when none has anything in it.
    static func programName(title: String?, app: String?, label: String?) -> String? {
        [title, app, label].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var panes: [Pane]
    /// The pane on screen, or the one just asked for.
    var shown: String
    /// The shown pane's window, one cell per pane.
    var minimap: [RexSessionLayout.Cell]

    var shownName: String { panes.first { $0.blockID == shown }?.name ?? "Terminal" }

    /// The bar's pane switcher is for a session with more than one pane. (The
    /// swipe is for every session: past the last pane it opens a new one.)
    var showsSwitcher: Bool { panes.count > 1 }
    var showsMinimap: Bool { minimap.count > 1 }
    /// Where the shown pane is in strip order.
    var shownIndex: Int? { panes.firstIndex { $0.blockID == shown } }
    /// The session has more than one window, so the switcher's menu sections them.
    var namesWindows: Bool { Set(panes.compactMap(\.windowID)).count > 1 }

    /// The pane `delta` places from the shown one in strip order, or nil past
    /// either end: past the last pane a swipe opens a new one (`RexSessionModel.newPane`).
    func neighbour(offsetBy delta: Int) -> Pane? {
        guard let index = shownIndex else { return nil }
        let target = index + delta
        return panes.indices.contains(target) ? panes[target] : nil
    }

    func pane(offsetBy delta: Int) -> String? { neighbour(offsetBy: delta)?.blockID }
}

/// The main-actor face of a Rex session terminal: what the bar's pane
/// switcher, the minimap, and the swipe read and ask for. The connection
/// (`RexSessionConnection`) owns the work, so a gesture, a menu choice, a
/// minimap cell, and VoiceOver's custom action all reach `show` the same way.
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

    /// The session as of this moment. `state` follows it a main-actor turn
    /// later, so two swipes in a row read this to go two panes.
    var latest: RexSessionState { connection.state }

    /// The pane on screen, named: what a new connection reopens.
    var shownTarget: RexPaneTarget {
        RexPaneTarget(sessionID: sessionID, blockID: state.shown, label: state.shownName)
    }

    /// Shows `blockID`. Taking it for size and opening its stream is the
    /// connection's work, in order with every other request. False when the
    /// request was not taken: the pane is the one already asked for, or the
    /// session does not have it.
    @discardableResult
    func show(_ blockID: String) -> Bool { connection.show(blockID) }

    /// Moves `delta` panes along the strip from the pane last asked for (so
    /// two quick swipes go two panes); false past either end.
    @discardableResult
    func step(_ delta: Int) -> Bool { connection.step(delta) }

    /// Opens a new pane after the one last asked for and shows it, through
    /// the same `show` as any switch. Returns the new pane's name. The session
    /// knows the pane (its view was read) before it is shown; it throws when
    /// Rex refuses or does not answer, and then the shown pane is unchanged.
    func newPane() async throws -> String {
        let block = try await connection.newPane()
        guard show(block) else {
            throw RexClientError.unreadable("a view without the new pane")
        }
        return latest.panes.first { $0.blockID == block }?.name ?? "Terminal"
    }
}
