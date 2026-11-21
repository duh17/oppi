import Foundation

// Where an open lands: one table for the window's main pane and its side
// panes. `SceneNavigation.open(_:from:beside:)` is the one entry, and it reads
// this file alone: a place replaces the main leaf's route, a chat lands on its
// list or over what shows, a page opens over its opener, and side content (a
// file, a folder, a web page, a session list, Git, a terminal, a game) fills a
// pane already showing its kind or a launcher, else opens a new pane beside
// the one it came from, else falls back to the pane its opener named.
// A side the person picks is not decided here: Open in New Pane to the Right
// or Below (`PaneOpenMenu`), a drop on a pane's edge (`+Drop`), Split Right and
// Split Down (the grip's menu and their keys), and a launcher choice, which
// fills its own pane.

/// What new content is, as the table weighs it.
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

    /// The kind an entry shows; nil for a chat, a panel, a page of a chat, a
    /// launcher, and anything a pane beside does not take.
    init?(_ route: PaneRoute) {
        switch route {
        case .file: self = .file
        case .files, .hostFiles: self = .folder
        case .browser: self = .webPage
        case .sessions: self = .sessions
        case .godot: self = .game
        case .git, .commit: self = .git
        case .local(let token):
            switch PaneLocalScreen(token) {
            case .browser?: self = .webPage
            case .terminal?: self = .terminal
            case .rex?: self = .rex
            case .godot?: self = .game
            case .launcher?, nil: return nil
            }
        case .session, .thread, .panel, .read, .unsupported: return nil
        }
    }
}

/// Where an open came from: the pane it acted in, and what that means for
/// where its content lands.
enum OpenOrigin: Equatable {
    /// A row, button, key or list on one of the window's screens, in `pane`:
    /// its content opens beside that pane, else over it. `workspace` is the
    /// workspace the screen belongs to: a chat opens on its list.
    case row(PaneID, workspace: WorkspaceNavTarget? = nil)
    /// A link in the window's content: beside the pane it was tapped in (the
    /// pane the touch focused), else in the main pane.
    case link
    /// Open Here on a link's menu: the main pane, never beside.
    case here
    /// A notification, an `oppi://` link, Siri or a Shortcut: no pane of its
    /// own. Its content opens beside the main pane, else in it.
    case external

    /// The pane the open acts in.
    func pane(focused: PaneID, mainLeaf: PaneID) -> PaneID {
        switch self {
        case .row(let id, _): id
        case .link: focused
        case .here, .external: mainLeaf
        }
    }

    /// The workspace a chat opens on, for a screen that knows it.
    var workspace: WorkspaceNavTarget? {
        if case .row(_, let workspace) = self { return workspace }
        return nil
    }
}

/// Where an open lands, in one of the window's leaves.
enum PanePlacement: Equatable {
    /// The place is `pane`'s root with nothing over it.
    case root(PaneID, NavigationPlace)
    /// On the place in `pane`, in place of what covered it: Back returns to
    /// the place.
    case onPlace(PaneID, NavigationPlace)
    /// On top of what `pane` shows: Back returns to it.
    case push(PaneID)
    /// In place of the server pages on top of `pane`: the host switcher's jobs
    /// replace each other on the compact stack.
    case replacingServerPages(PaneID)
    /// `pane` shows the content in place of what it showed.
    case reuse(PaneID)
    /// A new pane at an edge (`.right` or `.bottom`) of a pane.
    case split(PaneID, PaneEdge)
    /// It already shows.
    case stay

    /// What a pane shows, as the table weighs it.
    enum Shown: Equatable {
        case launcher
        case kind(PaneContentKind)
        case other
    }

    /// The edges a new pane tries, the chosen side's first.
    static func edges(_ side: AppPreferenceStore.NewPanes.Side, isPortrait: Bool) -> [PaneEdge] {
        switch side {
        case .automatic: isPortrait ? [.bottom, .right] : [.right, .bottom]
        case .right: [.right, .bottom]
        case .below: [.bottom, .right]
        }
    }

