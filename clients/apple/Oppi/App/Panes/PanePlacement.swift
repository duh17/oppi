import UIKit

// Where a new pane goes when nothing says: the one owner for every opener
// that makes a pane without the person picking a side. A tapped file, folder,
// web, sessions or Rex link (`AppOpener.openBesideFocusedPane`, `openBrowser`,
// `SSHTerminalOpenRoute`), a Godot link (`openGodot`) and the chat bar's
// Terminal all come through the host's `openBeside`. A side the person picks
// is not decided here: Open in New Pane to the Right or Below (`PaneOpenMenu`),
// a drop on a pane's edge (`+Drop`), Split Right and Split Down (the grip's
// menu and their keys), and a launcher choice, which fills its own pane.
// Everywhere else (a compact window, Split Panes off) the opener shows the
// content as it always did, in the main pane.

/// What a new pane shows, as the placement weighs it.
enum PaneContentKind: Equatable, Sendable, CaseIterable {
    case file
    case folder
    case webPage
    case sessions
    case terminal
    case rex
    case game

    /// The New Panes setting that picks this kind's side.
    var setting: AppPreferenceStore.NewPanes.Kind {
        switch self {
        case .file, .folder: .files
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
        case .file, .folder, .webPage, .sessions: true
        case .terminal, .rex, .game: false
        }
    }
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
/// - On a compact window, with Split Panes off, or with the window at its
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
    /// Opens `content` in a pane beside `source` (the focused pane when nil),
    /// where `PanePlacement` puts it, and focuses that pane. `screen` is the
    /// screen the pane shows when its entry cannot build it (a folder
    /// terminal, a Rex host's list). False when it belongs in the main pane:
    /// the caller opens it there as before.
    @discardableResult
    func openBeside(
        _ content: PaneOpenContent,
        kind: PaneContentKind,
        from source: PaneID? = nil,
        screen: UIViewController? = nil
    ) -> Bool {
        let source = source ?? focusedCell
        let cells = panes.cellLayout
        let placement = PanePlacement.resolve(
            kind,
            side: AppPreferenceStore.NewPanes.side(for: kind.setting, in: panes.preferences),
            isWide: panes.splitsEnabled && AdaptiveWidth.isWide(traitCollection),
            canAddPane: panes.tree.leaves.count < PaneLayout.maximumLeaves,
            cells: cells,
            source: source,
            routedLeaf: panes.routedLeafID,
            isPortrait: view.bounds.height > view.bounds.width,
            shown: { [panes] leaf in
                guard case .local(let token)? = leaf.stack.last?.route else { return PanePlacement.shown(leaf.stack.last) }
                switch panes.standIns[token] {
                case .linkedFile?: return .kind(.file)
                case .fileBrowser?: return .kind(.folder)
                default: return PanePlacement.shown(leaf.stack.last)
                }
            },
            fits: { [weak self] target, edge in
                guard let self else { return false }
                return PaneOpenChoices.fits(edge, of: target, in: cells, showing: content.entry.route) { self.presentation(of: $0) }
            }
        )
        let root = AppRootEnvironment.near(self)
        if let element = content.element { panes.remember(element, for: content.entry) }
        let screen = { screen ?? content.element.flatMap { element in root.map { PaneSplitScreens.screen(for: element, root: $0) } } }
        switch placement {
        case .mainPane:
            return false
        case .reuse(let id):
            if case .browser(let url) = content.entry.route,
               let browser = frontScreen(ofCell: id) as? BrowserPaneViewController {
                // A live page loads the link in place, keeping its history.
                browser.open(url)
            } else {
                openingScreens[id] = screen()
                panes.show(content.entry, in: id)
                syncSplitLeaves()
                openingScreens[id] = nil
            }
            focus(cell: id)
        case .split(let target, let edge):
            guard let made = panes.split(target, edge: edge, showing: content.entry) else { return false }
            openingScreens[made] = screen()
            syncSplitLeaves()
            openingScreens[made] = nil
            focus(cell: made)
        }
        announceLayoutChange()
        return true
    }
}
