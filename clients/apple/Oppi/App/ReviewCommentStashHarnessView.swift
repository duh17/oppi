#if DEBUG
import SwiftUI

enum ReviewCommentStashHarnessConfig {
    static var isEnabled: Bool {
#if targetEnvironment(simulator)
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--review-comment-stash-harness")
            || processInfo.environment["PI_REVIEW_COMMENT_STASH_HARNESS"] == "1"
#else
        return false
#endif
    }
}

/// The stash sheet at the root of a router navigation controller, as chat
/// presents it. The screen is its own SwiftUI graph, so the comments it edits
/// live in an observable model.
struct ReviewCommentStashHarnessView: View {
    @State private var model = ReviewCommentStashHarnessModel()

    var body: some View {
        let model = model
        RouterPreviewNavigation {
            ReviewCommentStashContent(
                comments: model.comments,
                focusedCommentId: nil,
                onEdit: { comment, body in model.update(comment, body: body) },
                onDelete: { comment in
                    model.comments.removeAll { $0.id == comment.id }
                },
                onClose: {}
            )
        }
        .ignoresSafeArea()
        .overlay(alignment: .topLeading) {
            Text(model.didSave ? "1" : "0")
                .font(.system(size: 1))
                .opacity(0.02)
                .accessibilityLabel("Review comment save completed")
                .accessibilityValue(model.didSave ? "1" : "0")
                .accessibilityIdentifier("diag.reviewCommentStash.saved")
        }
    }
}

@MainActor @Observable
private final class ReviewCommentStashHarnessModel {
    var comments = [ReviewCommentStashHarnessModel.fixtureComment]
    var didSave = false

    func update(_ comment: ReviewComment, body: String) -> Bool {
        guard let index = comments.firstIndex(where: { $0.id == comment.id }) else {
            return false
        }
        comments[index].body = body
        comments[index].updatedAt += 1
        didSave = true
        return true
    }

    private static let fixtureComment = ReviewComment(
        id: "review-comment-stash-harness-comment",
        workspaceId: "workspace-1",
        sessionId: "session-1",
        turnId: nil,
        author: .human,
        status: .staged,
        severity: nil,
        body: "Original comment.",
        attachments: nil,
        reference: ReviewCommentReference(
            source: .timelineText,
            label: "Timeline",
            path: nil,
            side: nil,
            startLine: nil,
            endLine: nil,
            selectedText: "The selected text under review.",
            languageHint: nil,
            toolCallId: nil,
            timelineItemId: "timeline-item-1",
            url: nil
        ),
        createdAt: 1,
        updatedAt: 1,
        sentAt: nil
    )
}
#endif
