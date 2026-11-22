import Foundation
import Observation

/// A chat the window's panes work with: where its reader is, for
/// restoration, and the files its text links to, which open beside it.
@MainActor
protocol PaneChat: AnyObject {
    var paneChatScroll: PaneChatScroll? { get }
    /// Opens `target`, linked from session `sessionId`'s text on server
    /// `serverId`, as this chat's reader beside it, as a file pill opens.
    /// False when this is not that chat, or its panels do not open beside it.
    func openLinkedFileBeside(_ target: WorkspaceLinkedFileNavTarget, sessionId: String, serverId: String) -> Bool
}

/// The window's pane tree (`PaneLayout`): its leaves, their weights, focus,
/// recency and zoom, and each leaf's route (`PaneStack`). Today a window
/// holds the main leaf and at most one attached companion beside it, which the
/// pane host (`PaneHostController`) draws and reports into the tree: it opens
/// and closes, takes a share of the width, zooms to the full window (by a
/// drag, or because it does not fit beside its leaf: build plan §1.3), and
/// takes focus.
///
/// This writes the tree when it settles (`PaneTreeStore`, 500 ms after the
/// last change, and at once when the scene goes to the background), and
/// restores it at launch. A chat's Files and Git panels and its extension
/// panels have links (`.files`, `.git`, `.panel`), so they are the
/// companions that restore; Outline, Context, Share, readers and a commit's
/// diff are `.local` and are not saved.
@MainActor @Observable
final class ScenePanes {
    /// The tree. Every leaf in `stacks` keeps its route there, not in `tree`;
    /// `layout(…)` writes each into the saved tree.
    private(set) var tree: PaneLayout {
        didSet {
            // Any other change of the zoom ends full screen.
            if let fullScreen, cellLayout.zoomed != fullScreen.cell { self.fullScreen = nil }
        }
    }
    /// Every leaf's route, the main leaf's included: its place (nil for a
    /// side leaf, whose bottom screen is its content) and the screens over it.
    private(set) var stacks: [PaneID: PaneStack] = [:]
    /// The main leaf: the one that cannot close, that iPhone shows, and that
    /// an outside chat link targets.
    private(set) var mainLeafID: PaneID
    /// The share of the width a companion rests at, by pairing
    /// (`PanePairing.key`): the last one the person settled on beside that
    /// screen, in this window or (restored) before relaunch.
    @ObservationIgnored private var rememberedShares: [String: Double] = [:]
    /// The shown companion's pairing.
    @ObservationIgnored private var companionPairing: String?
    @ObservationIgnored private var nextLeafNumber = 1
    /// Split leaves a relaunch brought back that have not mounted yet. A
    /// browser among them opens paused, its page loading only on a tap
    /// (build plan §1.8).
    @ObservationIgnored private var restoredLeaves: Set<PaneID> = []
    /// One sheet at a time across the window's panes.
    @ObservationIgnored let sheets = PaneSheetArbiter()
    /// Where the New Panes settings are read as a pane opens
    /// (`PaneHostController.openBeside`); a test's own defaults.
    @ObservationIgnored var preferences: UserDefaults = .standard

    @ObservationIgnored private var sceneIdentifier: String?
    @ObservationIgnored private var store = PaneTreeStore()
    @ObservationIgnored private var pending: PaneLayoutArchive?
    /// What a chat picks up as it shows. Observed, so a chat already on
    /// screen opens its panel too, and a save while it waits keeps it in the
    /// tree.
    private var handoff = ChatHandoff()
    @ObservationIgnored private let chats = NSHashTable<AnyObject>.weakObjects()
    @ObservationIgnored private var saving: Task<Void, Never>?
    /// What was last written: `.none` before the first write, `.some(nil)`
    /// once an empty tree removed the entry.
    @ObservationIgnored private var lastWritten: PaneLayoutArchive?? = .none
    @ObservationIgnored private weak var navigation: SceneNavigation?
    /// The main leaf's route a relaunch restored (and its entries resolved
    /// into their screens), until the person navigates away from it: showing
    /// it does not reveal a main leaf a restored zoom hides.
    @ObservationIgnored private var restoredMainStack: [WorkspaceStackRouteElement]?
    @ObservationIgnored private weak var coordinator: ConnectionCoordinator?
    /// Debounce before a settled change is written.
    private static let settleDelay: Duration = .milliseconds(500)
    /// How long restored screens must hold before the restore counts as
    /// survived (`PaneTreeStore.restoringKey(forScene:)`).
    private static let restoreSurvivalDelay: Duration = .seconds(5)

    /// Neutral stack kept on every leaf inside `tree` while its live route
    /// lives in `stacks`: `layout(…)` writes each leaf's saved entries from its
    /// route.
    private static let treeEntry = PaneStackEntry(serverId: "", route: .sessions(workspace: nil))

    init() {
        let id = Self.leafID(1)
        nextLeafNumber = 2
        mainLeafID = id
        stacks = [id: PaneStack(place: .allSessions)]
        tree = PaneLayout(single: PaneLeaf(id: id, name: nil, stack: [Self.treeEntry], attachedTo: nil, origin: .split))
    }

    private static func leafID(_ number: Int) -> PaneID {
        guard let id = PaneID("leaf-\(number)") else { preconditionFailure("leaf-\(number) is not a pane id") }
        return id
    }

    /// An id no leaf of the tree has.
    private func freshLeafID() -> PaneID {
        while true {
            let id = Self.leafID(nextLeafNumber)
            nextLeafNumber += 1
            if tree.leaf(id) == nil { return id }
        }
    }

    /// The handoff to chats that are not on screen yet: the panel a session's
    /// chat opens beside itself (the restored companion, or a panel link),
    /// and after a relaunch the restored chat's reading position and whether
    /// its panel had focus or filled the window. Each part is taken once, by
    /// the screen that applies it.
    private struct ChatHandoff {
        var panel: (sessionId: String, route: PaneRoute)?
        var scroll: PaneChatScroll?
        var panelFocused = false
        var panelZoomed = false
    }

    // MARK: Scene

