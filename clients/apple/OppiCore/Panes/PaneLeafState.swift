/// How a leaf's server connection stands, as the connection reports it. A
/// remote server, the Mac's own server and an on-device one all report
/// through this one value; what each can do about being unreachable is its
/// `PaneConnectionRemedy`, so "server removed" is never a guess about an
/// offline server.
enum PaneConnectionStatus: Hashable, Sendable {
    case connected
    case connecting
    /// Not reachable now; the remedy is the connection's own.
    case unreachable(PaneConnectionRemedy)
    /// No paired server has the leaf's server id.
    case removed
}

/// What the person can do about an unreachable server.
enum PaneConnectionRemedy: Hashable, Sendable {
    /// A remote server: try to connect again.
    case retry
    /// The Mac's own server stopped: start it again.
    case restart
    /// The Mac's server agent is turned off in Login Items.
    case openLoginItems
}

/// Whether a leaf's content (its session, workspace, file) exists, as far as
/// the app can tell now. `absent` comes from a list the server sent since
/// launch, or a read the server refused with "not found"; a cache never says
/// `absent`.
enum PaneContentPresence: Hashable, Sendable {
    case present, absent, unknown
}

/// What a leaf's content went missing as.
enum PaneMissingContent: Hashable, Sendable {
    case session, file, workspace, server
}

/// What a panel leaf has seen of its surface.
enum PanePanelSurface: Hashable, Sendable {
    /// The session holds the surface now.
    case published
    /// The leaf showed the surface, and the session no longer holds it.
    case cleared
    /// Not published since the leaf opened.
    case notPublished
}

/// What a panel's session is doing.
enum PanePanelSession: Hashable, Sendable {
    /// Working, or starting up: a panel may still arrive.
    case busy
    case idle
    /// Stopped, or gone from its server.
    case ended
}

/// What a leaf shows instead of, or as, its content (build plan §1.11).
enum PaneLeafState: Hashable, Sendable {
    case content
    case connecting
    /// A scoped lock holds the content; it asks only when tapped.
    case locked
    /// Choose… or Close Pane.
    case missing(PaneMissingContent)
    /// The server cannot be reached and the content is not known locally.
    case unreachable(PaneConnectionRemedy)
    /// A leaf kind from a newer Oppi.
    case unsupported
    /// A panel nobody has published yet while its session works.
    case waiting
    /// A panel its idle session has not published.
    case unavailable
    /// A panel whose surface was cleared or whose session ended: the last
    /// snapshot, dimmed, with Close Pane.
    case ended
    /// A panel leaf without its chat beside it, before panels can be pinned:
    /// Open Chat.
    case chatNotShown

    /// The state of a leaf showing `route`. Pure: the app passes what it
    /// knows. Content known locally shows even while its server reconnects;
    /// the screen reports its own connection.
    static func resolve(
        route: PaneRoute,
        connection: PaneConnectionStatus,
        presence: PaneContentPresence,
        isLocked: Bool
    ) -> Self {
        if case .unsupported = route { return .unsupported }
        if connection == .removed { return .missing(.server) }
        if isLocked { return .locked }
        switch presence {
        case .present:
            return .content
        case .absent:
            return .missing(missingContent(route))
        case .unknown:
            switch connection {
            case .connected, .connecting, .removed: return .connecting
            case .unreachable(let remedy): return .unreachable(remedy)
            }
        }
    }

    /// The state of a panel leaf (`.panel`) whose session the app holds.
    /// Pure: the leaf passes what it sees of its surface and session. Until
    /// panels can be pinned, a panel shows only beside its own chat.
    static func panel(surface: PanePanelSurface, session: PanePanelSession, chatShown: Bool) -> Self {
        guard chatShown else { return .chatNotShown }
        switch surface {
        case .published: return session == .ended ? .ended : .content
        case .cleared: return .ended
        case .notPublished: return session == .busy ? .waiting : .unavailable
        }
    }

    private static func missingContent(_ route: PaneRoute) -> PaneMissingContent {
        switch route {
        case .session, .thread, .panel: .session
        case .file: .file
        case .sessions, .files, .git, .commit: .workspace
        // A Godot leaf states its own project (`GodotPaneViewController`).
        case .godot: .workspace
        // A browser leaf shows its page whatever its server's state, so it
        // never asks; nor do screens with no content to miss.
        case .browser, .local, .unsupported: .session
        }
    }
}
