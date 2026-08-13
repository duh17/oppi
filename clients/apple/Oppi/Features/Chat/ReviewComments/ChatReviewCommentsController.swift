import Foundation
import Observation

@MainActor @Observable
final class ChatReviewCommentsController {
    private let store: ReviewCommentStore

    init(store: ReviewCommentStore = ReviewCommentStore()) {
        self.store = store
    }

    var stagedComments: [ReviewComment] { store.stagedComments }
    var stagedCount: Int { store.stagedCount }
    var stagedCommentIds: [String] { store.stagedComments.map(\.id) }

    func load(localScopeId: String?, sessionId: String) {
        guard let localScopeId else {
            store.clearLoadedScope()
            return
        }
        store.load(workspaceId: localScopeId, sessionId: sessionId)
    }

    func appendReviewBlock(
        to text: String,
        pathFormatting: ReviewCommentPathFormatting = .normalizedDisplay
    ) -> String {
        store.appendReviewBlock(to: text, pathFormatting: pathFormatting)
    }

    @discardableResult
    func save(body: String, request: ReviewCommentSelectionRequest, localScopeId: String?, sessionId: String) -> String? {
        guard let localScopeId else {
            return "Review comments are unavailable for this session."
        }

        do {
            _ = try store.create(
                workspaceId: localScopeId,
                sessionId: sessionId,
                body: body,
                reference: Self.reviewReference(for: request)
            )
            return nil
        } catch {
            return "Failed to save review comment: \(error.localizedDescription)"
        }
    }

    func update(_ comment: ReviewComment, body: String) -> String? {
        do {
            _ = try store.updateBody(commentId: comment.id, body: body)
            return nil
        } catch {
            return "Failed to update review comment: \(error.localizedDescription)"
        }
    }

    func delete(_ comment: ReviewComment) {
        store.delete(commentId: comment.id)
    }

    func clearSent(ids: [String]) {
        store.clearSent(ids: ids)
    }

    @discardableResult
    func moveStagedComments(
        fromLocalScopeId: String,
        fromSessionId: String,
        toLocalScopeId: String,
        toSessionId: String
    ) throws -> Int {
        try store.moveStagedComments(
            fromWorkspaceId: fromLocalScopeId,
            fromSessionId: fromSessionId,
            toWorkspaceId: toLocalScopeId,
            toSessionId: toSessionId
        )
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
