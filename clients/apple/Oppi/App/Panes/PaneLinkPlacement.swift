import UIKit

// A tapped link's file, folder or web page lands in a pane beside the pane it
// was tapped in, on a wide window with Split Panes on; everywhere else it
// opens as it always did, in the main pane (a web page: Safari's sheet). The
// host's `openLink` is the one place that decides, for every file and folder
// the opener resolves (`AppOpener.openBesideFocusedPane`) and every in-app web
// page (`openBrowser`). A long press offers the explicit choices instead
// (`PaneOpenMenu`).

/// What a link shows in a pane.
enum PaneLinkKind: Equatable, Sendable {
    case file
    case folder
    case webPage
}

/// Where a tapped link's content lands, from the pane it was tapped in.
///
/// - A pane already showing the same kind of thing (a file, a folder, a web
///   page) takes it, else an empty New Pane launcher, the most recently used
///   first, so taps do not pile up panes. The chat, the pane the link was
///   tapped in, a terminal, Rex and a game are never replaced.
/// - Otherwise a new pane opens where there is most room: to the right in a
///   landscape window, below in a portrait one, or the other way when only
///   that fits. When neither fits, it opens on the window's side anyway and
///   the least recently used pane moves to Hidden Panes, as the fit rule
///   does for any new pane (build plan §1.3).
/// - The first new pane splits the pane the link was tapped in. From the chat
///   with other panes open, it splits the most recently used of those
///   instead, so the chat keeps its share and is not squeezed to its
///   minimum by each link.
/// - On a compact window, with Split Panes off, or with the window at its
///   most panes and none to reuse, it opens in the main pane.
enum PaneLinkPlacement: Equatable {
    case reuse(PaneID)
    /// A new pane at an edge (`.right` or `.bottom`) of a pane.
    case split(PaneID, PaneEdge)
    case mainPane

    /// What a pane shows, as the placement weighs it.
    enum Shown: Equatable {
        case launcher
        case kind(PaneLinkKind)
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
        case .local(let token)?:
            switch PaneLocalScreen(token) {
            case .launcher?: return .launcher
            case .browser?: return .kind(.webPage)
            case .terminal?, .rex?, .godot?, nil: return .other
            }
        default: return .other
        }
    }

    /// - Parameters:
    ///   - cells: the window's cells (`ScenePanes.cellLayout`).
    ///   - source: the cell the link was tapped in.
    ///   - routedLeaf: the main pane, which holds the chat.
    ///   - isPortrait: the window is taller than wide.
    ///   - fits: whether a new pane at an edge of a pane keeps every pane
    ///     shown now on screen.
    static func resolve(
        _ kind: PaneLinkKind,
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
        for wanted in [Shown.kind(kind), .launcher] {
            if let reused = candidates.filter({ shown($0) == wanted }).min(by: { recency($0) < recency($1) }) {
                return .reuse(reused.id)
            }
        }
        guard canAddPane else { return .mainPane }
        let open = cells.leaves.filter { $0.id != routedLeaf && cells.collapsed[$0.id] == nil }
        let target = source == routedLeaf ? open.min(by: { recency($0) < recency($1) })?.id ?? source : source
        let edges: [PaneEdge] = isPortrait ? [.bottom, .right] : [.right, .bottom]
        return .split(target, edges.first { fits(target, $0) } ?? edges[0])
    }
}

extension PaneHostController {
    /// Opens a tapped link's `content` beside the focused pane, where
    /// `PaneLinkPlacement` puts it, and focuses that pane. False when it
    /// belongs in the main pane: the caller opens it there as before.
    @discardableResult
    func openLink(_ content: PaneOpenContent, kind: PaneLinkKind) -> Bool {
        let source = focusedCell
        let cells = panes.cellLayout
        let placement = PaneLinkPlacement.resolve(
            kind,
            isWide: panes.splitsEnabled && AdaptiveWidth.isWide(traitCollection),
            canAddPane: panes.tree.leaves.count < PaneLayout.maximumLeaves,
            cells: cells,
            source: source,
            routedLeaf: panes.routedLeafID,
            isPortrait: view.bounds.height > view.bounds.width,
            shown: { [panes] leaf in
                guard case .local(let token)? = leaf.stack.last?.route else { return PaneLinkPlacement.shown(leaf.stack.last) }
                switch panes.standIns[token] {
                case .linkedFile?: return .kind(.file)
                case .fileBrowser?: return .kind(.folder)
                default: return PaneLinkPlacement.shown(leaf.stack.last)
                }
            },
            fits: { [weak self] target, edge in
                guard let self else { return false }
                return PaneOpenChoices.fits(edge, of: target, in: cells, showing: content.entry.route) { self.presentation(of: $0) }
            }
        )
        let root = AppRootEnvironment.near(self)
        if let element = content.element { panes.remember(element, for: content.entry) }
        let screen = { content.element.flatMap { element in root.map { PaneSplitScreens.screen(for: element, root: $0) } } }
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