    /// The scene connected: read its tree, to restore once launch has its
    /// stores (`restore`). A restore that the app did not survive last time
    /// (it crashed or was killed while mounting the screens) is not tried
    /// again: the trees go and the window starts fresh.
    func connect(scene id: String, store: PaneTreeStore = PaneTreeStore()) {
        sceneIdentifier = id
        self.store = store
        if store.lastRestoreWasInterrupted(scene: id) {
            store.dropAfterInterruptedRestore(scene: id)
        }
        pending = store.load(scene: id)
    }

    // MARK: The companion

    /// The attached leaf beside the main leaf, if one is open.
    var companionID: PaneID? {
        tree.leaves.first { $0.attachedTo == mainLeafID }?.id
    }

    /// The share of the width the shown companion rests at: the last one
    /// settled for its pairing, nil until one ever was (it then opens at its
    /// own ideal width). The tree's weight follows it, or the drawn share
    /// before it is known.
    var companionShare: Double? { companionPairing.flatMap { rememberedShares[$0] } }

    var isCompanionZoomed: Bool { companionID != nil && tree.zoomed == companionID }
    /// The companion's zoom is the fit rule's, not the person's: it ends
    /// when the window fits both leaves again, and is never saved.
    private(set) var companionZoomIsFit = false
    var isCompanionFocused: Bool { companionID != nil && tree.focus == companionID }

    /// The companion's share of the cell it shares with its main leaf, as
    /// the tree's weights hold it; nil without a companion.
    private var companionPairShare: Double? {
        guard let companionID, let path = tree.root.path(of: companionID), let index = path.last, index > 0,
              case .split(_, _, let weights)? = tree.root.node(at: Array(path.dropLast())) else { return nil }
        let pair = weights[index - 1] + weights[index]
        return pair > 0 ? weights[index] / pair : nil
    }

    /// `layout` with `leaf`'s weight at `share` of the cell it shares with the
    /// leaf before it (a companion, or a reader split off a pane), the pair
    /// keeping its total.
    private static func settingShare(_ share: Double, of leaf: PaneID, in layout: PaneLayout) -> PaneLayout? {
        guard let path = layout.root.path(of: leaf), let index = path.last, index > 0,
              case .split(_, _, var weights)? = layout.root.node(at: Array(path.dropLast())) else { return nil }
        let pair = weights[index - 1] + weights[index]
        weights[index - 1] = pair * (1 - share)
        weights[index] = pair * share
        return try? layout.setWeights(at: Array(path.dropLast()), weights)
    }

    /// A companion opened beside the main leaf, or the open one shows
    /// another panel (`route` is its link, nil when it has none) of
    /// `pairing`. Its weight is the pairing's remembered share, else
    /// `drawnShare` (read once the pairing is set, so it is the new panel's).
    /// Another pairing in an open companion takes its own share.
    func companionDidOpen(_ route: PaneStackEntry?, pairing: String, drawnShare: () -> Double? = { nil }) {
        let pairingChanged = companionPairing != pairing
        companionPairing = pairing
        let stack = [route ?? PaneStackEntry(serverId: "", route: .local(PaneLocalToken(raw: "panel")))]
        func share() -> Double? { companionShare ?? drawnShare().map { min(max($0, 0.05), 0.95) } }
        if let companionID {
            var next = tree
            if next.leaf(companionID)?.stack != stack {
                next.root = next.root.mapLeaves { leaf in
                    guard leaf.id == companionID else { return leaf }
                    var leaf = leaf
                    leaf.stack = stack
                    return leaf
                }
            }
            if pairingChanged, let share = share(), let shared = Self.settingShare(share, of: companionID, in: next) {
                next = shared
            }
            if next != tree { tree = next }
            return
        }
        let leaf = PaneLeaf(id: freshLeafID(), name: nil, stack: stack, attachedTo: mainLeafID, origin: .attached)
        guard var opened = try? tree.split(mainLeafID, axis: .row, inserting: leaf) else { return }
        if let share = share(), let next = Self.settingShare(share, of: leaf.id, in: opened) {
            opened = next
        }
        tree = opened
    }

    /// The companion closed (or left the window with its owner).
    func companionDidClose() {
        guard let companionID else { return }
        if let closed = try? tree.close(companionID) { tree = closed }
        companionZoomIsFit = false
    }

    /// The companion settled at `share` of the width beside its leaf.
    func setCompanionShare(_ share: Double) {
        let share = min(max(share, 0.05), 0.95)
        if let companionPairing { rememberedShares[companionPairing] = share }
        guard let companionID, let next = Self.settingShare(share, of: companionID, in: tree) else { return }
        if next != tree { tree = next }
    }

    /// The person reset the companion's width: its pairing forgets the share
    /// it settled on, and the companion's weight goes to `defaultShare`.
    func forgetCompanionShare(defaultShare: Double?) {
        if let companionPairing { rememberedShares[companionPairing] = nil }
        guard let defaultShare, let companionID,
              let next = Self.settingShare(min(max(defaultShare, 0.05), 0.95), of: companionID, in: tree) else { return }
        if next != tree { tree = next }
    }

    /// The companion fills the window (the tree's zoom of it), or gives its
    /// leaf its room back. `byFit`: the zoom is the fit rule's (build plan
    /// §1.3), not the person's choice.
    func setCompanionZoomed(_ zoomed: Bool, byFit: Bool = false) {
        guard let companionID else { return }
        let fit = zoomed && byFit
        if companionZoomIsFit != fit { companionZoomIsFit = fit }
        guard isCompanionZoomed != zoomed else { return }
        if fit {
            // The window's width did this, not the person: focus stays where
            // it was, and is there again when the zoom ends.
            tree.zoomed = companionID
            return
        }
        guard let next = try? tree.zoom(zoomed ? companionID : nil) else { return }
        tree = next
    }

    /// Pane focus moved to the companion, or back to the main leaf.
    func focusCompanion(_ onCompanion: Bool) {
        guard let target = onCompanion ? companionID : mainLeafID, tree.focus != target,
              let next = try? tree.focusing(target) else { return }
        tree = next
    }

    // MARK: Cells and split leaves

    /// The leaves Split made (or a restored tree held): every leaf but the
    /// main one and its companion, in tree order.
    var splitLeaves: [PaneLeaf] {
        tree.leaves.filter { $0.id != mainLeafID && $0.attachedTo == nil }
    }

