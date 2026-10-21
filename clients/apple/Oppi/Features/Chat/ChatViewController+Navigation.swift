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
    /// navigation (a fork, or a session link from an extension surface).
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

    func openExtensionSurfaceURL(_ url: URL) -> Bool {
        let context = extensionSurfaceLinkContext
        switch ExtensionSurfaceLinkRouting.action(
            for: url,
            serverID: context.serverID,
            workspaceID: context.workspaceID,
            currentSessionId: sessionId
        ) {
        case .pushSession(let link):
            connection.prepareForSessionReentry(link.sessionId, workspaceIdHint: link.workspaceId)
            pushChat(sessionId: link.sessionId, workspaceId: link.workspaceId)
            return true
        case .ignore:
            return true
        case .resourceReference(let reference):
            NotificationCenter.default.post(name: .resourceReferenceTapped, object: reference)
            return true
        case .webLink(let destination):
            NotificationCenter.default.post(name: .webLinkTapped, object: destination)
            return true
        case .fileLink(let payload):
            NotificationCenter.default.post(name: .fileLinkTapped, object: payload)
            return true
        case .inviteDeepLink(let destination):
            NotificationCenter.default.post(name: .inviteDeepLinkTapped, object: destination)
            return true
        case .unhandled:
            return false
        }
    }
}
