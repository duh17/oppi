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

    var usesCustomChatBackButton: Bool {
        appNavigation.workspaceNavigationPresentation == .stack
            || appNavigation.workspaceNavigationPresentation == .split
    }

    /// Back closes the chat's screen through the router: pushed (a shell
    /// route, a quick action, a fork), it pops; as the split detail root, the
    /// column shows its list. The bar controls go first: the outgoing bar
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
    func openExtensionSurfaceURL(_ url: URL) -> Bool {
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
            root?.opener.open(request)
        }
        return true
    }
}