    /// The tree the host lays out by the fit rule: one cell per leaf, the
    /// companion folded into its main leaf's cell, which draws it inside
    /// itself (`PaneHostController`). The person's full-window companion is
    /// its cell's zoom; the fit rule's stays inside the cell.
    var cellLayout: PaneLayout {
        guard let companionID, var cells = try? tree.close(companionID) else { return tree }
        if tree.focus == companionID {
            cells.focus = mainLeafID
            cells.recency.removeAll { $0 == mainLeafID }
            cells.recency.insert(mainLeafID, at: 0)
        }
        if tree.zoomed == companionID, !companionZoomIsFit { cells.zoomed = mainLeafID }
        return cells
    }

    /// Runs `change` on the cells and puts the companion back beside its
    /// main leaf, at the share, focus, zoom and recency it had. False when
    /// the change is refused.
    @discardableResult
    private func changeCells(_ change: (PaneLayout) throws -> PaneLayout) -> Bool {
        guard var next = try? change(cellLayout) else { return false }
        if let companionID, let companion = tree.leaf(companionID), next.leaf(mainLeafID) != nil,
           var withCompanion = try? next.split(mainLeafID, axis: .row, inserting: companion) {
            if let share = companionPairShare,
               let shared = Self.settingShare(share, of: companionID, in: withCompanion) {
                withCompanion = shared
            }
            withCompanion.recency = next.recency.flatMap { $0 == mainLeafID ? [$0, companionID] : [$0] }
            if tree.focus == companionID, next.focus == mainLeafID {
                withCompanion.focus = companionID
                withCompanion.recency.removeAll { $0 == companionID }
                withCompanion.recency.insert(companionID, at: 0)
            }
            if tree.zoomed == companionID, companionZoomIsFit || next.zoomed == mainLeafID {
                withCompanion.zoomed = companionID
            }
            next = withCompanion
        }
        if next != tree {
            tree = next
            forgetClosedLeaves()
        }
        return true
    }

    // MARK: Chats in the leaves

    /// The leaf whose route holds the chat of `sessionId` on `serverId`,
    /// under anything opened over it; nil when no leaf does. One session shows
    /// in one leaf (D7), so this is the leaf an open for it focuses.
    func leaf(showingChatOf sessionId: String, serverId: String) -> PaneID? {
        tree.leaves.first { leaf in
            stacks[leaf.id]?.elements.contains { element in
                guard let chat = element.chatSession else { return false }
                return chat.serverId == serverId && chat.sessionId == sessionId
            } ?? false
        }?.id
    }

    /// The leaf that shows a chat of `serverId` which is not `sessionId`'s,
    /// skipping `excluding`: one chat per server (Stage 4a), so this is the
    /// leaf a new chat of that server takes, in place of the chat there. A
    /// server's connection has one focused-session claim and one stream
    /// (§1.1); a second chat of it needs the session lane (Stage 4b).
    ///
    /// A page under a chat is the history that opened it, not a chat on screen:
    /// only a `.session` screen counts, and an entry whose session its server
    /// has not listed is a leaf state, not a live chat.
    func otherChatLeaf(ofServer serverId: String, not sessionId: String, excluding leaf: PaneID? = nil) -> PaneID? {
        tree.leaves.first { candidate in
            guard candidate.id != leaf else { return false }
            return stacks[candidate.id]?.elements.contains { element in
                guard case .session(let chat) = element else { return false }
                return chat.serverId == serverId && chat.sessionId != sessionId
            } ?? false
        }?.id
    }

    /// The leaf's route with the pages above the chat of `sessionId` on
    /// `serverId` taken off, so the chat itself shows; nil when the chat is its
    /// top already or no leaf holds it. The pages were opened from that chat (a
    /// reader, a panel), so the leaf comes back to the chat rather than a second
    /// copy of it. The caller writes the route: the main leaf's through its one
    /// owner.
    func stackShowingChat(_ sessionId: String, serverId: String) -> (leaf: PaneID, stack: PaneStack)? {
        guard let id = leaf(showingChatOf: sessionId, serverId: serverId),
              var stack = stacks[id], let index = stack.stack.lastIndex(where: { element in
                  guard let chat = element.chatSession else { return false }
                  return chat.serverId == serverId && chat.sessionId == sessionId
              }), index < stack.stack.count - 1 else { return nil }
        stack.stack.removeSubrange((index + 1)...)
        return (id, stack)
    }

    /// `leaf`'s route with `chat` in place of the chat of `chat.serverId` it
    /// holds, keeping everything below that chat (the main leaf's place and any
    /// screens under it, a side leaf's list) and dropping the old chat and any
    /// pages pushed above it. When `leaf` holds no live chat of that server,
    /// pushes `chat` onto its existing stack.
    func stackReplacingChat(_ chat: WorkspaceSessionNavTarget, in leaf: PaneID) -> PaneStack {
        var stack = stacks[leaf] ?? PaneStack(place: leaf == mainLeafID ? .allSessions : nil)
        if let index = stack.stack.lastIndex(where: { element in
            if case .session(let shown) = element { return shown.serverId == chat.serverId }
            return false
        }) {
            stack.stack.removeSubrange(index...)
        }
        stack.stack.append(.session(chat))
        return stack
    }

    /// Whether another leaf (`!= leaf`) already holds a live `.session` chat of
    /// `serverId` (same session or another).
    private func anotherLeafHoldsLiveChat(ofServer serverId: String, excluding leaf: PaneID) -> Bool {
        tree.leaves.contains { candidate in
            guard candidate.id != leaf else { return false }
            return stacks[candidate.id]?.elements.contains { element in
                if case .session(let chat) = element { return chat.serverId == serverId }
                return false
            } ?? false
        }
    }

    /// A leaf the window no longer has keeps no route and no list search.
    private func forgetClosedLeaves() {
        let live = Set(tree.leaves.map(\.id))
        for id in stacks.keys where !live.contains(id) {
            stacks[id] = nil
            navigation?.clearSearch(in: id)
        }
    }

    private func makeLeaf() -> PaneLeaf {
        PaneLeaf(id: freshLeafID(), name: nil, stack: [Self.treeEntry], attachedTo: nil, origin: .split)
    }

