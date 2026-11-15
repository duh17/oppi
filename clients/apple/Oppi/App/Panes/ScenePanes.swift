import Foundation
import Observation

/// A chat that can say where its reader is, for restoration.
@MainActor
protocol PaneChatScrollReporting: AnyObject {
    var paneChatScroll: PaneChatScroll? { get }
}

/// The window's pane tree (`PaneLayout`): its leaves, their weights, focus,
/// recency and zoom. The routed leaf's stack is the shell's
/// (`SceneNavigation.workspaceStackRouteElements`) and is read into the tree
/// when it is saved; every other part lives here. Today a window holds the
/// routed leaf and at most one attached companion beside it, which the pane
/// host (`PaneHostController`) draws and reports into the tree: it opens and
/// closes, takes a share of the width, zooms to the full window (by a drag,
/// or because it does not fit beside its leaf: build plan §1.3), and takes
/// focus.
///
/// This writes the tree when it settles (`PaneTreeStore`, 500 ms after the
/// last change, and at once when the scene goes to the background), and
/// restores it at launch. A chat's Files and Git panels and its extension
/// panels have links (`.files`, `.git`, `.panel`), so they are the
/// companions that restore; Outline, Context, Share, readers and a commit's
/// diff are `.local` and are not saved.
///
/// Split Panes is an experiment (Settings → Experiments, on by default).
/// While it is off the window's cells are the routed leaf alone, with its
/// companion: no split leaf mounts, and no change to the cells is made, so
/// the tree (and what is saved) keeps the split leaves until the switch
/// comes back on and they mount again. The host offers no split while off
/// (`PaneHostController.canSplit`, `openChoices`).
@MainActor @Observable
final class ScenePanes {
    /// The tree. The routed leaf's stack here is a placeholder; `layout(…)`
    /// fills it from the shell's routes.
    private(set) var tree: PaneLayout
    /// The routed leaf: the shell's stack.
    private(set) var routedLeafID: PaneID
    /// The share of the width the next companion opens at: the last one a
    /// companion settled at, in this window or (restored) before relaunch.
    @ObservationIgnored private var rememberedShare: Double?
    @ObservationIgnored private var nextLeafNumber = 1
    /// Split leaves a relaunch brought back that have not mounted yet. A
    /// browser among them opens paused, its page loading only on a tap
    /// (build plan §1.8).
    @ObservationIgnored private var restoredLeaves: Set<PaneID> = []
    /// One sheet at a time across the window's panes.
    @ObservationIgnored let sheets = PaneSheetArbiter()
    /// The Split Panes experiment, as this window draws it. Follows the
    /// switch without a relaunch.
    var splitsEnabled: Bool
    @ObservationIgnored private var experimentObserver: NSObjectProtocol?

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
    /// The routed stack a relaunch restored (and its entries resolved into
    /// their screens), until the person navigates away from it: showing it
    /// does not reveal a routed leaf a restored zoom hides.
    @ObservationIgnored private var restoredRoutedStack: [WorkspaceStackRouteElement]?
    @ObservationIgnored private weak var coordinator: ConnectionCoordinator?
    /// Debounce before a settled change is written.
    private static let settleDelay: Duration = .milliseconds(500)
    /// How long restored screens must hold before the restore counts as
    /// survived (`PaneTreeStore.restoringKey(forScene:)`).
    private static let restoreSurvivalDelay: Duration = .seconds(5)
    /// The routed leaf's stack until `layout(…)` reads the shell's.
    private static let routedPlaceholder = PaneStackEntry(serverId: "", route: .local(PaneLocalToken(raw: "routes")))

