import Foundation

// The one way to show something in the window's main pane. Every sidebar row,
// list row, button, link, notification and key that shows a place, a chat or
// a page calls `SceneNavigation.open(_:from:)`, and
// `MainPaneRoute.placement(of:from:split:)` is the one table that says where
// it goes. Content that can open in a pane beside (`SidePanePlacement`) comes here
// only when it opens in the main pane.

/// What an open shows in the main pane.
enum NavigationDestination: Equatable {
    /// A sidebar row: All Sessions, a workspace's sessions, a utility.
    case place(NavigationPlace)
    /// A session's chat.
    case chat(WorkspaceSessionNavTarget)
    /// A screen that belongs to what it was opened from: a file, a folder, a
    /// reader, Workspace Settings, a server page, a linked entry's leaf state.
    case page(WorkspaceStackRouteElement)
    /// One of the host switcher's jobs on a server.
    case serverJob(HostSwitcherDestination, serverId: String)

    /// The screen the open puts in the stack; nil for All Sessions, which is
    /// the stack's bottom, and for the host switcher's list.
    var screen: WorkspaceStackRouteElement? {
        switch self {
        case .place(let place): place.screen
        case .chat(let chat): .session(chat)
        case .page(let page): page
        case .serverJob(let job, let serverId):
            switch job {
            case .inbox: nil
            case .usage: .utility(.manageServers)
            case .serverMetrics: .utility(.serverMetrics)
            case .serverSettings: .serverDetails(ServerDetailsNavTarget(serverId: serverId))
            case .modelProviders: .modelProviders(ModelProvidersNavTarget(serverId: serverId))
            }
        }
    }

    /// The scoped lock that must allow the open: the workspace a list,
    /// folder or Workspace Settings belongs to, the session of a chat, a file's.
    @MainActor var lockTarget: ScopedLockTarget? {
        switch screen {
        case .workspace(let workspace)?, .workspaceConfiguration(let workspace)?:
            .workspace(serverId: workspace.serverId, workspaceId: workspace.workspace.id)
        case .session(let chat)?:
            ScopedLockService.shared.sessionTarget(
                serverId: chat.serverId,
                sessionId: chat.sessionId,
                workspaceId: chat.workspaceId
            )
        case .linkedFile(let file)?:
            WorkspaceLinkedFileViewController.lockTarget(for: file)
        case .fileBrowser(let folder)?:
            if case .workspace(let workspaceId, _) = folder.scope {
                .workspace(serverId: folder.serverId, workspaceId: workspaceId)
            } else {
                nil
            }
        default:
            nil
        }
    }
}

/// Where an open comes from, which decides what Back returns to.
enum MainPaneOrigin: Equatable {
    /// A row, button, sidebar row or key on one of the window's screens.
    /// `workspace` is the workspace that screen belongs to: a chat opens on
    /// its list.
    case screen(workspace: WorkspaceNavTarget? = nil)
    /// A link inside a chat or another page: it keeps the back stack.
    case link
    /// A notification, an `oppi://` link, Siri or a Shortcut: no screen of its own.
    case external
}

/// Where the main pane puts an open.
enum MainPanePlacement: Equatable {
    /// The place is the main pane's root with nothing over it.
    case root(NavigationPlace)
    /// On the place, in place of what covered it: Back returns to the place.
    case onPlace(NavigationPlace)
    /// On top of what shows: Back returns to it.
    case push
    /// In place of the server pages on top: the host switcher's jobs replace
    /// each other on the compact stack.
    case replacingServerPages
    /// It already shows.
    case stay
}

extension NavigationPlace {
    /// The place's screen in the stack: nil for All Sessions, the stack's bottom.
    var screen: WorkspaceStackRouteElement? {
        switch self {
        case .sessions(let workspace): workspace.map { .workspace($0) }
        case .utility(let utility): .utility(utility)
        }
    }

    var workspace: WorkspaceNavTarget? {
        if case .sessions(let workspace) = self { return workspace }
        return nil
    }
}