    /// Splits `id` along `axis`. The new leaf copies a Files, Git, file or
    /// terminal pane; anything else (a chat, a session list, the launcher)
    /// gets the launcher. A chat's split opens the launcher because its own
    /// chat cannot show twice and another server's chat is a row's open (the
    /// launcher's Sessions list opens its rows in the leaf).
    /// Returns the new leaf's id; focus stays where it was.
    @discardableResult
    func split(_ id: PaneID, axis: PaneAxis) -> PaneID? {
        guard tree.leaves.count < PaneLayout.maximumLeaves else { return nil }
        let leaf = makeLeaf()
        guard changeCells({ try $0.split(id, axis: axis, inserting: leaf) }) else { return nil }
        stacks[leaf.id] = PaneStack(stack: [splitRoute(copying: id)])
        return leaf.id
    }

    /// Opens `route` in a new leaf at `edge` of `id` (a drop on a pane's edge).
    /// `share` is the new leaf's part of the cell it splits off a trailing
    /// edge (a reader at its reading width); nil halves it. Returns the new
    /// leaf's id; focus stays where it was.
    @discardableResult
    func split(_ id: PaneID, edge: PaneEdge, showing route: WorkspaceStackRouteElement, share: Double? = nil) -> PaneID? {
        guard tree.leaves.count < PaneLayout.maximumLeaves else { return nil }
        let leaf = makeLeaf()
        let opened = changeCells { cells in
            let split = try cells.split(id, edge: edge, inserting: leaf)
            guard let share, edge.isTrailing else { return split }
            return Self.settingShare(min(max(share, 0.05), 0.95), of: leaf.id, in: split) ?? split
        }
        guard opened else { return nil }
        stacks[leaf.id] = PaneStack(stack: [route])
        return leaf.id
    }

    /// The screen an item opened as, where its entry cannot say all of it: a
    /// file opened from a chat keeps that chat's lock, and a terminal has a
    /// screen only its opener made. A leaf builds its screen from this route.
    func route(for entry: PaneStackEntry) -> WorkspaceStackRouteElement {
        guard let coordinator, let element = PaneEntries.element(for: entry, coordinator: coordinator) else {
            return .entry(entry)
        }
        return element
    }

    /// Open in New Pane: `route` in a new leaf at `edge` of `id` (`.right` or
    /// `.bottom`), focused, filling the window when `full` (the fit rule: it
    /// cannot sit beside it). Undo takes it back. Returns the new leaf's id.
    @discardableResult
    func newPane(_ route: WorkspaceStackRouteElement, at edge: PaneEdge = .right, ofCell id: PaneID, full: Bool) -> PaneID? {
        guard edge.isTrailing, tree.leaves.count < PaneLayout.maximumLeaves else { return nil }
        let leaf = makeLeaf()
        undoable(Self.openAction) { cells in
            let opened = try cells.split(id, axis: edge.axis, inserting: leaf).focusing(leaf.id)
            return full ? try opened.zoom(leaf.id) : opened
        }
        guard tree.leaf(leaf.id) != nil else { return nil }
        stacks[leaf.id] = PaneStack(stack: [route])
        return leaf.id
    }

    /// Open in Pane: a split leaf shows `route` in place of what it showed,
    /// focused. Undo brings back what it showed.
    func replace(_ route: WorkspaceStackRouteElement, inCell id: PaneID) {
        guard id != mainLeafID, tree.leaf(id)?.attachedTo == nil else { return }
        let before = cellLayout
        let previous = stacks[id]
        let next = PaneStack(stack: [route])
        guard changeCells({ try $0.focusing(id) }) else { return }
        stacks[id] = next
        if cellLayout != before || previous != next {
            recordUndo(Self.openInPaneAction, cells: before, routes: previous.map { [id: $0] } ?? [:])
        }
    }

    /// What a split of `id` shows: its Files, Git or file, the workspace's own
    /// terminal for a terminal (not a second screen on the shell its opener
    /// made), else the launcher.
    private func splitRoute(copying id: PaneID) -> WorkspaceStackRouteElement {
        guard let top = stacks[id]?.top else { return .entry(launcher(for: id)) }
        switch top.contentKind {
        case .file?, .folder?, .git?:
            return top
        case .terminal?:
            // A launcher's Terminal already names the workspace in its token.
            if case .entry = top { return top }
            let context = context(of: id)
            if let workspaceId = context.workspaceId {
                let token = PaneLocalScreen.terminal(workspaceId: workspaceId).token
                return .entry(PaneStackEntry(serverId: context.serverId, route: .local(token)))
            }
        default:
            break
        }
        return .entry(launcher(for: id))
    }

    /// The launcher (Sessions, Files, Terminal) for the workspace `id` shows.
    func launcher(for id: PaneID) -> PaneStackEntry {
        let context = context(of: id)
        return PaneStackEntry(serverId: context.serverId, route: .local(PaneLocalScreen.launcher(workspaceId: context.workspaceId).token))
    }

    func setStack(_ stack: PaneStack, for id: PaneID) { stacks[id] = stack }

    func stack(of id: PaneID) -> PaneStack? { stacks[id] }

    /// The top entry of `id`, as its grip's title and menu read it: a screen
    /// no link names is a `.local` one.
    func topEntry(of id: PaneID) -> PaneStackEntry {
        let top = stacks[id].flatMap { PaneEntries.entries(of: $0, rootServerId: rootServerId).last }
            ?? tree.leaf(id)?.stack.last
        return top ?? PaneStackEntry(serverId: rootServerId, route: .sessions(workspace: nil))
    }

    private var rootServerId: String { coordinator.flatMap { navigation?.activeServerId(in: $0) } ?? "" }

    /// The server and workspace a leaf works in: its top screen's, else the
    /// nearest one below it that names a workspace.
    func context(of id: PaneID) -> (serverId: String, workspaceId: String?) {
        let top = topEntry(of: id)
        if let stack = stacks[id],
           let found = stack.elements.reversed().lazy.compactMap({ self.workspace(of: $0) }).first {
            return found
        }
        if let found = tree.leaf(id)?.stack.reversed().lazy.compactMap({ entry in
            self.workspaceId(of: entry).map { (entry.serverId, $0) }
        }).first { return found }
        return (top.serverId, nil)
    }

