import Foundation

struct ExtensionSurfaceLinkContext: Equatable {
    var serverID: String? = nil
    var workspaceID: String? = nil
    var sessionID: String? = nil

    static let empty = Self()
}

/// What an extension surface's link tap does: open a request through the app
/// opener, or consume a link to the current chat. `nil` is unhandled.
enum ExtensionSurfaceLinkOutcome: Equatable {
    case open(AppOpenRequest)
    case ignore

    var request: AppOpenRequest? {
        guard case .open(let request) = self else { return nil }
        return request
    }
}

@MainActor
enum ExtensionSurfaceLinkRouting {
    static func outcome(
        for url: URL,
        serverID: String?,
        workspaceID: String?,
        currentSessionId: String
    ) -> ExtensionSurfaceLinkOutcome? {
        guard var request = MarkdownLinkInteractionSupport.classify(
            url,
            serverID: serverID,
            workspaceID: workspaceID
        ) else {
            return nil
        }
        guard case .session(var open) = request else {
            return .open(request)
        }
        if open.workspaceId == nil {
            open.workspaceId = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
            request = .session(open)
        }
        // A link to the chat it appears in changes nothing.
        if open.sessionId == currentSessionId {
            return .ignore
        }
        return .open(request)
    }

    static func accessibilityHint(for outcome: ExtensionSurfaceLinkOutcome?) -> String? {
        guard let outcome else { return nil }
        switch outcome {
        case .ignore:
            return nil
        case .open(let request):
            switch request {
            case .session:
                return "Opens the related session"
            case .webLink:
                return "Opens the web page"
            case .fileLink, .resourceReference, .sessionFile:
                return "Opens the file"
            case .invite, .createWorkspace:
                return "Opens the link"
            case .quickSession, .pairing, .system:
                return nil
            }
        }
    }
}
