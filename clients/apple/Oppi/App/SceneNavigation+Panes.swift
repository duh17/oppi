import Foundation

// The window's primary leaf as pane entries: what restoration writes and
// reads, and the `.paneEntry` screens that show a restored or linked entry's
// leaf state (`PaneLeafStateViewController`) until its content can open.
extension SceneNavigation {
    /// Shows exactly `elements` above the root, as the restored primary leaf.
    /// No scoped-lock gate runs: a locked entry arrives as a `.paneEntry`
    /// that asks only when tapped.
    func restorePrimaryStack(_ elements: [WorkspaceStackRouteElement]) {
        selectedWorkspaceFilter = elements.first.flatMap { element in
            if case .workspace(let target) = element { return target }
            return nil
        }
        workspaceStackRouteElements = elements
        if workspaceNavigationPresentation == .split {
            splitColumnVisibility = splitDetailColumn.rootIndex == nil && splitDetailColumn.pushed.isEmpty
                ? .all
                : .detailOnly
        }
    }

    /// Pushes a linked entry's leaf state above the current screens; a second
    /// tap on the same link while it shows pushes nothing.
    func pushPaneEntry(_ entry: PaneStackEntry) {
        mediaOverlayYieldsToUserNavigation()
        guard workspaceStackRouteElements.last != .paneEntry(entry) else { return }
        workspaceStackRouteElements.append(.paneEntry(entry))
    }

    /// The entry's content can open: its screen takes the entry's place. A
    /// workspace's session list is a root, not a pushed screen, so it opens
    /// as the workspace does. In the split shell a session that lands at the
    /// bottom of the detail column becomes its root, as opening it from the
    /// list makes it.
    func resolvePaneEntry(_ entry: PaneStackEntry, with element: WorkspaceStackRouteElement) {
        if case .workspace(let target) = element {
            closePaneEntry(entry)
            openWorkspace(target)
            return
        }
        guard let index = workspaceStackRouteElements.firstIndex(of: .paneEntry(entry)) else { return }
        let before = workspaceStackRouteElements
        workspaceStackRouteElements[index] = element
        panes.routedEntryResolved(from: before, to: workspaceStackRouteElements)
    }

    /// Close Pane on an entry's leaf state: the entry and what was above it
    /// go, and with them a restored chat's panel and position still waiting.
    func closePaneEntry(_ entry: PaneStackEntry) {
        panes.dropRestoredHandoffs()
        guard let index = workspaceStackRouteElements.firstIndex(of: .paneEntry(entry)) else { return }
        workspaceStackRouteElements.removeLast(workspaceStackRouteElements.count - index)
        if workspaceNavigationPresentation == .split, splitDetailColumn.rootIndex == nil, splitDetailColumn.pushed.isEmpty {
            splitColumnVisibility = .all
        }
    }

    static func paneEntryDiagnosticContext(_ entry: PaneStackEntry) -> WorkspaceStackDiagnosticContext {
        let sessionId: String? = if case .session(let id) = entry.route { id } else { nil }
        return WorkspaceStackDiagnosticContext(screen: "pane_entry", sessionId: sessionId, workspaceId: nil)
    }

    // MARK: - Removing a session

    /// Takes the session's routes off the window's stack: its chat was
    /// deleted, or its lock was refused after its route was pushed, so Back
    /// never reaches it. A session's route goes together with the screens
    /// pushed from that chat (a reader, whose lock origin was fixed when it
    /// opened), up to the next session route: another session's chat is not
    /// under this lock, so it and what is over it stay. A `.paneEntry` for the
    /// session counts as its route. In the split shell the detail column
    /// clears when the session is its root: the screens pushed over a root go
    /// with it. Returns true when the removed screens reached the top, so the
    /// person was still in this session's screens.
    @discardableResult
    func removeSessionRoute(serverId: String, sessionId: String) -> Bool {
        func matches(_ target: WorkspaceSessionNavTarget) -> Bool {
            target.serverId == serverId && target.sessionId == sessionId
        }
        /// A pane entry for a session or one of its panels stands for a
        /// session route; any other entry, for none.
        func session(of element: WorkspaceStackRouteElement) -> WorkspaceSessionNavTarget? {
            switch element {
            case .session(let target):
                return target
            case .paneEntry(let entry):
                switch entry.route {
                case .session(let id), .panel(let id, _):
                    return WorkspaceSessionNavTarget(serverId: entry.serverId, sessionId: id)
                default:
                    return nil
                }
            default:
                return nil
            }
        }
        let elements = workspaceStackRouteElements
        var removing = false
        var remaining: [WorkspaceStackRouteElement] = []
        for element in elements {
            if let target = session(of: element) { removing = matches(target) }
            if !removing { remaining.append(element) }
        }
        if workspaceNavigationPresentation == .split, let rootIndex = splitDetailColumn.rootIndex,
           let root = session(of: elements[rootIndex]), matches(root) {
            mediaOverlayYieldsToUserNavigation()
            workspaceStackRouteElements = elements[..<rootIndex].filter { element in
                if case .workspace = element { return true }
                return false
            }
            splitColumnVisibility = .all
            return removing
        }
        if remaining.count != elements.count {
            mediaOverlayYieldsToUserNavigation()
            workspaceStackRouteElements = remaining
        }
        return removing
    }
}