    /// The server and workspace `element` names. A terminal's route names the
    /// server its opener knew, which a split opened from another server's
    /// chat reads instead of the leaf's.
    private func workspace(
        of element: WorkspaceStackRouteElement
    ) -> (serverId: String, workspaceId: String?)? {
        switch element {
        case .session(let target):
            (target.workspaceId ?? sessionWorkspaceId(target.sessionId, serverId: target.serverId)).map { (target.serverId, $0) }
        case .workspace(let target), .workspaceConfiguration(let target):
            (target.serverId, target.workspace.id)
        case .linkedFile(let target):
            (target.serverId, target.workspaceId)
        case .fileBrowser(let target):
            if case .workspace(let workspaceId, _) = target.scope { (target.serverId, workspaceId) } else { nil }
        case .entry(let entry):
            workspaceId(of: entry).map { (entry.serverId, $0) }
        case .terminal(let target):
            // The opener's own server, not the leaf's: a terminal beside a
            // chat of another server works in that server's workspace.
            target.workspace.map { (serverId: $0.serverId, workspaceId: $0.workspaceId) }
        default:
            nil
        }
    }

    private func sessionWorkspaceId(_ sessionId: String, serverId: String) -> String? {
        coordinator?.connection(for: serverId)?.sessionStore.session(id: sessionId)?.workspaceId
    }

    private func workspaceId(of entry: PaneStackEntry) -> String? {
        switch entry.route {
        case .sessions(let id): id
        case .files(let id, _), .git(let id, _), .commit(let id, _), .file(.workspace(let id, _), _, _): id
        case .session(let id), .file(.session(let id), _, _), .panel(let id, _), .read(let id, _):
            sessionWorkspaceId(id, serverId: entry.serverId)
        case .local(let token): PaneLocalScreen(token)?.workspaceId
        case .thread, .file(.host, _, _), .hostFiles, .browser, .godot, .unsupported: nil
        }
    }

    /// Whether `id` came back with a relaunch and mounts for the first time;
    /// true once.
    func takeRestored(_ id: PaneID) -> Bool {
        restoredLeaves.remove(id) != nil
    }

    /// A split leaf shows `route` in place of what it showed.
    func show(_ route: WorkspaceStackRouteElement, in id: PaneID) {
        guard id != mainLeafID, tree.leaf(id)?.attachedTo == nil else { return }
        setStack(PaneStack(stack: [route]), for: id)
    }

    /// A split leaf shows `entry`'s screen in place of what it showed.
    func show(_ entry: PaneStackEntry, in id: PaneID) {
        show(route(for: entry), in: id)
    }

    /// The entry's content can open: its screen takes that entry's place in the
    /// leaf's route, and the pages over and under it stay.
    ///
    /// One chat per server (Stage 4a): when a restored placeholder chat entry
    /// resolves in a side leaf while another leaf already holds a live chat of
    /// that server, the side leaf gives up the entry (and any pages pushed
    /// above it, up to a later chat), closing when nothing stays under it.
    func replace(_ entry: PaneStackEntry, with element: WorkspaceStackRouteElement, in id: PaneID) {
        guard var stack = stacks[id], let index = stack.stack.lastIndex(of: .entry(entry)) else { return }
        guard stack.stack[index] != element else { return }
        if case .session(let chat) = element,
           anotherLeafHoldsLiveChat(ofServer: chat.serverId, excluding: id) {
            var end = index + 1
            while end < stack.stack.count, stack.stack[end].chatSession == nil { end += 1 }
            stack.stack.removeSubrange(index..<end)
            guard !stack.stack.isEmpty || id == mainLeafID else {
                close(id, undoable: false)
                return
            }
            setStack(stack, for: id)
            return
        }
        stack.stack[index] = element
        setStack(stack, for: id)
    }

    /// Close Pane on `entry`: a page over the leaf's root pops, and its root
    /// closes the pane.
    func close(_ entry: PaneStackEntry, in id: PaneID) {
        guard var stack = stacks[id], stack.stack.count > 1, stack.stack.last == .entry(entry) else {
            close(id)
            return
        }
        stack.stack.removeLast()
        setStack(stack, for: id)
    }

    /// A side leaf's stack went back to `depth` screens: Back on a routed page.
    func pop(_ id: PaneID, to depth: Int) {
        guard id != mainLeafID, var stack = stacks[id] else { return }
        stack.pop(toDepth: depth, split: true)
        guard stack != stacks[id] else { return }
        stacks[id] = stack
    }

    /// Closes a split leaf. The main leaf holds the window's route and does
    /// not close. Pass `undoable: false` for invariant repairs (such as
    /// dropping a duplicate same-server chat) that Undo must not resurrect.
    func close(_ id: PaneID, undoable isUndoable: Bool = true) {
        guard id != mainLeafID, tree.leaf(id)?.attachedTo == nil else { return }
        if isUndoable {
            undoable(Self.closeAction, restoring: stacks[id].map { [id: $0] } ?? [:]) { try $0.close(id) }
        } else {
            changeCells { try $0.close(id) }
        }
    }

    /// Every split leaf closes; the main leaf and its companion stay.
    func resetPanes() {
        let closing = cellLayout.leaves.map(\.id).filter { $0 != mainLeafID }
        undoable(Self.resetAction, restoring: closing.reduce(into: [:]) { routes, id in routes[id] = stacks[id] }) { cells in
            try closing.reduce(cells) { try $0.close($1) }
        }
    }

    // MARK: Undo

    /// A change Undo can take back: its name ("Close Pane") and the cells and
    /// every leaf's route before it. The chat's panel is not part of it: Undo
    /// leaves the panel as it is now (build plan §1.7).
    struct UndoStep: Equatable {
        let action: String
        let cells: PaneLayout
        /// The routes of the leaves the step closed or replaced. A leaf it left
        /// alone keeps whatever the person navigated to meanwhile, the main
        /// leaf's included.
        let routes: [PaneID: PaneStack]
    }

    static let undoDepth = 5
    static let closeAction = String(localized: "Close Pane")
    static let moveAction = String(localized: "Move Pane")
    static let resetAction = String(localized: "Reset Panes")
    static let openAction = String(localized: "Open in New Pane")
    static let openInPaneAction = String(localized: "Open in Pane")

