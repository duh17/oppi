import Foundation
import Observation

/// A chat that can say where its reader is, for restoration.
@MainActor
protocol PaneChatScrollReporting: AnyObject {
    var paneChatScroll: PaneChatScroll? { get }
}

/// The window's pane tree (`PaneLayout`): its leaves, their weights, focus,
/// recency and zoom. The routed leaf's stack is the shell's
/// (`AppNavigation.workspaceStackRouteElements`) and is read into the tree
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
    @ObservationIgnored private weak var navigation: AppNavigation?
    @ObservationIgnored private weak var coordinator: ConnectionCoordinator?
    /// Debounce before a settled change is written.
    private static let settleDelay: Duration = .milliseconds(500)
    /// How long restored screens must hold before the restore counts as
    /// survived (`PaneTreeStore.restoringKey(forScene:)`).
    private static let restoreSurvivalDelay: Duration = .seconds(5)
    /// The routed leaf's stack until `layout(…)` reads the shell's.
    private static let routedPlaceholder = PaneStackEntry(serverId: "", route: .local(PaneLocalToken(raw: "routes")))

    init() {
        let id = Self.leafID(1)
        nextLeafNumber = 2
        routedLeafID = id
        tree = PaneLayout(single: PaneLeaf(id: id, name: nil, stack: [Self.routedPlaceholder], attachedTo: nil, origin: .split))
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
        if let share = rememberedShare ?? drawnShare.map({ min(max($0, 0.05), 0.95) }), let path = opened.root.path(of: leaf.id),
           let next = try? opened.setWeights(at: Array(path.dropLast()), [1 - share, share]) {
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
        guard let companionID, let path = tree.root.path(of: companionID),
              let next = try? tree.setWeights(at: Array(path.dropLast()), [1 - share, share]) else { return }
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
    func layout(navigation: AppNavigation, rootServerId: String) -> PaneLayout {
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
        if let share = rememberedShare, let path = withPanel.root.path(of: side.id),
           let next = try? withPanel.setWeights(at: Array(path.dropLast()), [1 - share, share]) {
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
        navigation: AppNavigation,
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

    private func apply(_ archive: PaneLayoutArchive, navigation: AppNavigation, coordinator: ConnectionCoordinator) {
        markRestoringUntilSurvived()
        rememberedShare = archive.companionFraction
        let layout = archive.layout
        guard let primary = layout.leaves.first(where: { $0.attachedTo == nil }) else { return }
        if layout.leaves.count(where: { $0.attachedTo == nil }) > 1 {
            // This build opens no split leaves yet (they come with the pane
            // commands); a tree with more keeps the first routed leaf.
            ClientLog.warning("Panes", "Restored tree has more routed leaves than the window shows", metadata: [
                "leaves": String(layout.leaves.count),
            ])
        }
        routedLeafID = primary.id
        tree = PaneLayout(single: PaneLeaf(
            id: primary.id, name: primary.name, stack: [Self.routedPlaceholder], attachedTo: nil, origin: primary.origin
        ))
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

        guard case .session(let sessionId)? = primary.stack.last?.route else { return }
        handoff.scroll = archive.chatScroll[primary.id].flatMap { $0.sessionId == sessionId ? $0 : nil }
        guard let companion = layout.leaves.first(where: { $0.attachedTo == primary.id }),
              let route = companion.stack.last?.route else { return }
        if let path = layout.root.path(of: companion.id), let index = path.last,
           case .split(_, _, let weights)? = layout.root.node(at: Array(path.dropLast())) {
            rememberedShare = weights[index]
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
        guard let navigation, let rootServerId = coordinator?.activeServerId else { return .none }
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
