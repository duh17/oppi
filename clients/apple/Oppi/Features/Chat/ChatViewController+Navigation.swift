import UIKit

// The chat's own navigation: back, another session above it, and the links an
// extension surface opens.

extension ChatViewController {
    var extensionSurfaceLinkContext: ExtensionSurfaceLinkContext {
        ExtensionSurfaceLinkContext(
            serverID: resolvedServerId,
            workspaceID: session?.workspaceId ?? sessionStore.workspaceId(for: sessionId),
            sessionID: sessionId
        )
    }

    // MARK: - Navigation

    /// Back pops the chat's screen through the router: a shell route, a quick
    /// action or a fork is always pushed over the screen it was opened from.
    /// The bar controls go first: the outgoing bar
    /// keeps them on screen for most of the transition, where a second tap
    /// on Back would close the screen below too.
    func navigateBackFromChat() {
        barItems.clear()
        Router.finish(screen)
    }

    /// Opens another session above this chat, on this chat's server and
    /// navigation (a fork's chat).
    func pushChat(sessionId: String, workspaceId: String?) {
        let chat = ChatViewController(
            sessionId: sessionId,
            connection: connection,
            navigation: appNavigation,
            apiClient: apiClient,
            workspaceIdHint: workspaceId
        )
        chat.traitOverrides.appRootEnvironment = root
        Router.push(chat, from: screen)
    }

    /// An extension surface's links. A session link navigates like a timeline
    /// session link: it keeps the back stack and goes through the app opener.
    /// A child session from its live tail row: the same `oppi://session/<id>` route the
    /// subagent pill's rows take.
    func openChildSession(_ sessionId: String) {
        var components = URLComponents()
        components.scheme = "oppi"
        components.host = "session"
        components.path = "/\(sessionId)"
        guard let url = components.url else { return }
        _ = openExtensionSurfaceURL(url)
    }

    func openExtensionSurfaceURL(_ url: URL) -> Bool {
        // An internal URL the server shows (`proc://bash-3`) belongs to this session: its viewer
        // opens here, as the opener's `PaneRoute.read` would, without leaving the chat.
        if connection.showsInternalURL(url) {
            openInternalURL(url.absoluteString)
            return true
        }
        let context = extensionSurfaceLinkContext
        guard let outcome = ExtensionSurfaceLinkRouting.outcome(
            for: url,
            serverID: context.serverID,
            workspaceID: context.workspaceID,
            currentSessionId: sessionId
        ) else {
            return false
        }
        if let request = outcome.request {
            root?.opener.follow(request)
        }
        return true
    }
}