    /// Newest last, at most `undoDepth`. Not saved: a relaunch starts empty.
    private(set) var undoSteps: [UndoStep] = []

    /// What Undo would take back now ("Close Pane"), nil with nothing to undo.
    var undoAction: String? { undoSteps.last?.action }

    private func recordUndo(_ action: String, cells: PaneLayout, routes: [PaneID: PaneStack] = [:]) {
        undoSteps.append(UndoStep(action: action, cells: cells, routes: routes))
        if undoSteps.count > Self.undoDepth { undoSteps.removeFirst() }
    }

    /// Runs `change` on the cells and keeps the cells and routes before it
    /// for Undo, when it changed anything.
    private func undoable(
        _ action: String,
        restoring routes: [PaneID: PaneStack] = [:],
        _ change: (PaneLayout) throws -> PaneLayout
    ) {
        let before = cellLayout
        guard changeCells(change), cellLayout != before else { return }
        recordUndo(action, cells: before, routes: routes)
    }

    /// Puts the cells back as they were before the newest step, and the routes
    /// of the leaves it closed or replaced. A pane it brings back shows what it
    /// showed, from its route, not its scroll position. False with nothing to
    /// undo.
    @discardableResult
    func undo() -> Bool {
        guard let step = undoSteps.popLast() else { return false }
        guard changeCells({ _ in step.cells }) else { return false }
        for (id, route) in step.routes where id != mainLeafID { stacks[id] = route }
        return true
    }

    /// Zooms a cell to the whole window; nil restores. A zoom of the main
    /// leaf takes its companion with it.
    func zoom(_ id: PaneID?) {
        changeCells { try $0.zoom(id) }
    }

    /// The cell that fills the window by the person's choice, if any.
    var zoomedCell: PaneID? { cellLayout.zoomed }

    /// A cell playing full screen: the tree's zoom of it, with the window's
    /// chrome put away (the status bar, home indicator, sidebar, the cell's
    /// bar and grip). Not saved; any other change of the zoom ends it.
    private var fullScreen: (cell: PaneID, zoomedBefore: PaneID?, focusBefore: PaneID)?

    /// The cell playing full screen now.
    var fullScreenCell: PaneID? { fullScreen?.cell }

    /// Zooms `id` full screen. False when it cannot zoom (it is the only cell).
    @discardableResult
    func enterFullScreen(_ id: PaneID) -> Bool {
        let before = cellLayout
        guard changeCells({ try $0.zoom(id) }), cellLayout.zoomed == id else { return false }
        fullScreen = (id, before.zoomed, before.focus)
        return true
    }

    /// Ends full screen: the zoom and focus go back to what they were, so the
    /// split shows exactly as it did.
    func exitFullScreen() {
        guard let fullScreen else { return }
        self.fullScreen = nil
        changeCells { cells in
            var restored = try cells.zoom(fullScreen.zoomedBefore)
            if restored.leaf(fullScreen.focusBefore) != nil, fullScreen.zoomedBefore == nil || fullScreen.zoomedBefore == fullScreen.focusBefore {
                restored = try restored.focusing(fullScreen.focusBefore)
            }
            return restored
        }
    }

    /// Whether the main leaf's route about to show is the person's
    /// navigation, not the route a relaunch restored. The first change away
    /// from the restored route ends the restore's exemption.
    func mainStackNavigated() -> Bool {
        guard let restored = restoredMainStack else { return true }
        guard stacks[mainLeafID]?.elements != restored else { return false }
        restoredMainStack = nil
        return true
    }

    /// A restored entry resolved into its screen in place: still the
    /// restore's route, not navigation.
    func mainEntryResolved(from before: [WorkspaceStackRouteElement], to after: [WorkspaceStackRouteElement]) {
        if restoredMainStack == before { restoredMainStack = after }
    }

    /// Collapses a cell to its strip; focus moves to the most recent open
    /// cell. False when it cannot (the window's only open cell).
    @discardableResult
    func collapse(_ id: PaneID) -> Bool {
        changeCells { try $0.collapse(id) }
    }

    /// Gives a collapsed cell back the share it had.
    func expand(_ id: PaneID) {
        changeCells { try $0.expand(id) }
    }

    /// The cells collapsed to strips.
    var collapsedCells: Set<PaneID> { Set(cellLayout.collapsed.keys) }

    /// Moves `id` to `edge` of `target`.
    func move(_ id: PaneID, to target: PaneID, edge: PaneEdge) {
        undoable(Self.moveAction) { try $0.move(id, to: target, edge: edge) }
    }

    /// Trades the places of two cells; sizes stay with the places.
    func swap(_ first: PaneID, _ second: PaneID) {
        undoable(Self.moveAction) { try $0.swap(first, second) }
    }

    /// Focuses a cell: the main leaf, or a split leaf.
    func focus(_ id: PaneID) {
        guard tree.focus != id else { return }
        if id == mainLeafID, tree.focus == companionID { return }
        changeCells { try $0.focusing(id) }
    }

    /// Sets the weights of the cells' split at `path`.
    func setCellWeights(at path: [Int], _ weights: [Double]) {
        changeCells { try $0.setWeights(at: path, weights) }
    }

    /// Equal shares for every split's children, or only the one at `path`.
    func equaliseCells(at path: [Int]? = nil) {
        changeCells { cells in
            var cells = cells
            cells.root = Self.equalised(cells.root, at: path, here: [])
            return cells
        }
    }

    private static func equalised(_ node: PaneNode, at target: [Int]?, here: [Int]) -> PaneNode {
        guard case .split(let axis, let children, let weights) = node else { return node }
        let equal = target == nil || target == here
        return .split(
            axis: axis,
            children: children.enumerated().map { equalised($0.element, at: target, here: here + [$0.offset]) },
            weights: equal ? Array(repeating: 1 / Double(children.count), count: children.count) : weights
        )
    }

    func register(chat: PaneChat) {
        chats.add(chat)
    }

