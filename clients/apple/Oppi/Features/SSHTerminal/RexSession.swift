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
        /// The OSC 7501 records Rex reports for the pane's program: what the Rex
        /// pill and panel say about its status, whatever the pane's own byte
        /// stream carried.
        var records: [SSHTerminalPaneRecord] = []

        /// The pane's program status, rolled up from `records`.
        var status: SessionStatusKind? { SSHTerminalPaneRecord.headline(of: records) }
    }

    /// The name a reporting pane's icon starts from: the terminal's title (a
    /// program puts its own mark first in it: `π - …`), else the `app` its
    /// status names, else Rex's label. Nil when none has anything in it.
    static func programName(title: String?, app: String?, label: String?) -> String? {
        [title, app, label].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// What a pane's icon starts from: nil for a pane whose program never
    /// reported status (a plain shell), else `programName` of its title, the
    /// `app` its status names (the root record's, else the first's), and Rex's
    /// label. The one rule behind every pane icon: the bar's switcher and the
    /// Terminal tab's pane rows.
    static func program(title: String?, records: [SSHTerminalPaneRecord], label: String?) -> String? {
        guard !records.isEmpty else { return nil }
        let app = records.first { $0.id.isEmpty }?.app ?? records.first?.app
        return programName(title: title, app: app, label: label)
    }

    var panes: [Pane]
    /// The pane on screen, or the one just asked for.
    var shown: String
    /// The panes whose data connection is open: the ones a swipe can slide in
    /// with their own screen. A pane whose lane closed is not here, and its
    /// screen is frozen where it stopped.
    var live: Set<String> = []
    /// The shown pane's window, one cell per pane.
    var minimap: [RexSessionLayout.Cell]

    var shownName: String { panes.first { $0.blockID == shown }?.name ?? "Terminal" }

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
                let changed = next != state
                if changed { state = next }
                // A pane list that moved (a pane opened, one closed, a window
                // reordered) moves the live window with it.
                if isWarming { keepLivePanes() }
                if changed { onShown?(next.shown) }
            }
        }
    }

    isolated deinit { reader?.cancel() }

    /// The session as of this moment. `state` follows it a main-actor turn
    /// later, so two swipes in a row read this to go two panes.
    var latest: RexSessionState { connection.state }

    /// The screen shows this session: its shown pane and the panes beside it in
    /// strip order stay live, so a swipe slides in a pane that already has its
    /// screen. Off screen, only the shown pane stays live — the terminal is
    /// still running, and nothing else may hold a stream.
    var isWarming = false {
        didSet {
            guard isWarming != oldValue else { return }
            keepLivePanes()
        }
    }

    /// The panes to keep streaming: the shown one and its neighbours, at most
    /// `RexSessionConnection.maximumLivePanes` (the strip's order, nearest
    /// first).
    func keepLivePanes() {
        var blocks = Set([latest.shown])
        if isWarming {
            var delta = 1
            while blocks.count < RexSessionConnection.maximumLivePanes, delta <= 2 {
                for step in [delta, -delta] {
                    if let pane = latest.neighbour(offsetBy: step) { blocks.insert(pane.blockID) }
                }
                delta += 1
            }
        }
        connection.keepLive(blocks)
    }

    /// A pane off screen whose stream cannot be read: its lane is dropped and
    /// the screen falls back to that pane's card if a swipe reaches it.
    func paneFailed(_ block: String) {
        connection.dropLane(block)
    }

    /// The session's state changed, with the pane it shows: the screen that shows
    /// this session puts that pane on the grid (`SSHTerminalGridView
    /// .presentShownPane`), so the pane that gets input is always the pane that is
    /// drawn. Every way of changing pane ends here — a swipe, a menu choice, a
    /// minimap cell, VoiceOver, a pane closing in Rex, a refusal recovering, a new
    /// pane — and so does a change that leaves the pane alone (a title, a status),
    /// which the grid ignores because the pane is already the one it paints.
    @ObservationIgnored var onShown: ((String) -> Void)?

    /// Which way Rex is reached: over Tailscale or the SSH bridge.
    var route: RexRoute { connection.route }

    /// The pane on screen, named: what a new connection reopens.
    var shownTarget: RexPaneTarget {
        RexPaneTarget(sessionID: sessionID, blockID: state.shown, label: state.shownName)
    }

    /// Shows `blockID`. Taking it for size and opening its stream is the
    /// connection's work, in order with every other request. False when the
    /// request was not taken: the pane is the one already asked for, or the
    /// session does not have it.
    @discardableResult
    func show(_ blockID: String) -> Bool {
        let accepted = connection.show(blockID)
        if accepted { keepLivePanes() }
        return accepted
    }

    /// Moves `delta` panes along the strip from the pane last asked for (so
    /// two quick swipes go two panes); false past either end.
    @discardableResult
    func step(_ delta: Int) -> Bool {
        let stepped = connection.step(delta)
        if stepped { keepLivePanes() }
        return stepped
    }

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
