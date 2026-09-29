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

typealias ChatTimelineOpenDestination = @MainActor (ChatTimelineDestinationRequest) -> Void
