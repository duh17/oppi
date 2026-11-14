import Foundation

// Pane links (`oppi://sessions`, `file`, `files`, `git`, `panel`), decoded by
// `PaneLinkCodec`. A link opens on the server it names, else the server it
// came from, else the active one. What the primary leaf can show opens
// there; content the app cannot show yet (a server this device has not
// paired, a server still connecting, a session it must look up, content
// behind a scoped lock) opens as the entry's leaf state
// (`PaneLeafStateViewController`), which turns into the content when it can.
// A panel opens beside its session's chat (`ScenePanes.openPanel`). A
// browser link opens its page as a tapped web link does: needing no server,
// it never switches one. A Godot link opens beside the focused pane on a wide
// window, else in the primary stack, and only with the Godot Pane experiment on.
extension AppOpener {
    func performPane(_ link: PaneLink, sourceServerID: String?, generation: UInt64) async -> AppOpenOutcome {
        if case .browser(let url) = link.route {
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
        let entry = PaneStackEntry(serverId: serverId, route: link.route)
        switch link.route {
        case .git, .commit:
            // Git panes arrive with the per-window tree.
            toast(String(localized: "Oppi can\u{2019}t open this kind of link yet"))
            return .finished
        default:
            break
        }
        // A locked entry asks only when its leaf is tapped, so the window's
        // server does not switch under the lock.
        guard serverStore.server(for: serverId) != nil,
              !ScopedLockService.shared.isLocked(PaneEntries.lockTarget(entry)) else {
            navigation.pushPaneEntry(entry)
            return .finished
        }
        let previousServerId = windowServerId
        let switched = await openServer(serverId, generation: generation)
        guard isCurrent(generation) else { return .finished }
        guard switched else {
            // The leaf shows the server offline and opens once it connects.
            navigation.pushPaneEntry(entry)
            return .finished
        }
        if case .sessions(nil) = link.route {
            navigation.showAllWorkspaceSessions()
            return .finished
        }
        if case .panel(let sessionId, _) = link.route,
           let connection = coordinator.connection(for: serverId),
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
        switch PaneEntries.element(for: entry, coordinator: coordinator) {
        case .workspace(let target)?:
            navigation.openWorkspace(target)
        case .fileBrowser(let target)?:
            navigation.openWorkspaceFileBrowser(target)
        case .linkedFile(let target)?:
            navigation.openWorkspaceLinkedFile(target)
        default:
            navigation.pushPaneEntry(entry)
        }
        return .finished
    }
}