    /// Where side content of `kind` opened from `origin` lands.
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
    /// - On a compact window, with the window at its most panes and none to
    ///   reuse, or for Open Here, it opens where the open falls back to (over
    ///   the pane that opened it, or the main pane): nil.
    ///
    /// - Parameters:
    ///   - side: the New Panes setting for `kind`.
    ///   - cells: the window's cells (`ScenePanes.cellLayout`).
    ///   - mainLeaf: the pane that holds the chat.
    ///   - isPortrait: the window is taller than wide.
    ///   - shown: what each of the window's leaves shows.
    ///   - fits: whether a new pane at an edge of a pane keeps every pane
    ///     shown now on screen.
    static func sideContent(
        _ kind: PaneContentKind,
        from origin: OpenOrigin,
        side: AppPreferenceStore.NewPanes.Side,
        isWide: Bool,
        canAddPane: Bool,
        cells: PaneLayout,
        focused: PaneID,
        mainLeaf: PaneID,
        isPortrait: Bool,
        shown: (PaneLeaf) -> Shown,
        fits: (PaneID, PaneEdge) -> Bool
    ) -> Self? {
        let source = origin.pane(focused: focused, mainLeaf: mainLeaf)
        guard isWide, origin != .here, cells.leaf(source) != nil else { return nil }
        let candidates = cells.leaves.filter { leaf in
            leaf.id != source && leaf.id != mainLeaf && cells.collapsed[leaf.id] == nil
        }
        func recency(_ leaf: PaneLeaf) -> Int { cells.recency.firstIndex(of: leaf.id) ?? .max }
        let reusable: [Shown] = kind.replacesItsKind ? [.kind(kind), .launcher] : [.launcher]
        for wanted in reusable {
            if let reused = candidates.filter({ shown($0) == wanted }).min(by: { recency($0) < recency($1) }) {
                return .reuse(reused.id)
            }
        }
        guard canAddPane else { return nil }
        let open = cells.leaves.filter { $0.id != mainLeaf && cells.collapsed[$0.id] == nil }
        let target = source == mainLeaf ? open.min(by: { recency($0) < recency($1) })?.id ?? source : source
        let edges = edges(side, isPortrait: isPortrait)
        return .split(target, edges.first { fits(target, $0) } ?? edges[0])
    }
}

extension PanePlacement {
    /// Whether it shows the open in a pane beside, rather than in the main
    /// pane's route.
    var showsBeside: Bool {
        switch self {
        case .reuse, .split: true
        default: false
        }
    }
}

extension PaneStack {
    /// Where a destination that the window's own screens carry lands in the
    /// leaf this route belongs to: a place replaces it, a chat sits on its
    /// list or over the screen the link is in, a page sits over its opener,
    /// and the host switcher's jobs replace each other.
    ///
    /// A place replaces the pane's stack in both shells, whatever opens it:
    /// the sidebar, the drawer, a link or a key (the compact stack keeps All
    /// Sessions under it). A chat from a list sits on that list; from a link,
    /// over the screen the link is in; from outside, on the list the window
    /// shows. A page (a terminal too) sits over its opener. Workspace Settings
    /// sits on its workspace's list.
    func placement(of destination: NavigationDestination, from origin: OpenOrigin, in pane: PaneID, split: Bool) -> PanePlacement {
        // A leaf rooted at its content has no place, and the main leaf's is All
        // Sessions when it has none: both read as the window's list.
        let place = place ?? .allSessions
        switch destination {
        case .place(let place):
            return .root(pane, place)
        case .chat(let chat):
            switch origin {
            case .link:
                return shownChat.map { SceneNavigation.isSameSession($0, chat) } == true ? .stay : .push(pane)
            case .here, .external:
                return .onPlace(pane, split ? .sessions(place.workspace) : .allSessions)
            case .row(_, let workspace):
                if split {
                    switch place {
                    case .utility: return .push(pane)
                    case .sessions(let listed): return .onPlace(pane, .sessions(listed.map { workspace ?? $0 }))
                    }
                }
                // The compact stack changes the place only from one workspace's list to
                // another's; over All Sessions or a utility the chat is pushed.
                guard let workspace, case .sessions(_?) = place else { return .push(pane) }
                return .onPlace(pane, .sessions(workspace))
            }
        case .page(.workspaceConfiguration(let workspace)):
            return .onPlace(pane, .sessions(workspace))
        case .page(let page):
            return page == top ? .stay : .push(pane)
        case .serverJob(let job, _):
            guard job.shouldNavigate(from: hostSwitcherDestination) else { return .stay }
            guard split else { return .replacingServerPages(pane) }
            // Each job replaces the detail column beside the sidebar.
            return switch destination.screen {
            case nil: .root(pane, .allSessions)
            case .utility(let utility)?: .root(pane, .utility(utility))
            default: .onPlace(pane, .allSessions)
            }
        }
    }

    /// The session whose chat is on top.
    var shownChat: WorkspaceSessionNavTarget? {
        guard case .session(let chat)? = stack.last else { return nil }
        return chat
    }

    /// The host switcher's job the screen on top shows, else All Sessions.
    var hostSwitcherDestination: HostSwitcherDestination {
        SceneNavigation.hostSwitcherDestination(from: top) ?? .inbox
    }
}