    /// A file linked from a chat's text opens beside that chat, when it is on
    /// screen with room for its panels. False leaves the open to the caller.
    func openLinkedFileBesideChat(_ target: WorkspaceLinkedFileNavTarget, sessionId: String, serverId: String) -> Bool {
        chats.allObjects.contains {
            ($0 as? PaneChat)?.openLinkedFileBeside(target, sessionId: sessionId, serverId: serverId) == true
        }
    }

    /// A panel link: the session's chat opens `route` beside itself when it
    /// shows (`pendingPanel(for:)`), replacing one still waiting.
    func openPanel(_ route: PaneRoute, beside sessionId: String) {
        handoff.panel = (sessionId, route)
    }

    /// The panel waiting for this session's chat; reading it observes it.
    func pendingPanel(for sessionId: String) -> PaneRoute? {
        guard let panel = handoff.panel, panel.sessionId == sessionId else { return nil }
        return panel.route
    }

    /// The panel waiting for this session's chat, once.
    func takePendingPanel(for sessionId: String) -> PaneRoute? {
        guard let route = pendingPanel(for: sessionId) else { return nil }
        handoff.panel = nil
        return route
    }

    /// The reading position a restored chat starts at, once.
    func takeRestoredScroll(for sessionId: String) -> PaneChatScroll? {
        guard let scroll = handoff.scroll, scroll.sessionId == sessionId else { return nil }
        handoff.scroll = nil
        return scroll
    }

    /// A restored entry was closed before its chat showed: the chat's panel
    /// and position must not open when the person opens it later by hand.
    func dropRestoredHandoffs() {
        handoff = ChatHandoff()
    }

    /// Whether a restored companion takes focus and fills the window as it
    /// mounts, once.
    func takeRestoredCompanionState() -> (focused: Bool, zoomed: Bool) {
        defer {
            handoff.panelFocused = false
            handoff.panelZoomed = false
        }
        return (handoff.panelFocused, handoff.panelZoomed)
    }

    // MARK: Snapshot

    /// The window's tree now, every leaf's stack as it is saved from its route
    /// (`PaneEntries.entries(of:rootServerId:)`). A companion is kept only
    /// beside a chat, the one screen whose panels have links. A panel still
    /// waiting for its chat (the chat is a leaf state until its server
    /// connects) stays in the tree, so a save meanwhile does not lose it.
    func layout(rootServerId: String) -> PaneLayout {
        var layout = tree
        layout.root = layout.root.mapLeaves { leaf in
            guard let stack = stacks[leaf.id] else { return leaf }
            var leaf = leaf
            leaf.stack = PaneEntries.entries(of: stack, rootServerId: rootServerId)
            return leaf
        }
        guard let top = layout.leaf(mainLeafID)?.stack.last, case .session(let sessionId) = top.route else {
            if let companionID, let closed = try? layout.close(companionID) { return closed }
            return layout
        }
        guard companionID == nil, let waiting = pendingPanel(for: sessionId) else { return layout }
        let side = PaneLeaf(
            id: (0...).lazy.map(Self.leafID).first { layout.leaf($0) == nil } ?? Self.leafID(0),
            name: nil,
            stack: [PaneStackEntry(serverId: top.serverId, route: waiting)],
            attachedTo: mainLeafID,
            origin: .attached
        )
        guard var withPanel = try? layout.split(mainLeafID, axis: .row, inserting: side) else { return layout }
        if let share = rememberedShares[PanePairing.restoredChatPanelKey(waiting)],
           let next = Self.settingShare(share, of: side.id, in: withPanel) {
            withPanel = next
        }
        if handoff.panelFocused, let focused = try? withPanel.focusing(side.id) { withPanel = focused }
        if handoff.panelZoomed { withPanel.zoomed = side.id }
        return withPanel
    }

    // MARK: Restore

    /// Applies the tree read at `connect`: the main leaf's route, then the
    /// chat's panel, width share, focus, zoom and reading position, which
    /// the chat takes as it appears. With App Lock on, this waits for unlock
    /// so nothing mounts behind the cover. Then the window's changes are
    /// saved. `applying: false` drops the saved tree (nothing paired to show
    /// it on).
    func restore(
        navigation: SceneNavigation,
        coordinator: ConnectionCoordinator,
        applying: Bool = true,
        appLock: AppLockService = .shared
    ) {
        guard saving == nil else { return }
        self.navigation = navigation
        self.coordinator = coordinator
        guard applying, let archive = pending else {
            pending = nil
            startSaving()
            return
        }
        pending = nil
        guard appLock.isLocked else {
            apply(archive, navigation: navigation, coordinator: coordinator)
            startSaving()
            return
        }
        Task { [weak self] in
            for await locked in Observations({ appLock.isLocked }) where !locked { break }
            guard let self else { return }
            // An open that waited for the same unlock (a notification, a
            // link) already chose the screen; it wins over the saved tree.
            if navigation.workspaceStackRouteElements.isEmpty {
                self.apply(archive, navigation: navigation, coordinator: coordinator)
            }
            self.startSaving()
        }
    }

