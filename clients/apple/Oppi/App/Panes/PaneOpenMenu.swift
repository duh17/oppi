import UIKit

// Open Here, Open in New Pane (to the right or below) and Open in Pane ▸ on
// every file, folder and web link and file row (build plan §1.6 rule 4).
// Each surface keeps its own open (a tap, its menu's Open) as Open Here and
// says what the item is (`PaneOpenContent`);
// `PaneOpenMenu` builds the items, their accessibility actions and the opens
// from the pane the item sits in. A compact window, or a screen outside the
// panes (a sheet), offers none of them: the window has one pane there
// (§1.5). Neither does any window while the Split Panes experiment is off.

/// Where an item menu opens its item.
enum PaneOpenPlacement: Hashable {
    /// The surface's own open, as a tap does.
    case here
    /// A new pane at this edge of the item's pane: `.right` or `.bottom`.
    case newPane(PaneEdge)
    /// Another pane of the window, in place of what it shows.
    case pane(PaneID)
}

/// What an item opens as in a pane: its entry, and the shell screen it
/// opens as when that screen needs more than the entry carries (a file
/// opened from a chat keeps that chat's lock, which a link cannot name; its
/// entry then has no link and does not come back after a relaunch, as the
/// primary stack's own screens do in `PaneEntries.entry(for:)`).
struct PaneOpenContent {
    let entry: PaneStackEntry
    let element: WorkspaceStackRouteElement?

    init(entry: PaneStackEntry) {
        self.entry = entry
        element = nil
    }

    @MainActor
    init(file target: WorkspaceLinkedFileNavTarget) {
        let element = WorkspaceStackRouteElement.linkedFile(target)
        self.element = element
        entry = PaneEntries.entry(for: element)
            ?? PaneStackEntry(serverId: target.serverId, route: .local(PaneLocalToken(raw: "file/\(UUID().uuidString)")))
    }

    /// A folder in the File Browser; a worktree's folder has no link, so its
    /// entry stands in for the screen as a chat's file does.
    @MainActor
    init(folder target: FileBrowserNavTarget) {
        let element = WorkspaceStackRouteElement.fileBrowser(target)
        self.element = element
        entry = PaneEntries.entry(for: element)
            ?? PaneStackEntry(serverId: target.serverId, route: .local(PaneLocalToken(raw: "folder/\(UUID().uuidString)")))
    }

    /// The scoped lock that holds the item.
    @MainActor
    var lockTarget: ScopedLockTarget {
        switch element {
        case .linkedFile(let target)?:
            return WorkspaceLinkedFileViewController.lockTarget(for: target)
        case .fileBrowser(let target)?:
            if case .workspace(let workspaceId, _) = target.scope {
                return .workspace(serverId: target.serverId, workspaceId: workspaceId)
            }
            return .server(target.serverId)
        default:
            return PaneEntries.lockTarget(entry)
        }
    }
}

/// What an item menu offers from one pane: whether Open in New Pane can make
/// a pane to the right or below, and whether that pane opens full by the fit
/// rule (build plan §1.3), and the panes Open in Pane ▸ lists. Nil on a
/// compact window.
struct PaneOpenChoices: Equatable {
    struct Target: Equatable {
        let id: PaneID
        let title: String
    }

    enum NewPane: Equatable {
        /// It sits beside the item's pane.
        case beside
        /// Beside the item's pane both would be under their minimums: it
        /// fills the window, and the pane under it comes back with Restore.
        case full
    }

    /// A new pane to the item's pane's right; nil when the window already
    /// holds its most panes.
    var right: NewPane?
    /// A new pane below the item's pane; nil as `right` is.
    var below: NewPane?
    /// The other panes that take a file, in tree order: a split leaf shows
    /// it in place of its screen, the routed leaf pushes it.
    var targets: [Target]