    init(splitsEnabled: Bool = AppPreferenceStore.Experiments.splitPanesEnabled) {
        let id = Self.leafID(1)
        nextLeafNumber = 2
        routedLeafID = id
        tree = PaneLayout(single: PaneLeaf(id: id, name: nil, stack: [Self.routedPlaceholder], attachedTo: nil, origin: .split))
        self.splitsEnabled = splitsEnabled
        experimentObserver = NotificationCenter.default.addObserver(
            forName: AppPreferences.Experiments.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let enabled = AppPreferenceStore.Experiments.splitPanesEnabled
                if self?.splitsEnabled != enabled { self?.splitsEnabled = enabled }
            }
        }
    }

    isolated deinit {
        if let experimentObserver { NotificationCenter.default.removeObserver(experimentObserver) }
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

    /// The attached leaf beside the routed one, if one is open.
    var companionID: PaneID? {
        tree.leaves.first { $0.attachedTo == routedLeafID }?.id
    }

    /// The share of the width a companion rests at: the last one settled,
    /// nil until one ever was (a companion then opens at its own ideal
    /// width). The tree's weight follows it, or the drawn share before it is
    /// known.
    var companionShare: Double? { rememberedShare }

    var isCompanionZoomed: Bool { companionID != nil && tree.zoomed == companionID }
    /// The companion's zoom is the fit rule's, not the person's: it ends
    /// when the window fits both leaves again, and is never saved.
    private(set) var companionZoomIsFit = false
    var isCompanionFocused: Bool { companionID != nil && tree.focus == companionID }

    /// The companion's share of the cell it shares with its routed leaf, as
    /// the tree's weights hold it; nil without a companion.
    private var companionPairShare: Double? {
        guard let companionID, let path = tree.root.path(of: companionID), let index = path.last, index > 0,
              case .split(_, _, let weights)? = tree.root.node(at: Array(path.dropLast())) else { return nil }
        let pair = weights[index - 1] + weights[index]
        return pair > 0 ? weights[index] / pair : nil
    }

    /// `layout` with the companion's weight at `share` of the cell it shares
    /// with the leaf before it, the pair keeping its total.
    private static func settingCompanionShare(_ share: Double, of companion: PaneID, in layout: PaneLayout) -> PaneLayout? {
        guard let path = layout.root.path(of: companion), let index = path.last, index > 0,
              case .split(_, _, var weights)? = layout.root.node(at: Array(path.dropLast())) else { return nil }
        let pair = weights[index - 1] + weights[index]
        weights[index - 1] = pair * (1 - share)
        weights[index] = pair * share
        return try? layout.setWeights(at: Array(path.dropLast()), weights)
    }

    /// A companion opened beside the routed leaf, or the open one shows
    /// another panel (`route` is its link, nil when it has none). Its weight
    /// is the remembered share, else `drawnShare`.
    func companionDidOpen(_ route: PaneStackEntry?, drawnShare: Double? = nil) {
        let stack = [route ?? PaneStackEntry(serverId: "", route: .local(PaneLocalToken(raw: "panel")))]
        if let companionID {
            guard tree.leaf(companionID)?.stack != stack else { return }
            tree.root = tree.root.mapLeaves { leaf in
                guard leaf.id == companionID else { return leaf }
                var leaf = leaf
                leaf.stack = stack
                return leaf
            }
            return
        }
        let leaf = PaneLeaf(id: freshLeafID(), name: nil, stack: stack, attachedTo: routedLeafID, origin: .attached)
        guard var opened = try? tree.split(routedLeafID, axis: .row, inserting: leaf) else { return }
        if let share = rememberedShare ?? drawnShare.map({ min(max($0, 0.05), 0.95) }),
           let next = Self.settingCompanionShare(share, of: leaf.id, in: opened) {
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
        rememberedShare = share
        guard let companionID, let next = Self.settingCompanionShare(share, of: companionID, in: tree) else { return }
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

    /// Pane focus moved to the companion, or back to the routed leaf.
    func focusCompanion(_ onCompanion: Bool) {
        guard let target = onCompanion ? companionID : routedLeafID, tree.focus != target,
              let next = try? tree.focusing(target) else { return }
        tree = next
    }

    // MARK: Cells and split leaves

    /// The leaves Split made (or a restored tree held): every leaf but the
    /// routed one and its companion, in tree order.
    var splitLeaves: [PaneLeaf] {
        guard splitsEnabled else { return [] }
        return tree.leaves.filter { $0.id != routedLeafID && $0.attachedTo == nil }
    }

    /// The tree the host lays out by the fit rule: one cell per leaf, the
    /// companion folded into its routed leaf's cell, which draws it inside
    /// itself (`PaneHostController`). The person's full-window companion is
    /// its cell's zoom; the fit rule's stays inside the cell.
    var cellLayout: PaneLayout {
        guard splitsEnabled else {
            // The routed leaf alone; its full-window companion is its zoom, as
            // below.
            var cells = PaneLayout(single: tree.leaf(routedLeafID)
                ?? PaneLeaf(id: routedLeafID, name: nil, stack: [Self.routedPlaceholder], attachedTo: nil, origin: .split))
            if tree.zoomed == companionID, companionID != nil, !companionZoomIsFit { cells.zoomed = routedLeafID }
            return cells
        }
        guard let companionID, var cells = try? tree.close(companionID) else { return tree }
        if tree.focus == companionID {
            cells.focus = routedLeafID
            cells.recency.removeAll { $0 == routedLeafID }
            cells.recency.insert(routedLeafID, at: 0)
        }
        if tree.zoomed == companionID, !companionZoomIsFit { cells.zoomed = routedLeafID }
        return cells
    }

    /// Runs `change` on the cells and puts the companion back beside its
    /// routed leaf, at the share, focus, zoom and recency it had. False when
    /// the change is refused.
    /// Refused while Split Panes is off: the cells drawn then are not the
    /// tree's, and writing them back would drop its split leaves.
    @discardableResult
    private func changeCells(_ change: (PaneLayout) throws -> PaneLayout) -> Bool {
        guard splitsEnabled, var next = try? change(cellLayout) else { return false }
        if let companionID, let companion = tree.leaf(companionID), next.leaf(routedLeafID) != nil,
           var withCompanion = try? next.split(routedLeafID, axis: .row, inserting: companion) {
            if let share = companionPairShare,
               let shared = Self.settingCompanionShare(share, of: companionID, in: withCompanion) {
                withCompanion = shared
            }
            withCompanion.recency = next.recency.flatMap { $0 == routedLeafID ? [$0, companionID] : [$0] }
            if tree.focus == companionID, next.focus == routedLeafID {
                withCompanion.focus = companionID
                withCompanion.recency.removeAll { $0 == companionID }
                withCompanion.recency.insert(companionID, at: 0)
            }
            if tree.zoomed == companionID, companionZoomIsFit || next.zoomed == routedLeafID {
                withCompanion.zoomed = companionID
            }
            next = withCompanion
        }
        if next != tree { tree = next }
        return true
    }

    /// Splits `id` along `axis`. The new leaf copies a Files, Git, file or
    /// terminal pane; anything else (a chat, a session list, the launcher)
    /// gets the launcher, since one server streams one chat at a time.
    /// Returns the new leaf's id; focus stays where it was.
    @discardableResult
    func split(_ id: PaneID, axis: PaneAxis) -> PaneID? {
        guard tree.leaves.count < PaneLayout.maximumLeaves else { return nil }
        let leaf = PaneLeaf(id: freshLeafID(), name: nil, stack: [splitEntry(copying: id)], attachedTo: nil, origin: .split)
        return changeCells { try $0.split(id, axis: axis, inserting: leaf) } ? leaf.id : nil
    }

    /// Opens `entry` in a new leaf at `edge` of `id` (a drop on a pane's
    /// edge). Returns the new leaf's id; focus stays where it was.
    @discardableResult
    func split(_ id: PaneID, edge: PaneEdge, showing entry: PaneStackEntry) -> PaneID? {
        guard tree.leaves.count < PaneLayout.maximumLeaves else { return nil }
        let leaf = PaneLeaf(id: freshLeafID(), name: nil, stack: [entry], attachedTo: nil, origin: .split)
        return changeCells { try $0.split(id, edge: edge, inserting: leaf) } ? leaf.id : nil
    }

    /// The screens items opened as whose entries have no link (a file opened
    /// from a chat keeps its chat's lock), by entry: Undo brings such a pane
    /// back as it was while the window lives. Not saved.
    @ObservationIgnored private(set) var standIns: [PaneLocalToken: WorkspaceStackRouteElement] = [:]

    /// Remembers the screen an opened item's stand-in entry shows.
    func remember(_ element: WorkspaceStackRouteElement, for entry: PaneStackEntry) {
        guard case .local(let token) = entry.route else { return }
        standIns[token] = element
    }

    /// Open in New Pane: `entry` in a new leaf at `edge` of `id` (`.right` or
    /// `.bottom`), focused, filling the window when `full` (the fit rule: it
    /// cannot sit beside it). Undo takes it back. Returns the new leaf's id.
    @discardableResult
    func open(_ entry: PaneStackEntry, at edge: PaneEdge = .right, ofCell id: PaneID, full: Bool) -> PaneID? {
        guard edge.isTrailing, tree.leaves.count < PaneLayout.maximumLeaves else { return nil }
        let leaf = PaneLeaf(id: freshLeafID(), name: nil, stack: [entry], attachedTo: nil, origin: .split)
        undoable(Self.openAction) { cells in
            let opened = try cells.split(id, axis: edge.axis, inserting: leaf).focusing(leaf.id)
            return full ? try opened.zoom(leaf.id) : opened
        }
        return tree.leaf(leaf.id) == nil ? nil : leaf.id
    }

    /// Open in Pane: a split leaf shows `entry` in place of what it showed,
    /// focused. Undo brings back what it showed.
    func open(_ entry: PaneStackEntry, inCell id: PaneID) {
        guard id != routedLeafID, tree.leaf(id)?.attachedTo == nil else { return }
        undoable(Self.openInPaneAction) { cells in
            var cells = cells
            cells.root = cells.root.mapLeaves { leaf in
                guard leaf.id == id else { return leaf }
                var leaf = leaf
                leaf.stack = [entry]
                return leaf
            }
            return try cells.focusing(id)
        }
    }

    /// What a split of `id` shows.
    private func splitEntry(copying id: PaneID) -> PaneStackEntry {
        let top = topEntry(of: id)
        switch top.route {
        case .files, .hostFiles, .file, .git, .commit:
            return top
        case .local(let token):
            if case .terminal? = PaneLocalScreen(token) { return top }
            return launcher(for: id)
        default:
            return launcher(for: id)
        }
    }

    /// The launcher (Sessions, Files, Terminal) for the workspace `id` shows.
    func launcher(for id: PaneID) -> PaneStackEntry {
        let context = context(of: id)
        return PaneStackEntry(serverId: context.serverId, route: .local(PaneLocalScreen.launcher(workspaceId: context.workspaceId).token))
    }

    /// The top entry of `id`'s stack; the routed leaf's from the shell.
    func topEntry(of id: PaneID) -> PaneStackEntry {
        if id == routedLeafID, let stack = routedStack, let top = stack.last { return top }
        return tree.leaf(id)?.stack.last ?? Self.routedPlaceholder
    }

    /// The routed leaf's stack as entries, once restore wired the window.
    private var routedStack: [PaneStackEntry]? {
        guard let navigation, let coordinator, let serverId = navigation.activeServerId(in: coordinator) else { return nil }
        return PaneEntries.primaryStack(navigation.workspaceStackRouteElements, rootServerId: serverId)
    }

    /// The server and workspace a leaf works in: its top screen's, else the
    /// nearest one below it that names a workspace.
    func context(of id: PaneID) -> (serverId: String, workspaceId: String?) {
        if id == routedLeafID, let navigation {
            // The shell's own targets name their workspace, also for a chat
            // opened from All Sessions.
            for element in navigation.workspaceStackRouteElements.reversed() {
                if let found = Self.workspace(of: element) { return found }
            }
        }
        let stack = id == routedLeafID ? routedStack ?? [] : tree.leaf(id)?.stack ?? []
        let serverId = stack.last?.serverId ?? navigation.flatMap { nav in coordinator.flatMap(nav.activeServerId(in:)) } ?? ""
        for entry in stack.reversed() {
            if let workspaceId = workspaceId(of: entry) { return (entry.serverId, workspaceId) }
        }
        return (serverId, nil)
    }

    private static func workspace(of element: WorkspaceStackRouteElement) -> (serverId: String, workspaceId: String?)? {
        switch element {
        case .session(let target):
            return target.workspaceId.map { (target.serverId, $0) }
        case .workspace(let target), .workspaceConfiguration(let target):
            return (target.serverId, target.workspace.id)
        case .linkedFile(let target):
            return (target.serverId, target.workspaceId)
        case .fileBrowser(let target):
            guard case .workspace(let workspaceId, _) = target.scope else { return nil }
            return (target.serverId, workspaceId)
        default:
            return nil
        }
    }

    private func workspaceId(of entry: PaneStackEntry) -> String? {
        switch entry.route {
        case .sessions(let id): return id
        case .files(let id, _), .git(let id, _), .commit(let id, _), .file(.workspace(let id, _), _, _): return id
        case .session(let id), .file(.session(let id), _, _), .panel(let id, _):
            return coordinator?.connection(for: entry.serverId)?.sessionStore.session(id: id)?.workspaceId
        case .local(let token):
            return PaneLocalScreen(token)?.workspaceId
        case .thread, .file(.host, _, _), .hostFiles, .browser, .godot, .unsupported:
            return nil
        }
    }

    /// Whether `id` came back with a relaunch and mounts for the first time;
    /// true once.
    func takeRestored(_ id: PaneID) -> Bool {
        restoredLeaves.remove(id) != nil
    }

    /// A split leaf shows `entry` in place of what it showed.
    func show(_ entry: PaneStackEntry, in id: PaneID) {
        guard id != routedLeafID, tree.leaf(id)?.attachedTo == nil else { return }
        changeCells { try $0.showing(entry, in: id) }
    }

    /// Closes a split leaf. The routed leaf holds the window's stack and does
    /// not close.
    func close(_ id: PaneID) {
        guard id != routedLeafID, tree.leaf(id)?.attachedTo == nil else { return }
        undoable(Self.closeAction) { try $0.close(id) }
    }

    /// Every split leaf closes; the routed leaf and its companion stay.
    func resetPanes() {
        undoable(Self.resetAction) { cells in
            try cells.leaves.map(\.id).filter { $0 != routedLeafID }.reduce(cells) { try $0.close($1) }
        }
    }

    // MARK: Undo

    /// A change Undo can take back: its name ("Close Pane") and the cells
    /// before it. The chat's panel is not part of it: Undo leaves the panel
    /// as it is now (build plan §1.7).
    struct UndoStep: Equatable {
        let action: String
        let cells: PaneLayout
    }

    static let undoDepth = 5
    static let closeAction = String(localized: "Close Pane")
    static let moveAction = String(localized: "Move Pane")
    static let resetAction = String(localized: "Reset Panes")
    static let openAction = String(localized: "Open in New Pane")
    static let openInPaneAction = String(localized: "Open in Pane")

    /// Newest last, at most `undoDepth`. Not saved: a relaunch starts empty.
    private(set) var undoSteps: [UndoStep] = []

    /// What Undo would take back now ("Close Pane"), nil with nothing to undo
    /// or while Split Panes is off.
    var undoAction: String? { splitsEnabled ? undoSteps.last?.action : nil }

    /// Runs `change` on the cells and keeps the cells before it for Undo,
    /// when it changed anything.
    private func undoable(_ action: String, _ change: (PaneLayout) throws -> PaneLayout) {
        let before = cellLayout
        guard changeCells(change), cellLayout != before else { return }
        undoSteps.append(UndoStep(action: action, cells: before))
        if undoSteps.count > Self.undoDepth { undoSteps.removeFirst() }
    }

    /// Puts the cells back as they were before the newest step. A pane it
    /// brings back shows what it showed, from its link, not its scroll
    /// position. False with nothing to undo.
    @discardableResult
    func undo() -> Bool {
        guard let step = undoSteps.popLast() else { return false }
        return changeCells { _ in step.cells }
    }

    /// Zooms a cell to the whole window; nil restores. A zoom of the routed
    /// leaf takes its companion with it.
    func zoom(_ id: PaneID?) {
        changeCells { try $0.zoom(id) }
    }

    /// The cell that fills the window by the person's choice, if any.
    var zoomedCell: PaneID? { cellLayout.zoomed }

    /// Whether the routed stack about to show is the person's navigation,
    /// not the stack a relaunch restored. The first change away from the
    /// restored stack ends the restore's exemption.
    func routedStackNavigated() -> Bool {
        guard let restored = restoredRoutedStack else { return true }
        guard navigation?.workspaceStackRouteElements != restored else { return false }
        restoredRoutedStack = nil
        return true
    }

    /// A restored entry resolved into its screen in place: still the
    /// restore's stack, not navigation.
    func routedEntryResolved(from before: [WorkspaceStackRouteElement], to after: [WorkspaceStackRouteElement]) {
        if restoredRoutedStack == before { restoredRoutedStack = after }
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

    /// Focuses a cell: the routed leaf, or a split leaf.
    func focus(_ id: PaneID) {
        guard tree.focus != id else { return }
        if id == routedLeafID, tree.focus == companionID { return }
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

    func register(chat: PaneChatScrollReporting) {
        chats.add(chat)
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

    /// The window's tree now, with the routed leaf's stack read from the
    /// shell. A companion is kept only beside a chat, the one screen whose
    /// panels have links. A panel still waiting for its chat (the chat is a
    /// leaf state until its server connects) stays in the tree, so a save
    /// meanwhile does not lose it.
    func layout(navigation: SceneNavigation, rootServerId: String) -> PaneLayout {
        let stack = PaneEntries.primaryStack(navigation.workspaceStackRouteElements, rootServerId: rootServerId)
        let routed = routedLeafID
        var layout = tree
        layout.root = layout.root.mapLeaves { leaf in
            guard leaf.id == routed else { return leaf }
            var leaf = leaf
            leaf.stack = stack
            return leaf
        }
        guard let top = stack.last, case .session(let sessionId) = top.route else {
            if let companionID, let closed = try? layout.close(companionID) { return closed }
            return layout
        }
        guard companionID == nil, let waiting = pendingPanel(for: sessionId) else { return layout }
        let side = PaneLeaf(
            id: (0...).lazy.map(Self.leafID).first { layout.leaf($0) == nil } ?? Self.leafID(0),
            name: nil,
            stack: [PaneStackEntry(serverId: top.serverId, route: waiting)],
            attachedTo: routed,
            origin: .attached
        )
        guard var withPanel = try? layout.split(routed, axis: .row, inserting: side) else { return layout }
        if let share = rememberedShare, let next = Self.settingCompanionShare(share, of: side.id, in: withPanel) {
            withPanel = next
        }
        if handoff.panelFocused, let focused = try? withPanel.focusing(side.id) { withPanel = focused }
        if handoff.panelZoomed { withPanel.zoomed = side.id }
        return withPanel
    }

    // MARK: Restore

    /// Applies the tree read at `connect`: the routed leaf's screens, then
    /// the chat's panel, width share, focus, zoom and reading position, which
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
        rememberedShare = archive.companionFraction
        let layout = archive.layout
        // The routed leaf keeps the id a window's first leaf gets; split
        // leaves get later ones. An older tree names it only by being first.
        let unattached = layout.leaves.filter { $0.attachedTo == nil }
        guard let primary = unattached.first(where: { $0.id == Self.leafID(1) }) ?? unattached.first else { return }
        routedLeafID = primary.id
        // The split leaves come back where they were; the companion comes
        // back when its chat shows (`handoff.panel`), so it leaves the tree.
        var restored = layout
        for leaf in layout.leaves where leaf.attachedTo != nil {
            if restored.leaf(leaf.id) != nil, let closed = try? restored.close(leaf.id) { restored = closed }
        }
        restored.root = restored.root.mapLeaves { leaf in
            guard leaf.id == primary.id else { return leaf }
            var leaf = leaf
            leaf.stack = [Self.routedPlaceholder]
            return leaf
        }
        restored.zoomed = restored.zoomed.flatMap { layout.leaf($0)?.attachedTo == nil ? $0 : nil }
        tree = restored
        restoredLeaves = Set(restored.leaves.map(\.id)).subtracting([primary.id])
        var elements: [WorkspaceStackRouteElement] = []
        for (index, entry) in primary.stack.enumerated() {
            if index == 0 {
                // The root: a workspace's sessions when it still exists, else All Sessions.
                if case .sessions(_?) = entry.route,
                   let element = PaneEntries.element(for: entry, coordinator: coordinator) {
                    elements.append(element)
                }
                continue
            }
            if PaneEntries.state(of: entry, coordinator: coordinator) == .content,
               let element = PaneEntries.element(for: entry, coordinator: coordinator) {
                elements.append(element)
            } else {
                elements.append(.paneEntry(entry))
            }
        }
        navigation.restorePrimaryStack(elements)
        restoredRoutedStack = navigation.workspaceStackRouteElements

        guard case .session(let sessionId)? = primary.stack.last?.route else { return }
        handoff.scroll = archive.chatScroll[primary.id].flatMap { $0.sessionId == sessionId ? $0 : nil }
        guard let companion = layout.leaves.first(where: { $0.attachedTo == primary.id }),
              let route = companion.stack.last?.route else { return }
        if let path = layout.root.path(of: companion.id), let index = path.last, index > 0,
           case .split(_, _, let weights)? = layout.root.node(at: Array(path.dropLast())) {
            rememberedShare = weights[index] / (weights[index - 1] + weights[index])
        }
        handoff.panel = (sessionId, route)
        handoff.panelFocused = layout.focus == companion.id
        handoff.panelZoomed = layout.zoomed == companion.id
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
    /// leave nothing behind; the routed chat's reading position comes from
    /// the live chat; and the share the next companion opens at is kept only
    /// while no companion holds it as its weight.
    private func currentArchive() -> PaneLayoutArchive?? {
        guard let navigation, let rootServerId = coordinator.flatMap(navigation.activeServerId(in:)) else { return .none }
        var layout = layout(navigation: navigation, rootServerId: rootServerId)
        // A zoom the window's width forced is redrawn from the width.
        if companionZoomIsFit, layout.zoomed == companionID { layout.zoomed = nil }
        layout.root = layout.root.mapLeaves { leaf in
            var leaf = leaf
            leaf.stack = leaf.stack.map { entry in
                let sessionId: String? = switch entry.route {
                case .session(let id), .file(.session(let id), _, _), .panel(let id, _): id
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
        if case .session(let sessionId)? = layout.leaf(routedLeafID)?.stack.last?.route {
            let reports = chats.allObjects.compactMap { ($0 as? PaneChatScrollReporting)?.paneChatScroll }
            // A restored position the chat has not taken yet is still the
            // reader's place.
            scroll[routedLeafID] = reports.first { $0.sessionId == sessionId }
                ?? handoff.scroll.flatMap { $0.sessionId == sessionId ? $0 : nil }
        }
        let hasCompanion = layout.leaves.contains { $0.attachedTo == routedLeafID }
        return .some(PaneLayoutArchive(
            restorable: layout,
            chatScroll: scroll,
            companionFraction: hasCompanion ? nil : rememberedShare
        ))
    }
}
