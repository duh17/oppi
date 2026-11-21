import Foundation

// Pane links (`oppi://sessions`, `file`, `files`, `git`, `panel`), decoded by
// `PaneLinkCodec`. A link opens on the server it names, else the server it
// came from, else the active one. A file, a folder, a workspace's sessions,
// Git, a commit, a web page and a game are side content (`openSideContent`):
// beside the pane the link came from (the main pane for a link from outside
// the app) where there is room, else in the main pane. `oppi://sessions` is
// the All Sessions place, always in the main pane. Content the app cannot
// show yet (a server this device has not paired, a server still connecting, a
// session it must look up, content behind a scoped lock) opens as the entry's
// leaf state (`PaneLeafStateViewController`), which turns into the content
// when it can. A panel opens beside its session's chat
// (`ScenePanes.openPanel`). A browser link needs no server, so it never
// switches one; with no server at all it opens as a tapped web link does. A
// Godot link opens only with the Godot Pane experiment on and a server that
// offers it (its Godot Pane switch, and games to serve).
extension AppOpener {
    func performPane(_ link: PaneLink, sourceServerID: String?, generation: UInt64) async -> AppOpenOutcome {
        if case .browser(let url) = link.route {
            // Beside where side content opens; else as a tapped web link
            // opens (Oppi's browser or the system's, by the Browser setting).
            if let serverId = link.server ?? sourceServerID ?? windowServerId {
                let destination = NavigationDestination.page(.entry(PaneStackEntry(serverId: serverId, route: link.route)))
                if navigation.open(destination, from: followOrigin, beside: .webPage, opensInMainPane: false).showsBeside {
                    return .finished
                }
            }
            presentWebLink(url)
            return .finished
        }
        if case .godot = link.route, !GodotPaneAvailability.isOn {
            toast(PlatformCapabilities.godotPane
                ? String(localized: "Turn on Godot Pane in Settings › Experiments to open Godot games")
                : String(localized: "This build of Oppi can’t play Godot games"))
            return .finished
        }
        guard let serverId = link.server ?? sourceServerID ?? windowServerId else {
            toast(String(localized: "No server to open this link on"))
            return .finished
        }
        if case .godot = link.route, !coordinator.server(serverId, offers: .godotPane) {
            toast(String(localized: "Godot Pane is turned off on this server. Turn it on in Server Settings › Features."))
            return .finished
        }
        let entry = PaneStackEntry(serverId: serverId, route: link.route)
        // A locked entry asks only when its leaf is tapped, so the window's
        // server does not switch under the lock.
        guard serverStore.server(for: serverId) != nil,
              !ScopedLockService.shared.isLocked(PaneEntries.lockTarget(entry)) else {
            navigation.open(.page(.entry(entry)))
            return .finished
        }
        let previousServerId = windowServerId
        let switched = await openServer(serverId, generation: generation)
        guard isCurrent(generation) else { return .finished }
        guard switched else {
            // The leaf shows the server offline and opens once it connects.
            navigation.open(.page(.entry(entry)))
            return .finished
        }
        if case .sessions(nil) = link.route {
            navigation.open(.place(.allSessions))
            return .finished
        }
        let connection = coordinator.connection(for: serverId)
        // An internal URL opens in the viewer only when its server shows the scheme.
        if case .read(_, let target) = link.route, let url = URL(string: target),
           connection?.showsInternalURL(url) != true {
            toast(AppOpenRequest.unsupportedLinkMessage(url))
            return .finished
        }
        if let sessionId = link.route.chatPanelSessionId, let connection,
           connection.sessionStore.session(id: sessionId) != nil {
            // The chat opens as a session link does, and the panel beside it.
            navigation.panes.openPanel(link.route, beside: sessionId)
            return await openPreparedSession(
                serverId: serverId,
                sessionId: sessionId,
                workspaceIdHint: nil,
                connection: connection,
                origin: .external,
                previousServerId: previousServerId,
                generation: generation
            )
        }
        // A game, a workspace's Git or a commit (`PaneGitScreens`), a
        // workspace's sessions, a folder or a file is side content; anything
        // else, or what the stores do not know yet, is the entry's leaf state.
        let kind: PaneContentKind? = switch link.route {
        case .godot: .game
        case .git, .commit: .git
        default:
            switch PaneEntries.element(for: entry, coordinator: coordinator) {
            case .workspace?: .sessions
            case .fileBrowser?: .folder
            case .linkedFile?: .file
            default: nil
            }
        }
        if let kind {
            openSideContent(PaneOpenContent(entry: entry), kind: kind)
        } else {
            navigation.open(.page(.entry(entry)))
        }
        return .finished
    }

    /// A file a chat's text links to: beside that chat as its reader, as a
    /// file pill opens, when the chat shows with room for its panels; else as
    /// side content, telling the chat before the file covers it.
    func openLinkedFile(_ target: WorkspaceLinkedFileNavTarget, reference: ResourceReference) {
        if followOrigin != .here, let sessionId = reference.sourceSessionID, let serverId = reference.sourceServerID,
           navigation.panes.openLinkedFileBesideChat(target, sessionId: sessionId, serverId: serverId) {
            return
        }
        openSideContent(PaneOpenContent(file: target), kind: .file) { [self] in
            postWorkspaceLinkedFileWillOpen(reference: reference)
        }
    }

    /// Side content a link opens: beside the pane the request's origin names
    /// (`OpenOrigin`), where `PanePlacement` puts it; else in the main pane,
    /// after `beforeMainPane` tells the chat it is about to be covered. Beside
    /// needs a wide window, room for a pane, and no sheet in front.
    func openSideContent(_ content: PaneOpenContent, kind: PaneContentKind, beforeMainPane: @escaping () -> Void = {}) {
        navigation.open(
            content.mainPaneDestination(coordinator: coordinator),
            from: followOrigin,
            beside: kind,
            beforeMain: beforeMainPane
        )
    }
}