    /// Whether a pane showing `leaf` takes a file in place of what it shows.
    /// A web page, a terminal, Rex or a game is a live surface of its own, not
    /// somewhere a file goes.
    static func takesFile(_ leaf: PaneLeaf) -> Bool {
        switch leaf.stack.last?.route {
        case .browser?, .godot?: return false
        case .local(let token)?:
            switch PaneLocalScreen(token) {
            case .terminal?, .rex?, .browser?: return false
            case .launcher?, .godot?, nil: return true
            }
        default: return true
        }
    }

    /// - Parameters:
    ///   - cells: the window's cells (`ScenePanes.cellLayout`).
    ///   - source: the cell the item sits in.
    ///   - presentation: where a tree of cells sits in the window now.
    static func resolve(
        isWide: Bool,
        canAddPane: Bool,
        cells: PaneLayout,
        source: PaneID,
        title: (PaneID) -> String,
        presentation: (PaneLayout) -> PanePresentation
    ) -> Self? {
        guard isWide, cells.leaf(source) != nil else { return nil }
        let targets = cells.leaves.filter { $0.id != source && takesFile($0) }.map { Target(id: $0.id, title: title($0.id)) }
        guard canAddPane else { return Self(right: nil, below: nil, targets: targets) }
        func newPane(_ edge: PaneEdge) -> NewPane {
            fits(edge, of: source, in: cells, presentation: presentation) ? .beside : .full
        }
        return Self(right: newPane(.right), below: newPane(.bottom), targets: targets)
    }

    /// Whether `route` opened at `edge` of `source` (`.right` or `.bottom`),
    /// focused as Open in New Pane leaves it, keeps every pane shown now on
    /// screen.
    static func fits(
        _ edge: PaneEdge,
        of source: PaneID,
        in cells: PaneLayout,
        showing route: PaneRoute = .file(.host, path: "", line: nil),
        presentation: (PaneLayout) -> PanePresentation
    ) -> Bool {
        guard let probeID = (1...PaneLayout.maximumLeaves + 1).lazy.compactMap({ PaneID("open-\($0)") })
            .first(where: { cells.leaf($0) == nil }) else { return false }
        let probe = PaneLeaf(
            id: probeID, name: nil,
            stack: [PaneStackEntry(serverId: "", route: route)],
            attachedTo: nil, origin: .split
        )
        guard let opened = try? cells.split(source, axis: edge.axis, inserting: probe).focusing(probeID) else { return false }
        let before = presentation(cells)
        let after = presentation(opened)
        let shownBefore = Set(before.frames.keys)
        return after.frames[probeID] != nil && shownBefore.allSatisfy { after.frames[$0] != nil }
    }
}

/// The item menu's pane items and their accessibility actions, from the pane
/// a view sits in, and the opens they run.
@MainActor
enum PaneOpenMenu {
    /// Open Here, Open in New Pane and Open in Pane ▸ for an item in `view`.
    /// Empty on a compact window and outside the panes. `includesOpenHere`
    /// is false where the surface's own menu already has its Open, or where
    /// the item is already shown here (a reader's own file).
    /// `offersOtherPanes` is false for a web page, which no pane but a new
    /// one takes.
    static func items(
        near view: UIView,
        includesOpenHere: Bool = true,
        offersOtherPanes: Bool = true,
        open: @escaping @MainActor (PaneOpenPlacement) -> Void
    ) -> [PaneMenuItem] {
        guard let (host, cell) = locate(view), let choices = host.openChoices(from: cell) else { return [] }
        var items: [PaneMenuItem] = []
        if includesOpenHere {
            items.append(PaneMenuItem(
                title: String(localized: "Open Here"), symbol: "arrow.up.forward.square",
                actionName: String(localized: "Open Here"), identifier: "pane.open.here",
                run: { open(.here) }
            ))
        }
        if choices.right != nil {
            items.append(PaneMenuItem(
                title: String(localized: "Open in New Pane to the Right"), symbol: "rectangle.split.2x1",
                actionName: String(localized: "Open in New Pane to the Right"), identifier: "pane.open.newPane.right",
                run: { open(.newPane(.right)) }
            ))
        }
        if choices.below != nil {
            items.append(PaneMenuItem(
                title: String(localized: "Open in New Pane Below"), symbol: "rectangle.split.1x2",
                actionName: String(localized: "Open in New Pane Below"), identifier: "pane.open.newPane.below",
                run: { open(.newPane(.bottom)) }
            ))
        }
        if offersOtherPanes, !choices.targets.isEmpty {
            items.append(PaneMenuItem(
                title: String(localized: "Open in Pane"), symbol: "rectangle.on.rectangle",
                actionName: String(localized: "Open in Pane"), identifier: "pane.open.inPane",
                children: choices.targets.map { target in
                    PaneMenuItem(
                        title: target.title, symbol: "rectangle",
                        actionName: String(localized: "Open in \(target.title)"),
                        identifier: "pane.open.inPane.\(target.id.raw)",
                        run: { open(.pane(target.id)) }
                    )
                }
            ))
        }
        return items
    }

