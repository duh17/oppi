import Foundation

// The window's primary leaf as pane entries: what restoration writes and
// reads, and the `.paneEntry` screens that show a restored or linked entry's
// leaf state (`PaneLeafStateViewController`) until its content can open.
extension AppNavigation {
    /// The primary leaf's screens above its root, as compact-stack elements,
    /// whichever shell is mounted.
    var primaryStackElements: [WorkspaceStackRouteElement] {
        switch workspaceNavigationPresentation {
        case .stack: workspaceStackRouteElements
        case .split: stackForCurrentSplitSelection() ?? []
        }
    }

    /// Shows exactly `elements` above the root, as the restored primary leaf.
    /// No scoped-lock gate runs: a locked entry arrives as a `.paneEntry`
    /// that asks only when tapped.
    func restorePrimaryStack(_ elements: [WorkspaceStackRouteElement]) {
        selectedWorkspaceFilter = elements.first.flatMap { element in
            if case .workspace(let target) = element { return target }
            return nil
        }
        switch workspaceNavigationPresentation {
        case .stack:
            workspaceStackRouteElements = elements
        case .split:
            let state = splitState(forStack: elements)
            splitSelectedWorkspace = state.workspace
            splitDetailTarget = state.detail
            splitDetailPathElements = state.detailPathElements
            splitColumnVisibility = state.detail == nil && state.detailPathElements.isEmpty
                ? splitVisibility(for: nil)
                : .detailOnly
        }
    }

    /// Pushes a linked entry's leaf state above the current screens; a second
    /// tap on the same link while it shows pushes nothing.
    func pushPaneEntry(_ entry: PaneStackEntry) {
        mediaOverlayYieldsToUserNavigation()
        switch workspaceNavigationPresentation {
        case .stack:
            guard workspaceStackRouteElements.last != .paneEntry(entry) else { return }
            workspaceStackRouteElements.append(.paneEntry(entry))
        case .split:
            guard splitDetailPathElements.last != .paneEntry(entry) else { return }
            splitDetailPathElements.append(.paneEntry(entry))
        }
    }

    /// The entry's content can open: its screen takes the entry's place. A
    /// workspace's session list is a root, not a pushed screen, so it opens
    /// as the workspace does.
    func resolvePaneEntry(_ entry: PaneStackEntry, with element: WorkspaceStackRouteElement) {
        if case .workspace(let target) = element {
            closePaneEntry(entry)
            openWorkspace(target)
            return
        }
        switch workspaceNavigationPresentation {
        case .stack:
            guard let index = workspaceStackRouteElements.firstIndex(of: .paneEntry(entry)) else { return }
            workspaceStackRouteElements[index] = element
        case .split:
            guard let index = splitDetailPathElements.firstIndex(of: .paneEntry(entry)),
                  let pathElement = Self.splitPathElement(element) else { return }
            // A session at the bottom of an empty detail column is its root,
            // as opening it from the list makes it.
            if index == 0, splitDetailTarget == nil, case .session(let target) = element {
                splitDetailTarget = .session(target)
                splitDetailPathElements.removeFirst()
                return
            }
            splitDetailPathElements[index] = pathElement
        }
    }

    /// Close Pane on an entry's leaf state: the entry and what was above it
    /// go, and with them a restored chat's panel and position still waiting.
    func closePaneEntry(_ entry: PaneStackEntry) {
        panes.dropRestoredHandoffs()
        switch workspaceNavigationPresentation {
        case .stack:
            guard let index = workspaceStackRouteElements.firstIndex(of: .paneEntry(entry)) else { return }
            workspaceStackRouteElements.removeLast(workspaceStackRouteElements.count - index)
        case .split:
            guard let index = splitDetailPathElements.firstIndex(of: .paneEntry(entry)) else { return }
            splitDetailPathElements.removeLast(splitDetailPathElements.count - index)
            if splitDetailTarget == nil, splitDetailPathElements.isEmpty {
                splitColumnVisibility = splitVisibility(for: nil)
            }
        }
    }

