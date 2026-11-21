import UIKit

// Where side content goes when nothing says: the one owner for every opener
// that shows a file, folder, Git, web page, session list, terminal, Rex or
// game without the person picking a side. A link (`AppOpener.openSideContent`,
// `openBrowser`) and a screen's own row or button (`PaneHostController.open(_:kind:from:otherwise:)`:
// a path in a terminal, the File Browser's row, the chat bar's Terminal, a Rex
// link) all come through the host's `openBeside`, which reads its source pane
// from `SideContentOrigin` and its placement from `PanePlacement`. When no pane
// beside takes it, a link opens it in the main pane (`SceneNavigation.open`)
// and a screen pushes it over itself. A side the person picks is not decided
// here: Open in New Pane to the Right or Below (`PaneOpenMenu`), a drop on a
// pane's edge (`+Drop`), Split Right and Split Down (the grip's menu and their
// keys), and a launcher choice, which fills its own pane.

/// What a new pane shows, as the placement weighs it.
enum PaneContentKind: Equatable, Sendable, CaseIterable {
    case file
    case folder
    case webPage
    case sessions
    case terminal
    case rex
    case game
    /// A workspace's Git or one commit.
    case git

    /// The New Panes setting that picks this kind's side.
    var setting: AppPreferenceStore.NewPanes.Kind {
        switch self {
        // Git and commits are files' kin: they open where files do.
        case .file, .folder, .git: .files
        case .webPage: .web
        case .sessions: .sessions
        case .terminal, .rex: .terminal
        case .game: .games
        }
    }

    /// Whether a pane already showing this kind takes another in its place.
    /// A terminal, Rex and a game are live surfaces of their own: one is
    /// never replaced, so another always gets an empty launcher or a new pane.
    var replacesItsKind: Bool {
        switch self {
        case .file, .folder, .webPage, .sessions, .git: true
        case .terminal, .rex, .game: false
        }
    }
}

/// Where side content was opened from: the pane it opens beside, and where it
/// goes when no pane beside takes it.
enum SideContentOrigin: Equatable {
    /// A row, button or link in a screen that opens it itself, in pane `id`:
    /// beside that pane, else over the screen in its own pane.
    case pane(PaneID)
    /// A link in the window's content (a chat's text, a pin, an extension
    /// tile): beside the pane it was tapped in, which the touch focused; else
    /// in the main pane.
    case focusedPane
    /// An `oppi://` link from outside the app (a share, Shortcuts, another
    /// app): it has no pane, so it opens beside the main pane whichever pane
    /// was touched last; else in the main pane.
    case external
    /// Open Here on a link's menu: in the main pane, never beside.
    case mainPane
}

/// Where new content lands, from the pane it was opened from.
///
/// - A pane already showing the same kind of thing (a file, a folder, a web
///   page, a session list) takes it, else an empty New Pane launcher, the
///   most recently used first, so opens do not pile up panes. The chat, the
///   source pane, a terminal, Rex and a game are never replaced.
/// - Otherwise a new pane opens on the kind's side (`NewPanes.Side`, a
///   terminal below by default): Automatic is to the right in a landscape
///   window and below in a portrait one. When only the other side fits, it
///   opens there. When neither fits, it opens on the chosen side anyway and
///   the least recently used pane moves to Hidden Panes, as the fit rule
///   does for any new pane (build plan §1.3).
/// - The first new pane splits the source pane. From the chat with other
///   panes open, it splits the most recently used of those instead, so the
///   chat keeps its share and is not squeezed to its minimum by each open.
/// - A file that opens to the right takes its reading width of the pane it
///   splits (`PaneReadingWidth`); every other new pane takes half.
/// - On a compact window, or with the window at its
///   most panes and none to reuse, it opens in the main pane.
enum PanePlacement: Equatable {
    case reuse(PaneID)
    /// A new pane at an edge (`.right` or `.bottom`) of a pane.
    case split(PaneID, PaneEdge)
    case mainPane

