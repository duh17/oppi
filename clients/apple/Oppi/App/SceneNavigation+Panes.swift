import Foundation

// The main leaf's route and the `.entry` screens that show a restored or
// linked entry's leaf state (`PaneLeafStateViewController`) until its content
// can open.
extension SceneNavigation {
    /// Applies the main leaf's restored route through `mainPaneRoute`'s setter:
    /// the window's route is written here, by its owner, never by the panes
    /// (`uikit-structure-guard` counts a main-pane stack write outside it).
    func restoreMainRoute(_ route: PaneStack) { mainPaneRoute = route }

    /// The entry's content can open: its screen takes the entry's place. A
    /// workspace's session list is a place, not a pushed screen, so it opens
    /// as the workspace does.
    func resolvePaneEntry(_ entry: PaneStackEntry, with element: WorkspaceStackRouteElement) {
        if case .workspace(let target) = element {
            closePaneEntry(entry)
            open(.place(.sessions(target)))
            return
        }
        guard let index = mainPaneRoute.stack.firstIndex(of: .entry(entry)) else { return }
        let before = workspaceStackRouteElements
        mainPaneRoute.stack[index] = element
        panes.mainEntryResolved(from: before, to: workspaceStackRouteElements)
        if case .session = element {
            repairChatsPerServer()
        }
    }

    /// Close Pane on an entry's leaf state: the entry and what was above it
    /// go, and with them a restored chat's panel and position still waiting.
    func closePaneEntry(_ entry: PaneStackEntry) {
        panes.dropRestoredHandoffs()
        guard let index = mainPaneRoute.stack.firstIndex(of: .entry(entry)) else { return }
        mainPaneRoute.stack.removeLast(mainPaneRoute.stack.count - index)
    }

    static func paneEntryDiagnosticContext(_ entry: PaneStackEntry) -> WorkspaceStackDiagnosticContext {
        let sessionId: String? = if case .session(let id) = entry.route { id } else { nil }
        return WorkspaceStackDiagnosticContext(screen: "pane_entry", sessionId: sessionId, workspaceId: nil)
    }

    // MARK: - Removing a session

    /// Takes the session's routes off every leaf of the window: its chat was
    /// deleted, or its lock was refused after its route was pushed, so Back
    /// never reaches it. A session's route goes together with the screens
    /// pushed from that chat (a reader, whose lock origin was fixed when it
    /// opened), up to the next session route: another session's chat is not
    /// under this lock, so it and what is over it stay. A `.entry` for the
    /// session counts as its route. A side leaf that showed only this chat
    /// closes with it, as a deleted session's pane does. Returns true when the
    /// removed screens reached the top of a leaf, so the person was still in
    /// this session's screens.
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
            case .entry(let entry):
                switch entry.route {
                case .session(let id), .panel(let id, _), .read(let id, _):
                    return WorkspaceSessionNavTarget(serverId: entry.serverId, sessionId: id)
                default:
                    return nil
                }
            default:
                return nil
            }
        }
        var wasVisible = false
        for id in panes.tree.leaves.map(\.id) {
            guard var route = panes.stack(of: id) else { continue }
            let elements = route.stack
            var removing = false
            var remaining: [WorkspaceStackRouteElement] = []
            for element in elements {
                if let target = session(of: element) { removing = matches(target) }
                if !removing { remaining.append(element) }
            }
            guard remaining.count != elements.count else { continue }
            wasVisible = wasVisible || removing
            if remaining.isEmpty, id != panes.mainLeafID {
                // A side leaf shows its content alone: this chat was all of it.
                panes.close(id)
                continue
            }
            route.stack = remaining
            if id == panes.mainLeafID { mediaOverlayYieldsToUserNavigation() }
            setRoute(route, in: id)
        }
        return wasVisible
    }
}
