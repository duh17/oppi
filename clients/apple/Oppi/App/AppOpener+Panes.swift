import Foundation

// Pane links (`oppi://sessions`, `file`, `files`, `git`, `panel`), decoded by
// `PaneLinkCodec`. A link opens on the server it names, else the server it
// came from, else the active one. A file, a folder or a workspace's sessions
// open beside the focused pane where there is room (`openBesideFocusedPane`);
// what else the primary
// leaf can show opens there; content the app cannot show yet (a server this device has not
// paired, a server still connecting, a session it must look up, content
// behind a scoped lock) opens as the entry's leaf state
// (`PaneLeafStateViewController`), which turns into the content when it can.
// A panel opens beside its session's chat (`ScenePanes.openPanel`). A
// browser link opens its page beside the focused pane on a wide window, else
// as a tapped web link does; needing no server, it never switches one. A Git
// or commit link opens beside the focused pane on a wide window, else pushed
// (`PaneGitScreens`). A Godot link opens beside the focused pane on a wide
// window, else in the primary stack, and only with the Godot Pane experiment on
// and a server that offers it (its Godot Pane switch, and games to serve).
extension AppOpener {
    func performPane(_ link: PaneLink, sourceServerID: String?, generation: UInt64) async -> AppOpenOutcome {
        if case .browser(let url) = link.route {
            // Beside the focused pane on a wide window; else as a tapped web
            // link opens (the in-app browser or Safari, per Settings).
            if let serverId = link.server ?? sourceServerID ?? windowServerId,
               openBesideFocusedPane(PaneOpenContent(entry: PaneStackEntry(serverId: serverId, route: link.route)), kind: .webPage) {
                return .finished
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
            navigation.open(.page(.paneEntry(entry)))
            return .finished
        }
        let previousServerId = windowServerId
        let switched = await openServer(serverId, generation: generation)
        guard isCurrent(generation) else { return .finished }
        guard switched else {
            // The leaf shows the server offline and opens once it connects.
            navigation.open(.page(.paneEntry(entry)))
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
                origin: .externalURL,
                previousServerId: previousServerId,
                generation: generation
            )
        }
        if case .godot = link.route, let window = navigation.window,
           PaneHostController.focused(in: window)?.openGodot(entry) == true {
            return .finished
        }
        switch link.route {
        case .git, .commit:
            // A workspace's Git or a commit (`PaneGitScreens`): beside the
            // focused pane on a wide window, else pushed.
            if !openBesideFocusedPane(PaneOpenContent(entry: entry), kind: .git) {
                navigation.open(.page(.paneEntry(entry)))
            }
            return .finished
        default:
            break
        }
        switch PaneEntries.element(for: entry, coordinator: coordinator) {
        case .workspace(let target)?:
            if !openBesideFocusedPane(PaneOpenContent(entry: entry), kind: .sessions) {
                navigation.open(.place(.sessions(target)))
            }
        case .fileBrowser(let target)?:
            if !openBesideFocusedPane(PaneOpenContent(entry: entry), kind: .folder) {
                navigation.open(.page(.fileBrowser(target)))
            }
        case .linkedFile(let target)?:
            if !openBesideFocusedPane(PaneOpenContent(entry: entry), kind: .file) {
                navigation.open(.page(.linkedFile(target)))
            }
        default:
            navigation.open(.page(.paneEntry(entry)))
        }
        return .finished
    }

    /// Opens a link's content in a pane beside the focused one, where
    /// `PaneHostController.openBeside` puts it. False when it opens
    /// in the main pane as before: a compact window, no room
    /// for a pane, a sheet in front, or Open Here (`opensInMainPane`).
    /// A file a chat's text links to opens beside that chat as its reader, as
    /// a file pill does, when the chat shows with room for its panels; else
    /// beside the focused pane (`openBesideFocusedPane`). False when it
    /// belongs in the main pane.
    func openLinkedFileBeside(_ target: WorkspaceLinkedFileNavTarget, reference: ResourceReference) -> Bool {
        if !opensInMainPane, let sessionId = reference.sourceSessionID, let serverId = reference.sourceServerID,
           navigation.panes.openLinkedFileBesideChat(target, sessionId: sessionId, serverId: serverId) {
            return true
        }
        return openBesideFocusedPane(PaneOpenContent(file: target), kind: .file)
    }

    func openBesideFocusedPane(_ content: PaneOpenContent, kind: PaneContentKind) -> Bool {
        guard !opensInMainPane, let window = navigation.window,
              let host = PaneHostController.focused(in: window) else { return false }
        return host.openBeside(content, kind: kind)
    }
}