    private static func splitPathElement(_ element: WorkspaceStackRouteElement) -> WorkspaceSplitDetailPathElement? {
        switch element {
        case .session(let target): .session(target)
        case .fileBrowser(let target): .fileBrowser(target)
        case .linkedFile(let target): .linkedFile(target)
        default: nil
        }
    }

    static func paneEntryDiagnosticContext(_ entry: PaneStackEntry) -> WorkspaceStackDiagnosticContext {
        let sessionId: String? = if case .session(let id) = entry.route { id } else { nil }
        return WorkspaceStackDiagnosticContext(screen: "pane_entry", sessionId: sessionId, workspaceId: nil)
    }

    // MARK: - Removing a session

    /// Takes the session's routes off the compact stack or the split detail:
    /// its chat was deleted, or its lock was refused after its route was
    /// pushed, so Back never reaches it. A session's route goes together with
    /// the screens pushed from that chat (a reader, whose lock origin was fixed
    /// when it opened), up to the next session route: another session's chat
    /// is not under this lock, so it and what is over it stay. A `.paneEntry`
    /// for the session counts as its route. The split detail column clears
    /// when the session is its root: the screens pushed over a root go with
    /// it. Returns true when the removed screens reached the top, so the
    /// person was still in this session's screens.
    @discardableResult
    func removeSessionRoute(serverId: String, sessionId: String) -> Bool {
        func matches(_ target: WorkspaceSessionNavTarget) -> Bool {
            target.serverId == serverId && target.sessionId == sessionId
        }
        /// A pane entry for a session or one of its panels stands for a
        /// session route; any other entry, for none.
        func entrySession(_ entry: PaneStackEntry) -> WorkspaceSessionNavTarget? {
            switch entry.route {
            case .session(let id), .panel(let id, _):
                return WorkspaceSessionNavTarget(serverId: entry.serverId, sessionId: id)
            default:
                return nil
            }
        }
        switch workspaceNavigationPresentation {
        case .stack:
            let cut = Self.removingSessionBlocks(
                from: workspaceStackRouteElements,
                startsRemoving: false,
                session: { element in
                    switch element {
                    case .session(let target): target
                    case .paneEntry(let entry): entrySession(entry)
                    default: nil
                    }
                },
                matches: matches
            )
            if cut.remaining.count != workspaceStackRouteElements.count {
                mediaOverlayYieldsToUserNavigation()
                workspaceStackRouteElements = cut.remaining
            }
            return cut.reachedTop
        case .split:
            var rootMatches = false
            if case .session(let root)? = splitDetailTarget { rootMatches = matches(root) }
            let cut = Self.removingSessionBlocks(
                from: splitDetailPathElements,
                startsRemoving: rootMatches,
                session: { element in
                    switch element {
                    case .session(let target): target
                    case .paneEntry(let entry): entrySession(entry)
                    default: nil
                    }
                },
                matches: matches
            )
            if rootMatches {
                mediaOverlayYieldsToUserNavigation()
                splitDetailTarget = nil
                splitDetailPathElements = []
                splitColumnVisibility = .all
            } else if cut.remaining.count != splitDetailPathElements.count {
                mediaOverlayYieldsToUserNavigation()
                splitDetailPathElements = cut.remaining
            }
            return cut.reachedTop
        }
    }

    /// Drops each matching session element and every element after it up to
    /// the next session element. `reachedTop` is true when the last dropped
    /// block extends to the end, so nothing of another session is above it.
    /// `startsRemoving` treats the screens before the first session element as
    /// part of a removed block (a split detail whose root is the session).
    private static func removingSessionBlocks<Element>(
        from elements: [Element],
        startsRemoving: Bool,
        session: (Element) -> WorkspaceSessionNavTarget?,
        matches: (WorkspaceSessionNavTarget) -> Bool
    ) -> (remaining: [Element], reachedTop: Bool) {
        var removing = startsRemoving
        var remaining: [Element] = []
        for element in elements {
            if let target = session(element) { removing = matches(target) }
            if !removing { remaining.append(element) }
        }
        return (remaining, removing)
    }
}
