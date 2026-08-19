import Foundation

struct ExtensionSurfaceLinkContext: Equatable {
    var serverID: String? = nil
    var workspaceID: String? = nil
    var sessionID: String? = nil
    var sourceDirectory: String? = nil

    static let empty = ExtensionSurfaceLinkContext()
}

enum ExtensionSurfaceOpenAction: Equatable {
    case pushSession(ExtensionSurfaceSessionLink)
    case ignore
    case resourceReference(ResourceReference)
    case webLink(URL)
    case fileLink(FileLinkPayload)
    case inviteDeepLink(URL)
    case unhandled
}

@MainActor
enum ExtensionSurfaceLinkRouting {
    static func action(
        for url: URL,
        serverID: String?,
        workspaceID: String?,
        currentSessionId: String
    ) -> ExtensionSurfaceOpenAction {
        switch MarkdownLinkInteractionSupport.classify(
            url,
            serverID: serverID,
            workspaceID: workspaceID
        ) {
        case .inAppSessionLink:
            guard let link = ExtensionSurfaceSessionLink.parse(
                url,
                defaultWorkspaceId: workspaceID
            ) else {
                return .unhandled
            }
            if link.sessionId == currentSessionId {
                return .ignore
            }
            return .pushSession(link)
        case .deepLink(let destination):
            return .inviteDeepLink(destination)
        case .webLink(let destination):
            return .webLink(destination)
        case .resourceReference(let reference):
            return .resourceReference(reference)
        case .fileLink(let payload):
            return .fileLink(payload)
        case .systemDefault:
            return .unhandled
        }
    }

    static func accessibilityHint(for action: ExtensionSurfaceOpenAction) -> String? {
        switch action {
        case .pushSession:
            "Opens the related session"
        case .webLink:
            "Opens the web page"
        case .fileLink, .resourceReference:
            "Opens the file"
        case .inviteDeepLink:
            "Opens the link"
        case .ignore, .unhandled:
            nil
        }
    }
}
