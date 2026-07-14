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

struct ReviewCommentStashHarnessView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var comments = [Self.fixtureComment]
    @State private var didSave = false

    var body: some View {
        ReviewCommentStashSheet(
            comments: comments,
            focusedCommentId: nil,
            onEdit: { comment, body in
                _ = dismiss
                return updateComment(comment, body: body)
            },
            onDelete: { comment in
                comments.removeAll { $0.id == comment.id }
            },
            onClose: {}
        )
        .overlay(alignment: .topLeading) {
            Text(didSave ? "1" : "0")
                .font(.system(size: 1))
                .opacity(0.02)
                .accessibilityLabel("Review comment save completed")
                .accessibilityValue(didSave ? "1" : "0")
                .accessibilityIdentifier("diag.reviewCommentStash.saved")
        }
    }

    private func updateComment(_ comment: ReviewComment, body: String) -> Bool {
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
