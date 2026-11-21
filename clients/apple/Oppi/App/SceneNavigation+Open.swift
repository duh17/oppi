import Foundation

// The one way to show something in the window's main pane. Every sidebar row,
// list row, button, link, notification and key that shows a place, a chat or
// a page calls `SceneNavigation.open(_:from:)`, and `placement(of:from:)` is the
// one table that says where it goes. Content that can open in a pane beside
// (`PanePlacement`) comes here only when it opens in the main pane.

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
enum NavigationOrigin: Equatable {
    /// A row, button, sidebar row or key on one of the window's screens.
    /// `workspace` is the workspace that screen belongs to: the sidebar
    /// follows it, and a chat opens on its list.
    case screen(workspace: WorkspaceNavTarget? = nil)
    /// A link inside a chat (`chat`) or another page. A file linked from a
    /// chat that no longer shows opens as from `workspace`.
    case link(chat: WorkspaceSessionNavTarget? = nil, workspace: WorkspaceNavTarget? = nil)
    /// A notification, an `oppi://` link, Siri or a Shortcut: no screen of its own.
    case external

    /// An `AppOpenRequest`'s origin: outside the app, or a link inside it.
    init(_ source: SessionNavigationSource) {
        self = source == .externalURL ? .external : .link()
    }
}

/// Where the main pane puts an open.
enum MainPanePlacement: Equatable {
    /// The place is the main pane's root with nothing over it.
    case root(NavigationPlace)
    /// On the place, in place of what covered it: Back returns to the place.
    case onPlace(NavigationPlace)
    /// On top of what shows: Back returns to it. The sidebar's workspace
    /// becomes `selecting` when it names one.
    case push(selecting: WorkspaceNavTarget?)
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
    /// Shows `destination` in the main pane where `placement(of:from:)` puts
    /// it, once its scoped lock allows: a locked destination asks for device
    /// authentication and opens after success; cancel leaves the window as it
    /// was. The destination's screen gates again, which covers an unlock that
    /// expires under an open screen. Anything but an outside open is the
    /// person's own navigation, so it ends an AVKit full screen's hold on the stack.
    func open(_ destination: NavigationDestination, from origin: NavigationOrigin = .screen()) {
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
        switch placement(of: destination, from: origin) {
        case .root(let place):
            selectedWorkspaceFilter = place.workspace
            workspaceStackRouteElements = place.screen.map { [$0] } ?? []
        case .onPlace(let place):
            selectedWorkspaceFilter = place.workspace
            workspaceStackRouteElements = [place.screen, screen].compactMap { $0 }
        case .push(let workspace):
            if let workspace { selectedWorkspaceFilter = workspace }
            if let screen { workspaceStackRouteElements.append(screen) }
        case .replacingServerPages:
            var stack = workspaceStackRouteElements
            while Self.hostSwitcherDestination(from: stack.last) != nil { stack.removeLast() }
            workspaceStackRouteElements = stack + [screen].compactMap { $0 }
        case .stay:
            break
        }
    }

    /// The rule. A place is the main pane's root, except that the compact
    /// stack pushes a utility over what shows. A chat from a list sits on
    /// that list; from a link, over the screen the link is in; from outside,
    /// on the list the window shows. A page sits over its opener. Workspace
    /// Settings sits on its workspace's list in the split shell. The host
    /// switcher's jobs replace each other.
    func placement(of destination: NavigationDestination, from origin: NavigationOrigin) -> MainPanePlacement {
        let isSplit = workspaceNavigationPresentation == .split
        switch destination {
        case .place(let place):
            if case .utility = place, !isSplit { return .push(selecting: nil) }
            return .root(place)
        case .chat(let chat):
            switch origin {
            case .link:
                return visibleChatSession.map { Self.isSameSession($0, chat) } == true ? .stay : .push(selecting: nil)
            case .external:
                return .onPlace(isSplit ? .sessions(selectedWorkspaceFilter) : .allSessions)
            case .screen(let workspace):
                if isSplit {
                    switch currentPlace {
                    case .utility: return .push(selecting: nil)
                    case .sessions(let listed): return .onPlace(.sessions(listed.map { workspace ?? $0 }))
                    }
                }
                // The compact stack keeps a chat opened at All Sessions over All Sessions.
                guard let workspace, !showsAllSessionsRoot else { return .push(selecting: nil) }
                return .onPlace(.sessions(workspace))
            }
        case .page(.workspaceConfiguration(let workspace)):
            return isSplit ? .onPlace(.sessions(workspace)) : .push(selecting: workspace)
        case .page(let page):
            if page == workspaceStackRouteElements.last { return .stay }
            switch origin {
            case .screen(let workspace):
                return .push(selecting: workspace)
            case .link(let chat, let workspace):
                // Over the chat the link is in while it shows: the sidebar stays.
                let fromShownChat = chat.flatMap { chat in visibleChatSession.map { Self.isSameSession($0, chat) } } ?? false
                return .push(selecting: fromShownChat ? nil : workspace)
            case .external:
                return .push(selecting: nil)
            }
        case .serverJob(let job, _):
            guard job.shouldNavigate(from: visibleHostSwitcherDestination) else { return .stay }
            guard isSplit else { return .replacingServerPages }
            // Each job replaces the detail column beside the sidebar.
            return switch destination.screen {
            case nil: .root(.allSessions)
            case .utility(let utility)?: .root(.utility(utility))
            default: .onPlace(.allSessions)
            }
        }
    }
}