    /// The items as one inline section of a menu; nil when there are none.
    static func section(
        near view: UIView,
        includesOpenHere: Bool = true,
        offersOtherPanes: Bool = true,
        open: @escaping @MainActor (PaneOpenPlacement) -> Void
    ) -> UIMenu? {
        let items = items(near: view, includesOpenHere: includesOpenHere, offersOtherPanes: offersOtherPanes, open: open)
        return items.isEmpty ? nil : UIMenu(options: .displayInline, children: items.map(\.element))
    }

    /// The same items as accessibility actions, a submenu's panes one each.
    static func accessibilityActions(
        near view: UIView,
        includesOpenHere: Bool = true,
        open: @escaping @MainActor (PaneOpenPlacement) -> Void
    ) -> [UIAccessibilityCustomAction] {
        items(near: view, includesOpenHere: includesOpenHere, open: open).flatMap(\.leaves).map { item in
            let run = item.run
            return UIAccessibilityCustomAction(name: item.actionName) { _ in
                run()
                return true
            }
        }
    }

    /// The items on a plain view (a pill, a row button) whose tap is its
    /// Open Here: a long press shows them, and VoiceOver reads them as
    /// actions when it reaches the view, so both follow the window's width.
    static func attach(to view: UIView, open: @escaping @MainActor (PaneOpenPlacement) -> Void) {
        PaneOpenContextMenu.install(on: view, open: open)
        view.accessibilityCustomActionsBlock = { [weak view] in
            MainActor.assumeIsolated {
                view.map { accessibilityActions(near: $0, includesOpenHere: false, open: open) } ?? []
            }
        }
    }

    /// `attach(to:open:)` for an item whose content is known: `here` is its
    /// own open, and the pane items open `content`.
    static func attach(
        to view: UIView,
        here: @escaping @MainActor () -> Void,
        content: @escaping @MainActor () -> PaneOpenContent?
    ) {
        attach(to: view) { [weak view] placement in
            guard placement != .here else { return here() }
            guard let view else { return }
            open(placement, from: view) { content() }
        }
    }

    /// Opens what `content` resolves to at `placement`, from the pane `view`
    /// sits in, once its scoped lock allows. `.here` is the surface's own.
    static func open(
        _ placement: PaneOpenPlacement,
        from view: UIView,
        content: @escaping @MainActor () async -> PaneOpenContent?
    ) {
        guard placement != .here else { return }
        Task { @MainActor [weak view] in
            let opener = view.flatMap { AppRootEnvironment.near($0) }?.opener
            guard let content = await content() else {
                opener?.toast(String(localized: "Oppi can\u{2019}t open this in a pane"))
                return
            }
            guard await ScopedLockService.shared.authorize(content.lockTarget),
                  let view, let (host, cell) = locate(view) else { return }
            host.open(content, placement, from: cell)
        }
    }

    /// The pane host `view` sits in and the cell that holds it.
    private static func locate(_ view: UIView) -> (PaneHostController, PaneID)? {
        guard let controller = view.nearestViewController,
              let host = controller as? PaneHostController ?? PaneHostController.containing(controller),
              let cell = host.cell(holding: controller) else { return nil }
        return (host, cell)
    }
}

