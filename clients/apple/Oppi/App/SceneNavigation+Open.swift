import Foundation

// The one way to show something in the window. Every sidebar row, list row,
// button, link, notification and key calls `SceneNavigation.open(_:from:)`,
// and `PanePlacement` is the one table that says where it lands: the main
// pane's route, or a pane beside for side content (a file, a folder, a web
// page, a session list, Git, a terminal, a game).

/// What an open shows.
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
    /// Shows `destination` where the table puts it, once its scoped lock
    /// allows: a locked destination asks for device authentication and opens
    /// after success; cancel leaves the window as it was. The destination's screen gates again, which covers an unlock that
    /// expires under an open screen. Anything but an outside open is the
    /// person's own navigation, so it ends an AVKit full screen's hold on the stack.
    ///
    /// `origin` is what the open acted in; nil is the main pane's own screens.
    /// `beside` names what kind of side content the destination is: a pane
    /// already showing that kind (or a launcher) takes it in place of what it
    /// showed, else a new pane opens beside the pane `origin` names, else the
    /// content falls back to its opener's pane or the main pane.
    /// `beforeMain` runs just before that main-pane open (a chat freezes its
    /// viewport before a file covers it), and `opensInMainPane` is false for a
    /// caller that shows its own fallback and only reads where it landed.
    @discardableResult
    func open(
        _ destination: NavigationDestination,
        from origin: OpenOrigin? = nil,
        beside kind: PaneContentKind? = nil,
        opensInMainPane: Bool = true,
        beforeMain: @escaping () -> Void = {}
    ) -> PanePlacement {
        let origin = origin ?? .row(panes.mainLeafID)
        var destination = destination
        if case .chat(let chat) = destination, let workspace = origin.workspace {
            destination = .chat(chat.withWorkspaceIdIfMissing(workspace.workspace.id))
        }
        if let lock = destination.lockTarget, !ScopedLockService.shared.gate(lock, onUnlock: { [weak self, destination, origin, kind, opensInMainPane, beforeMain] in
            self?.open(destination, from: origin, beside: kind, opensInMainPane: opensInMainPane, beforeMain: beforeMain)
        }) {
            return .stay
        }
        if origin != .external { mediaOverlayYieldsToUserNavigation() }
        if let kind, let route = destination.screen,
           let beside = paneArea?.sidePlacement(of: kind, showing: route, from: origin),
           let pane = paneArea, pane.showBeside(route, kind: kind, beside) {
            return beside
        }
        let placement = fallback(of: destination, from: origin)
        // A caller that shows its own fallback (Safari's sheet for a web link)
        // reads the placement instead of opening anything.
        guard opensInMainPane else { return placement }
        beforeMain()
        apply(placement, destination)
        return placement
    }

    /// Where the open lands when no pane beside takes it: over the pane that
    /// opened it (a screen's own row), else where the main pane's rule puts it.
    private func fallback(of destination: NavigationDestination, from origin: OpenOrigin) -> PanePlacement {
        if case .row(let pane, _) = origin, case .page(let page) = destination, !page.isChat, pane != panes.mainLeafID {
            return .push(pane)
        }
        let main = panes.mainLeafID
        guard let route = panes.stack(of: main) else { return .push(main) }
        return route.placement(of: destination, from: origin, in: main, split: isSplit)
    }

    /// `isSplit` reads the window's shell.
    private var isSplit: Bool { workspaceNavigationPresentation == .split }

    /// Shows a main-pane placement. A pane beside is the host's arm, already
    /// taken before this (`PaneHostController.showBeside`).
    private func apply(_ placement: PanePlacement, _ destination: NavigationDestination) {
        switch placement {
        case .root(let pane, let place):
            setRoute(PaneStack(place: place), in: pane)
        case .onPlace(let pane, let place):
            setRoute(PaneStack(place: place, stack: [destination.screen].compactMap { $0 }), in: pane)
        case .push(let pane):
            guard let screen = destination.screen else { return }
            var route = panes.stack(of: pane) ?? PaneStack()
            route.stack.append(screen)
            setRoute(route, in: pane)
        case .replacingServerPages(let pane):
            var route = panes.stack(of: pane) ?? PaneStack()
            while Self.hostSwitcherDestination(from: route.stack.last) != nil { route.stack.removeLast() }
            // A server page at the root (Usage, kept from the split shell) goes too.
            if route.stack.isEmpty, Self.hostSwitcherDestination(from: route.place?.screen) != nil {
                route.place = NavigationPlace.allSessions
            }
            // All Sessions is the stack's bottom, so its job adds no screen.
            route.stack += [destination.screen].compactMap { $0 }
            setRoute(route, in: pane)
        case .reuse, .split, .stay:
            break
        }
    }
}