    private func apply(_ archive: PaneLayoutArchive, navigation: SceneNavigation, coordinator: ConnectionCoordinator) {
        markRestoringUntilSurvived()
        rememberedShares = archive.companionShares
        let layout = archive.layout
        // The main leaf keeps the id a window's first leaf gets; split leaves
        // get later ones. An older tree names it only by being first.
        let unattached = layout.leaves.filter { $0.attachedTo == nil }
        guard let main = unattached.first(where: { $0.id == Self.leafID(1) }) ?? unattached.first else { return }
        let place: NavigationPlace = if case .workspace(let target)? = main.stack.first.flatMap({
            PaneEntries.element(for: $0, coordinator: coordinator)
        }) { .sessions(target) } else { .allSessions }
        var routes: [PaneID: PaneStack] = [:]
        for leaf in unattached {
            let elements = leaf.stack.map { restoredElement($0, coordinator: coordinator) }
            routes[leaf.id] = leaf.id == main.id
                ? PaneStack(place: place, stack: Array(elements.dropFirst()))
                : PaneStack(stack: elements)
        }
        let previousMain = stacks[mainLeafID]
        mainLeafID = main.id
        // The main leaf's restored route goes in through `mainPaneRoute`, so
        // its side effects (the sidebar choice, an AVKit overlay) follow; the
        // getter reads `stacks`, which holds what the window had until then.
        stacks = previousMain.map { [main.id: $0] } ?? [:]
        // The split leaves come back where they were; the companion comes
        // back when its chat shows (`handoff.panel`), so it leaves the tree,
        // and every leaf's live route lives in `stacks`, not `tree`.
        var restored = layout
        for leaf in layout.leaves where leaf.attachedTo != nil {
            if restored.leaf(leaf.id) != nil, let closed = try? restored.close(leaf.id) { restored = closed }
        }
        restored.root = restored.root.mapLeaves { leaf in
            var leaf = leaf
            leaf.stack = [Self.treeEntry]
            return leaf
        }
        restored.zoomed = restored.zoomed.flatMap { layout.leaf($0)?.attachedTo == nil ? $0 : nil }
        tree = restored
        restoredLeaves = Set(restored.leaves.map(\.id)).subtracting([main.id])
        let route = routes[main.id] ?? PaneStack(place: place)
        // The main leaf's restored route goes in through its owner, so its side
        // effects (the sidebar choice, an AVKit overlay) follow; the side leaves'
        // routes join it in one write.
        navigation.restoreMainRoute(route)
        restoredMainStack = route.elements
        stacks.merge(routes.filter { $0.key != main.id }) { _, new in new }
        // A tree an older build wrote can hold two chats of one server.
        navigation.repairChatsPerServer()

        guard case .session(let sessionId)? = main.stack.last?.route else { return }
        handoff.scroll = archive.chatScroll[main.id].flatMap { $0.sessionId == sessionId ? $0 : nil }
        guard let companion = layout.leaves.first(where: { $0.attachedTo == main.id }),
              let route = companion.stack.last?.route else { return }
        // The open panel's weight is the share it rests at.
        if let path = layout.root.path(of: companion.id), let index = path.last, index > 0,
           case .split(_, _, let weights)? = layout.root.node(at: Array(path.dropLast())) {
            rememberedShares[PanePairing.restoredChatPanelKey(route)] = weights[index] / (weights[index - 1] + weights[index])
        }
        handoff.panel = (sessionId, route)
        handoff.panelFocused = layout.focus == companion.id
        handoff.panelZoomed = layout.zoomed == companion.id
    }

    /// A saved entry as the route it restores to: its own screen when its
    /// content is there, else its leaf state, which opens the content when it
    /// can.
    private func restoredElement(_ entry: PaneStackEntry, coordinator: ConnectionCoordinator) -> WorkspaceStackRouteElement {
        guard PaneEntries.state(of: entry, coordinator: coordinator) == .content,
              let element = PaneEntries.element(for: entry, coordinator: coordinator) else { return .entry(entry) }
        return element
    }

    /// Marks the restore under way, and clears the mark once the screens
    /// have held a while; `flush` clears it too.
    private func markRestoringUntilSurvived() {
        guard let sceneIdentifier else { return }
        store.markRestoring(true, scene: sceneIdentifier)
        Task { [weak self] in
            try? await Task.sleep(for: Self.restoreSurvivalDelay)
            self?.store.markRestoring(false, scene: sceneIdentifier)
        }
    }

    // MARK: Saving

    private func startSaving() {
        guard saving == nil else { return }
        saving = Task { [weak self] in
            var debounce: Task<Void, Never>?
            for await archive in Observations({ [weak self] in self?.currentArchive() }) {
                debounce?.cancel()
                guard let self else { continue }
                debounce = Task { [weak self] in
                    try? await Task.sleep(for: Self.settleDelay)
                    guard !Task.isCancelled else { return }
                    self?.write(archive)
                }
            }
        }
    }

    /// Writes the tree now (the scene is going to the background), and
    /// counts a restore still under way as survived.
    func flush() {
        if let sceneIdentifier { store.markRestoring(false, scene: sceneIdentifier) }
        guard saving != nil else { return }
        write(currentArchive(), force: true)
    }

    private func write(_ archive: PaneLayoutArchive??, force: Bool = false) {
        guard let sceneIdentifier, let archive, force || .some(archive) != lastWritten else { return }
        lastWritten = .some(archive)
        store.save(archive, scene: sceneIdentifier)
    }

    /// The tree as saved, or nil (`.none`) before restore wired the window:
    /// Incognito chats, and the files opened from their session copies,
    /// leave nothing behind; the main leaf's chat reading position comes from
    /// the live chat; and each pairing's remembered share is kept.
    private func currentArchive() -> PaneLayoutArchive?? {
        guard let navigation, let rootServerId = coordinator.flatMap(navigation.activeServerId(in:)) else { return .none }
        var layout = layout(rootServerId: rootServerId)
        // A zoom the window's width forced is redrawn from the width.
        if companionZoomIsFit, layout.zoomed == companionID { layout.zoomed = nil }
        // Full screen is not restored: the split comes back as it was.
        if let fullScreen, layout.zoomed == fullScreen.cell { layout.zoomed = fullScreen.zoomedBefore }
        layout.root = layout.root.mapLeaves { leaf in
            var leaf = leaf
            leaf.stack = leaf.stack.map { entry in
                let sessionId: String? = switch entry.route {
                case .session(let id), .file(.session(let id), _, _), .panel(let id, _), .read(let id, _): id
                default: nil
                }
                guard let sessionId,
                      coordinator?.connection(for: entry.serverId)?.sessionStore.session(id: sessionId)?.ephemeral == true
                else { return entry }
                return PaneStackEntry(serverId: entry.serverId, route: .local(PaneLocalToken(raw: "incognito")))
            }
            return leaf
        }
        var scroll: [PaneID: PaneChatScroll] = [:]
        if case .session(let sessionId)? = layout.leaf(mainLeafID)?.stack.last?.route {
            let reports = chats.allObjects.compactMap { ($0 as? PaneChat)?.paneChatScroll }
            // A restored position the chat has not taken yet is still the
            // reader's place.
            scroll[mainLeafID] = reports.first { $0.sessionId == sessionId }
                ?? handoff.scroll.flatMap { $0.sessionId == sessionId ? $0 : nil }
        }
        return .some(PaneLayoutArchive(
            restorable: layout,
            chatScroll: scroll,
            companionShares: rememberedShares
        ))
    }
}