    /// What a pane shows, as the placement weighs it.
    enum Shown: Equatable {
        case launcher
        case kind(PaneContentKind)
        case other
    }

    /// What a pane whose top entry is `entry` shows. An entry with no link
    /// that stands in for a screen (a file opened from a chat) is the host's
    /// to name.
    static func shown(_ entry: PaneStackEntry?) -> Shown {
        switch entry?.route {
        case .file?: return .kind(.file)
        case .files?, .hostFiles?: return .kind(.folder)
        case .browser?: return .kind(.webPage)
        case .sessions?: return .kind(.sessions)
        case .godot?: return .kind(.game)
        case .git?, .commit?: return .kind(.git)
        case .local(let token)?:
            switch PaneLocalScreen(token) {
            case .launcher?: return .launcher
            case .browser?: return .kind(.webPage)
            case .terminal?: return .kind(.terminal)
            case .rex?: return .kind(.rex)
            case .godot?: return .kind(.game)
            case nil: return .other
            }
        default: return .other
        }
    }

    /// The pane content from `origin` opens beside: nil when it opens in the
    /// main pane without trying beside.
    static func source(of origin: SideContentOrigin, focused: PaneID, mainPane: PaneID) -> PaneID? {
        switch origin {
        case .pane(let id): id
        case .focusedPane: focused
        case .external: mainPane
        case .mainPane: nil
        }
    }

    /// The edges a new pane tries, the chosen side's first.
    static func edges(_ side: AppPreferenceStore.NewPanes.Side, isPortrait: Bool) -> [PaneEdge] {
        switch side {
        case .automatic: isPortrait ? [.bottom, .right] : [.right, .bottom]
        case .right: [.right, .bottom]
        case .below: [.bottom, .right]
        }
    }

    /// - Parameters:
    ///   - side: the New Panes setting for `kind`.
    ///   - cells: the window's cells (`ScenePanes.cellLayout`).
    ///   - source: the cell the content was opened from.
    ///   - routedLeaf: the main pane, which holds the chat.
    ///   - isPortrait: the window is taller than wide.
    ///   - fits: whether a new pane at an edge of a pane keeps every pane
    ///     shown now on screen.
    static func resolve(
        _ kind: PaneContentKind,
        side: AppPreferenceStore.NewPanes.Side,
        isWide: Bool,
        canAddPane: Bool,
        cells: PaneLayout,
        source: PaneID,
        routedLeaf: PaneID,
        isPortrait: Bool,
        shown: (PaneLeaf) -> Shown,
        fits: (PaneID, PaneEdge) -> Bool
    ) -> Self {
        guard isWide, cells.leaf(source) != nil else { return .mainPane }
        let candidates = cells.leaves.filter { leaf in
            leaf.id != source && leaf.id != routedLeaf && cells.collapsed[leaf.id] == nil
        }
        func recency(_ leaf: PaneLeaf) -> Int { cells.recency.firstIndex(of: leaf.id) ?? .max }
        let reusable: [Shown] = kind.replacesItsKind ? [.kind(kind), .launcher] : [.launcher]
        for wanted in reusable {
            if let reused = candidates.filter({ shown($0) == wanted }).min(by: { recency($0) < recency($1) }) {
                return .reuse(reused.id)
            }
        }
        guard canAddPane else { return .mainPane }
        let open = cells.leaves.filter { $0.id != routedLeaf && cells.collapsed[$0.id] == nil }
        let target = source == routedLeaf ? open.min(by: { recency($0) < recency($1) })?.id ?? source : source
        let edges = edges(side, isPortrait: isPortrait)
        return .split(target, edges.first { fits(target, $0) } ?? edges[0])
    }
}