/// A long press on a plain view (a pill, a row button) that shows the pane
/// items, and nothing where there are none.
@MainActor
final class PaneOpenContextMenu: NSObject, UIContextMenuInteractionDelegate {
    private let open: @MainActor (PaneOpenPlacement) -> Void

    init(open: @escaping @MainActor (PaneOpenPlacement) -> Void) {
        self.open = open
    }

    /// Adds the menu to `view`; the view keeps it through its interaction.
    static func install(on view: UIView, open: @escaping @MainActor (PaneOpenPlacement) -> Void) {
        view.addInteraction(Interaction(menu: PaneOpenContextMenu(open: open)))
    }

    /// An interaction that keeps its delegate, which UIKit holds weakly.
    private final class Interaction: UIContextMenuInteraction {
        private let menu: PaneOpenContextMenu

        init(menu: PaneOpenContextMenu) {
            self.menu = menu
            super.init(delegate: menu)
        }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let view = interaction.view else { return nil }
        let items = PaneOpenMenu.items(near: view, open: open)
        guard !items.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: items.map(\.element))
        }
    }
}

extension PaneHostController {
    /// What an item menu in cell `id` offers now: nothing while the Split
    /// Panes experiment is off, as on a compact window.
    func openChoices(from id: PaneID) -> PaneOpenChoices? {
        PaneOpenChoices.resolve(
            isWide: panes.splitsEnabled && AdaptiveWidth.isWide(traitCollection),
            canAddPane: panes.tree.leaves.count < PaneLayout.maximumLeaves,
            cells: panes.cellLayout,
            source: id,
            title: { [weak self] in self?.cellTitle($0) ?? "" },
            presentation: { [weak self] in
                self?.presentation(of: $0) ?? PanePresentation(frames: [:], overflow: [], zoomedForKeyboard: nil)
            }
        )
    }

    /// Opens `content` from cell `source` where `placement` says, if the
    /// window still offers it there. A new pane takes focus and, when it
    /// cannot sit beside its pane, fills the window; both opens offer Undo.
    func open(_ content: PaneOpenContent, _ placement: PaneOpenPlacement, from source: PaneID) {
        guard let choices = openChoices(from: source), let root = AppRootEnvironment.near(self) else { return }
        // The shell's own screen for the item, when its entry cannot say all
        // of it; else the leaf builds it from the entry.
        let screen = { content.element.map { PaneSplitScreens.screen(for: $0, root: root) } }
        if let element = content.element { panes.remember(element, for: content.entry) }
        switch placement {
        case .here:
            return
        case .newPane(let edge):
            guard let newPane = edge == .bottom ? choices.below : choices.right,
                  let made = panes.open(content.entry, at: edge, ofCell: source, full: newPane == .full) else { return }
            openingScreens[made] = screen()
            syncSplitLeaves()
            openingScreens[made] = nil
        case .pane(let id):
            guard choices.targets.contains(where: { $0.id == id }) else { return }
            if id == panes.routedLeafID {
                // The routed leaf is the shell's stack: the item pushes there.
                showInRoutedLeaf(content, root: root)
                focus(cell: id)
                return
            }
            openingScreens[id] = screen()
            panes.open(content.entry, inCell: id)
            syncSplitLeaves()
            openingScreens[id] = nil
        }
        relayoutCells()
        updateVisibility()
        offerUndo()
        announceLayoutChange()
    }

    private func showInRoutedLeaf(_ content: PaneOpenContent, root: AppRootEnvironment) {
        let navigation = root.navigation
        switch content.element ?? PaneEntries.element(for: content.entry, coordinator: root.coordinator) {
        case .linkedFile(let target)?:
            navigation.openWorkspaceLinkedFile(target)
        case .fileBrowser(let target)?:
            navigation.openWorkspaceFileBrowser(target)
        default:
            navigation.pushPaneEntry(content.entry)
        }
    }
}
