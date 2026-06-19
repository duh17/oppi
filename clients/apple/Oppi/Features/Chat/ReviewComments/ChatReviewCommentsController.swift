import Foundation
import Observation

@MainActor @Observable
final class ChatReviewCommentsController {
    private let store = ReviewCommentStore()

    var stagedComments: [ReviewComment] { store.stagedComments }
    var stagedCount: Int { store.stagedCount }
    var stagedCommentIds: [String] { store.stagedComments.map(\.id) }

    func load(api: APIClient?, workspaceId: String?, sessionId: String) async {
        guard let api, let workspaceId else { return }
        await store.load(api: api, workspaceId: workspaceId, sessionId: sessionId)
    }

    func appendReviewBlock(to text: String) -> String {
        store.appendReviewBlock(to: text)
    }

    @discardableResult
    func save(body: String, request: ReviewCommentSelectionRequest, api: APIClient?, workspaceId: String?, sessionId: String) async -> String? {
        guard let api else {
            return "Connect to a server before saving review comments."
        }
        guard let workspaceId else {
            return "Review comments are only available in workspace sessions."
        }

        do {
            _ = try await store.create(
                api: api,
                workspaceId: workspaceId,
                sessionId: sessionId,
                body: body,
                reference: Self.reviewReference(for: request)
            )
            return nil
        } catch {
            return "Failed to save review comment: \(error.localizedDescription)"
        }
    }

    func delete(_ comment: ReviewComment, api: APIClient?) async -> String? {
        guard let api else { return nil }
        do {
            try await store.delete(api: api, workspaceId: comment.workspaceId, commentId: comment.id)
            return nil
        } catch {
            return "Failed to delete review comment: \(error.localizedDescription)"
        }
    }

    func markSent(ids: [String], api: APIClient?, workspaceId: String?, sessionId: String) async -> String? {
        guard !ids.isEmpty else { return nil }
        guard let api, let workspaceId else { return nil }
        let didMarkSent = await store.markSent(
            api: api,
            workspaceId: workspaceId,
            ids: ids,
            sessionId: sessionId
        )
        return didMarkSent ? nil : "Sent, but failed to update review comment status. Open Review Comments before sending again."
    }

    private static func reviewReference(for request: ReviewCommentSelectionRequest) -> ReviewCommentReference {
        ReviewCommentReference(
            source: request.source.reviewCommentReferenceSource,
            label: request.source.sourceLabel,
            path: request.source.filePath,
            side: nil,
            startLine: request.source.lineRange?.lowerBound,
            endLine: request.source.lineRange?.upperBound,
            selectedText: request.selectedText,
            languageHint: request.source.languageHint,
            toolCallId: nil,
            timelineItemId: request.source.timelineItemId,
            url: nil
        )
    }
}