extension SceneNavigation {
    /// Shows `destination` in the main pane where
    /// `MainPaneRoute.placement(of:from:split:)` puts it, once its scoped lock
    /// allows: a locked destination asks for device authentication and opens
    /// after success; cancel leaves the window as it was. The destination's screen gates again, which covers an unlock that
    /// expires under an open screen. Anything but an outside open is the
    /// person's own navigation, so it ends an AVKit full screen's hold on the stack.
    func open(_ destination: NavigationDestination, from origin: MainPaneOrigin = .screen()) {
        var destination = destination
        if case .chat(let chat) = destination, case .screen(let workspace?) = origin {
            destination = .chat(chat.withWorkspaceIdIfMissing(workspace.workspace.id))
        }
        if let lock = destination.lockTarget, !ScopedLockService.shared.gate(lock, onUnlock: { [weak self, destination] in
            self?.open(destination, from: origin)
        }) {
            return
        }
        if origin != .external { mediaOverlayYieldsToUserNavigation() }
        let screen = destination.screen
        let placement = mainPaneRoute.placement(of: destination, from: origin, split: workspaceNavigationPresentation == .split)
        switch placement {
        case .root(let place):
            mainPaneRoute = MainPaneRoute(place: place)
        case .onPlace(let place):
            mainPaneRoute = MainPaneRoute(place: place, stack: [screen].compactMap { $0 })
        case .push:
            if let screen { mainPaneRoute.stack.append(screen) }
        case .replacingServerPages:
            var route = mainPaneRoute
            while Self.hostSwitcherDestination(from: route.stack.last) != nil { route.stack.removeLast() }
            // A server page at the root (Usage, kept from the split shell) goes too.
            if route.stack.isEmpty, Self.hostSwitcherDestination(from: route.place.screen) != nil {
                route.place = .allSessions
            }
            route.stack += [screen].compactMap { $0 }
            mainPaneRoute = route
        case .stay:
            break
        }
    }
}

extension MainPaneRoute {
    /// The rule, read from this route and the window's shell alone. A place
    /// replaces the main pane's stack in both shells, whatever opens it: the
    /// sidebar, the drawer, a link or a key (the compact stack keeps All
    /// Sessions under it). A chat from a list sits on that list; from a link,
    /// over the screen the link is in; from outside, on the list the window
    /// shows. A page (a terminal too) sits over its opener. Workspace
    /// Settings sits on its workspace's list. The host switcher's jobs
    /// replace each other.
    func placement(of destination: NavigationDestination, from origin: MainPaneOrigin, split: Bool) -> MainPanePlacement {
        switch destination {
        case .place(let place):
            return .root(place)
        case .chat(let chat):
            switch origin {
            case .link:
                return shownChat.map { SceneNavigation.isSameSession($0, chat) } == true ? .stay : .push
            case .external:
                return .onPlace(split ? .sessions(place.workspace) : .allSessions)
            case .screen(let workspace):
                if split {
                    switch place {
                    case .utility: return .push
                    case .sessions(let listed): return .onPlace(.sessions(listed.map { workspace ?? $0 }))
                    }
                }
                // The compact stack changes the place only from one workspace's list to
                // another's; over All Sessions or a utility the chat is pushed.
                guard let workspace, case .sessions(_?) = place else { return .push }
                return .onPlace(.sessions(workspace))
            }
        case .page(.workspaceConfiguration(let workspace)):
            return .onPlace(.sessions(workspace))
        case .page(let page):
            return page == top ? .stay : .push
        case .serverJob(let job, _):
            guard job.shouldNavigate(from: hostSwitcherDestination) else { return .stay }
            guard split else { return .replacingServerPages }
            // Each job replaces the detail column beside the sidebar.
            return switch destination.screen {
            case nil: .root(.allSessions)
            case .utility(let utility)?: .root(.utility(utility))
            default: .onPlace(.allSessions)
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
