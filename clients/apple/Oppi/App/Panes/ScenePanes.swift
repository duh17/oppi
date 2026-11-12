import Foundation
import Observation

/// A chat that can say where its reader is, for restoration.
@MainActor
protocol PaneChatScrollReporting: AnyObject {
    var paneChatScroll: PaneChatScroll? { get }
}

/// The window's pane tree as far as it exists before the per-window tree
/// (Stage 3): the primary leaf, whose stack is the shell's routes
/// (`AppNavigation`), and at most one attached companion beside it
/// (`PaneHostController`). This owns what the routes do not hold (the
/// companion's link, width share and focus), writes the tree when it settles
/// (`PaneTreeStore`, 500 ms after the last change, and at once when the
/// scene goes to the background), and restores it at launch.
///
/// Only a chat's Files and Git panels have links (`.files`, `.git`), so they
/// are the companions that restore; Outline, Context, Share, readers and a
/// commit's diff are `.local` and are not saved.
@MainActor @Observable
final class ScenePanes {
    static let primaryLeafID = leafID("main")
    static let companionLeafID = leafID("side")

    private static func leafID(_ raw: String) -> PaneID {
        guard let id = PaneID(raw) else { preconditionFailure("\(raw) is not a pane id") }
        return id
    }

    /// The companion's link while one is shown; nil with none, or one that
    /// has no link.
    private(set) var companionRoute: PaneStackEntry?
    private(set) var companionIsShown = false
    private(set) var companionIsFocused = false
    /// The companion's share of the host's width, for every companion and
    /// every host this window mounts. Nil until dragged or restored.
    var companionFraction: CGFloat?

    @ObservationIgnored private var sceneIdentifier: String?
    @ObservationIgnored private var store = PaneTreeStore()
    @ObservationIgnored private var pending: PaneLayoutArchive?
    @ObservationIgnored private var restoredPanel: (sessionId: String, route: PaneRoute)?
    @ObservationIgnored private var restoredScroll: PaneChatScroll?
    @ObservationIgnored private var restoredCompanionFocus = false
    @ObservationIgnored private let chats = NSHashTable<AnyObject>.weakObjects()
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var lastWritten: Saved?
    @ObservationIgnored private weak var navigation: AppNavigation?
    @ObservationIgnored private weak var coordinator: ConnectionCoordinator?
    /// Debounce before a settled change is written.
    private static let settleDelay: Duration = .milliseconds(500)
    /// How long restored screens must hold before the restore counts as
    /// survived (`PaneTreeStore.restoringKey`).
    private static let restoreSurvivalDelay: Duration = .seconds(5)

    /// What a settle writes: the tree, and the companion's share whether or
    /// not a companion shows.
    private struct Saved: Equatable, Sendable {
        var layout: PaneLayout
        var companionFraction: Double?
    }

    // MARK: Scene

    /// The scene connected: read its tree, to restore once launch has its
    /// stores (`restore`). A restore that the app did not survive last time
    /// (it crashed or was killed while mounting the screens) is not tried
    /// again: the trees go and the window starts fresh.
    func connect(scene id: String, store: PaneTreeStore = PaneTreeStore()) {
        sceneIdentifier = id
        self.store = store
        if store.lastRestoreWasInterrupted {
            store.dropAfterInterruptedRestore(scene: id)
        }
        pending = store.load(scene: id)
    }

    // MARK: Host and chat reports

    func companionDidChange(_ entry: PaneStackEntry?, shown: Bool) {
        if companionRoute != entry { companionRoute = entry }
        if companionIsShown != shown { companionIsShown = shown }
        if !shown, companionIsFocused { companionIsFocused = false }
    }

    func focusDidChange(onCompanion: Bool) {
        if companionIsFocused != onCompanion { companionIsFocused = onCompanion }
    }

    func register(chat: PaneChatScrollReporting) {
        chats.add(chat)
    }

    /// The panel a restored chat reopens beside itself, once.
    func takeRestoredPanel(for sessionId: String) -> PaneRoute? {
        guard let panel = restoredPanel, panel.sessionId == sessionId else { return nil }
        restoredPanel = nil
        return panel.route
    }

    /// The reading position a restored chat starts at, once.
    func takeRestoredScroll(for sessionId: String) -> PaneChatScroll? {
        guard let scroll = restoredScroll, scroll.sessionId == sessionId else { return nil }
        restoredScroll = nil
        return scroll
    }

    /// A restored entry was closed before its chat showed: the chat's panel
    /// and position must not open when the person opens it later by hand.
    func dropRestoredHandoffs() {
        restoredPanel = nil
        restoredScroll = nil
        restoredCompanionFocus = false
    }

    /// Whether a restored companion takes focus as it mounts, once.
    func takeRestoredCompanionFocus() -> Bool {
        defer { restoredCompanionFocus = false }
        return restoredCompanionFocus
    }

    // MARK: Snapshot

