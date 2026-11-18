import Foundation
import Observation

@MainActor @Observable
final class ChatReviewCommentsController: ReviewCommentStashHandling {
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

    /// The staged comments as the context items the next message carries.
    func contextItems(
        pathFormatting: ReviewCommentPathFormatting = .normalizedDisplay,
        currentSourceRevision: ((ReviewComment) -> String?)? = nil
    ) -> [PromptContextItem] {
        store.contextItems(pathFormatting: pathFormatting, currentSourceRevision: currentSourceRevision)
    }

    /// Stages `items` again as comments: queued inputs Stop took back to the composer. A
    /// rendered element or diagram anchor comes back as its place and quote only.
    func restage(_ items: [PromptContextItem], localScopeId: String?, sessionId: String) -> String? {
        guard let localScopeId else { return "Review comments are unavailable for this session." }
        for item in items {
            do {
                _ = try store.create(
                    workspaceId: localScopeId,
                    sessionId: sessionId,
                    body: item.note ?? "",
                    reference: item.reviewReference
                )
            } catch {
                return "Failed to restore a review comment: \(error.localizedDescription)"
            }
        }
        return nil
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

    private static func reviewReference(for request: ReviewCommentSelectionRequest) -> ReviewCommentReference {
        ReviewCommentReference(
            source: request.source.reviewCommentReferenceSource,
            label: request.source.sourceLabel,
            path: request.source.filePath,
            side: nil,
            startLine: request.htmlDOMAnchor == nil ? request.source.lineRange?.lowerBound : nil,
            endLine: request.htmlDOMAnchor == nil ? request.source.lineRange?.upperBound : nil,
            selectedText: request.selectedText,
            languageHint: request.htmlDOMAnchor == nil ? request.source.languageHint : nil,
            toolCallId: nil,
            timelineItemId: request.source.timelineItemId,
            url: nil,
            htmlDOMAnchor: request.htmlDOMAnchor,
            semanticAnchor: request.semanticAnchor,
            startPage: request.pageRange?.lowerBound,
            endPage: request.pageRange?.upperBound
        )
    }
}