extension PaneHostController {
    /// Side content `opener` opens itself (a path in a terminal, the File
    /// Browser's row, the chat bar's Terminal, a Rex link): beside the
    /// opener's pane where `PanePlacement` puts it, else `otherwise`, which
    /// shows it over the opener in its own pane.
    static func open(
        _ content: PaneOpenContent,
        kind: PaneContentKind,
        from opener: UIViewController,
        otherwise: () -> Void
    ) {
        if let host = containing(opener), let cell = host.cell(holding: opener),
           host.openBeside(content, kind: kind, from: .pane(cell)) { return }
        otherwise()
    }

    /// Opens `content` in a pane beside the pane `origin` names, where
    /// `PanePlacement` puts it, and focuses that pane; a game already shown
    /// in a pane is focused there. False when no pane beside takes it: the
    /// opener shows it in the main pane, or over itself (`SideContentOrigin`).
    @discardableResult
    func openBeside(
        _ content: PaneOpenContent,
        kind: PaneContentKind,
        from origin: SideContentOrigin = .focusedPane
    ) -> Bool {
        guard let source = PanePlacement.source(of: origin, focused: focusedCell, mainPane: panes.routedLeafID) else {
            return false
        }
        if kind == .game, AdaptiveWidth.isWide(traitCollection),
           let shown = panes.cellLayout.leaves.first(where: { $0.stack.last == content.entry }) {
            focus(cell: shown.id)
            return true
        }
        let cells = panes.cellLayout
        let placement = PanePlacement.resolve(
            kind,
            side: AppPreferenceStore.NewPanes.side(for: kind.setting, in: panes.preferences),
            isWide: AdaptiveWidth.isWide(traitCollection),
            canAddPane: panes.tree.leaves.count < PaneLayout.maximumLeaves,
            cells: cells,
            source: source,
            routedLeaf: panes.routedLeafID,
            isPortrait: view.bounds.height > view.bounds.width,
            shown: placementShown,
            fits: { [weak self] target, edge in
                guard let self else { return false }
                return PaneOpenChoices.fits(edge, of: target, in: cells, showing: content.entry.route) { self.presentation(of: $0) }
            }
        )
        // Only a pane that takes the item builds its screen from what the item remembers.
        func remember() { if let element = content.element { panes.remember(element, for: content.entry) } }
        switch placement {
        case .mainPane:
            return false
        case .reuse(let id):
            if case .browser(let url) = content.entry.route,
               let browser = frontScreen(ofCell: id) as? BrowserPaneViewController {
                // A live page loads the link in place, keeping its history.
                browser.open(url)
            } else {
                remember()
                panes.show(content.entry, in: id)
                syncSplitLeaves()
            }
            focus(cell: id)
        case .split(let target, let edge):
            // A file beside a pane reads at its reading width; anything else,
            // or a pane below, halves the cell.
            let share = kind == .file && edge == .right ? readerShare(beside: target) : nil
            remember()
            guard let made = panes.split(target, edge: edge, showing: content.entry, share: share) else { return false }
            syncSplitLeaves()
            focus(cell: made)
        }
        announceLayoutChange()
        return true
    }

    /// The share of `target`'s cell a reader split off its trailing edge takes
    /// (`PaneReadingWidth.splitShare`).
    private func readerShare(beside target: PaneID) -> Double? {
        guard let width = cellFrame(target)?.width, let leaf = panes.cellLayout.leaf(target) else { return nil }
        return PaneReadingWidth.splitShare(of: width, neighbourMinimum: minimumSize(of: leaf).width)
    }

    /// What `leaf` shows as the placement weighs it, naming the screen an
    /// entry with no link of its own holds (a file or folder opened from a chat).
    func placementShown(_ leaf: PaneLeaf) -> PanePlacement.Shown {
        guard let top = leaf.stack.last, case .local = top.route else { return PanePlacement.shown(leaf.stack.last) }
        switch panes.standIns[top] {
        case .linkedFile?: return .kind(.file)
        case .fileBrowser?: return .kind(.folder)
        default: return PanePlacement.shown(leaf.stack.last)
        }
    }
}
