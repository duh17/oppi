import UIKit

/// A destination the timeline asks chat composition to open. The timeline decides which
/// destination a user action means; chat composition builds and presents it.
enum ChatTimelineDestination: Equatable {
    case commitDetail(sha: String)
    /// Upload, review, repo, and host-path pills open the file viewer.
    case workspaceFile(UserMessagePathPill)
}

/// One destination request: what to open, the source identity it belongs to, the
/// review-comment selection scope the opened screen inherits, and where to present.
struct ChatTimelineDestinationRequest {
    let destination: ChatTimelineDestination
    let serverId: String?
    let workspaceId: String
    let sessionId: String
    let reviewCommentSelectionScope: ReviewCommentSelectionScope?
    let sourceView: UIView
    let presenter: UIViewController
}

extension ChatTimelineDestinationRequest {
    /// The request without its views, for a screen that outlives the tap:
    /// the trailing column's panel.
    var sidePanelTarget: ChatTimelineSidePanelTarget {
        ChatTimelineSidePanelTarget(
            destination: destination,
            serverId: serverId,
            workspaceId: workspaceId,
            sessionId: sessionId,
            reviewCommentSelectionScope: reviewCommentSelectionScope
        )
    }
}

/// A timeline destination shown in the chat's trailing column at regular
/// width. Two opens of the same file are two panels, so identity is the id.
struct ChatTimelineSidePanelTarget: Hashable {
    let id = UUID()
    let destination: ChatTimelineDestination
    let serverId: String?
    let workspaceId: String
    let sessionId: String
    var reviewCommentSelectionScope: ReviewCommentSelectionScope?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The same open as a modal's request, for a window too narrow for the
    /// column.
    func request(sourceView: UIView, presenter: UIViewController) -> ChatTimelineDestinationRequest {
        ChatTimelineDestinationRequest(
            destination: destination,
            serverId: serverId,
            workspaceId: workspaceId,
            sessionId: sessionId,
            reviewCommentSelectionScope: reviewCommentSelectionScope,
            sourceView: sourceView,
            presenter: presenter
        )
    }
}

typealias ChatTimelineOpenDestination = @MainActor (ChatTimelineDestinationRequest) -> Void