    /// The window's tree now. The companion is kept only beside a chat, the
    /// one screen whose panels have links.
    func layout(navigation: AppNavigation, rootServerId: String) -> PaneLayout {
        let stack = PaneEntries.primaryStack(navigation.primaryStackElements, rootServerId: rootServerId)
        let main = PaneLeaf(id: Self.primaryLeafID, name: nil, stack: stack, attachedTo: nil, origin: .split)
        guard companionIsShown, case .session? = stack.last?.route else {
            return PaneLayout(single: main)
        }
        let side = PaneLeaf(
            id: Self.companionLeafID,
            name: nil,
            stack: [companionRoute ?? PaneStackEntry(serverId: rootServerId, route: .local(PaneLocalToken(raw: "panel")))],
            attachedTo: Self.primaryLeafID,
            origin: .attached
        )
        let share = Double(min(max(companionFraction ?? 0.4, 0.05), 0.95))
        let focus = companionIsFocused ? Self.companionLeafID : Self.primaryLeafID
        return PaneLayout(
            root: .split(axis: .row, children: [.leaf(main), .leaf(side)], weights: [1 - share, share]),
            focus: focus,
            recency: focus == Self.primaryLeafID
                ? [Self.primaryLeafID, Self.companionLeafID]
                : [Self.companionLeafID, Self.primaryLeafID]
        )
    }

    // MARK: Restore

    /// Applies the tree read at `connect`: the primary leaf's screens, then
    /// the chat's panel, width share, focus and reading position, which the
    /// chat takes as it appears. With App Lock on, this waits for unlock so
    /// nothing mounts behind the cover. Then the window's changes are saved.
    /// `applying: false` drops the saved tree (nothing paired to show it on).
    func restore(navigation: AppNavigation, coordinator: ConnectionCoordinator, applying: Bool = true) {
        guard saving == nil else { return }
        self.navigation = navigation
        self.coordinator = coordinator
        guard applying, let archive = pending else {
            pending = nil
            startSaving()
            return
        }
        pending = nil
        guard AppLockService.shared.isLocked else {
            apply(archive, navigation: navigation, coordinator: coordinator)
            startSaving()
            return
        }
        Task { [weak self] in
            for await locked in Observations({ AppLockService.shared.isLocked }) where !locked { break }
            guard let self else { return }
            // An open that waited for the same unlock (a notification, a
            // link) already chose the screen; it wins over the saved tree.
            if navigation.primaryStackElements.isEmpty {
                self.apply(archive, navigation: navigation, coordinator: coordinator)
            }
            self.startSaving()
        }
    }

    private func apply(_ archive: PaneLayoutArchive, navigation: AppNavigation, coordinator: ConnectionCoordinator) {
        markRestoringUntilSurvived()
        if let fraction = archive.companionFraction { companionFraction = CGFloat(fraction) }
        let layout = archive.layout
        guard let primary = layout.leaves.first(where: { $0.attachedTo == nil }) else { return }
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
        restoredScroll = archive.chatScroll[primary.id].flatMap { $0.sessionId == sessionId ? $0 : nil }
        guard let companion = layout.leaves.first(where: { $0.attachedTo == primary.id }),
              let route = companion.stack.last?.route else { return }
        restoredPanel = (sessionId, route)
        restoredCompanionFocus = layout.focus == companion.id
    }

    /// Marks the restore under way, and clears the mark once the screens
    /// have held a while; `flush` clears it too.
    private func markRestoringUntilSurvived() {
        store.markRestoring(true)
        Task { [weak self] in
            try? await Task.sleep(for: Self.restoreSurvivalDelay)
            self?.store.markRestoring(false)
        }
    }

    // MARK: Saving

    private func startSaving() {
        guard saving == nil else { return }
        saving = Task { [weak self] in
            var debounce: Task<Void, Never>?
            for await saved in Observations({ [weak self] in self?.currentSaved() }) {
                debounce?.cancel()
                guard let self, let saved else { continue }
                debounce = Task { [weak self] in
                    try? await Task.sleep(for: Self.settleDelay)
                    guard !Task.isCancelled else { return }
                    self?.write(saved)
                }
            }
        }
    }

    private func currentSaved() -> Saved? {
        guard let navigation, let rootServerId = coordinator?.activeServerId else { return nil }
        return Saved(
            layout: layout(navigation: navigation, rootServerId: rootServerId),
            companionFraction: companionFraction.map(Double.init)
        )
    }

    /// Writes the tree now (the scene is going to the background), and
    /// counts a restore still under way as survived.
    func flush() {
        store.markRestoring(false)
        guard saving != nil, let saved = currentSaved() else { return }
        write(saved, force: true)
    }

    private func write(_ saved: Saved, force: Bool = false) {
        guard let sceneIdentifier, force || saved != lastWritten else { return }
        lastWritten = saved
        store.save(archive(of: saved), scene: sceneIdentifier)
    }

    /// The tree as saved: Incognito chats, and the files opened from their
    /// session copies, leave nothing behind, and the primary chat's reading
    /// position comes from the live chat.
    private func archive(of saved: Saved) -> PaneLayoutArchive? {
        var layout = saved.layout
        layout.root = layout.root.mapLeaves { leaf in
            var leaf = leaf
            leaf.stack = leaf.stack.map { entry in
                let sessionId: String? = switch entry.route {
                case .session(let id), .file(.session(let id), _, _): id
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
        if case .session(let sessionId)? = layout.leaf(Self.primaryLeafID)?.stack.last?.route {
            let reports = chats.allObjects.compactMap { ($0 as? PaneChatScrollReporting)?.paneChatScroll }
            scroll[Self.primaryLeafID] = reports.first { $0.sessionId == sessionId }
        }
        return PaneLayoutArchive(restorable: layout, chatScroll: scroll, companionFraction: saved.companionFraction)
    }
}
