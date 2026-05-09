import Foundation
import Observation

struct ReviewCommentDraftContext: Identifiable, Equatable {
    let id = UUID()
    let request: SelectedTextPiRequest
}

@MainActor @Observable
final class ChatReviewCommentsController {
    private let store = ReviewCommentStore()

    var pendingDraft: ReviewCommentDraftContext?
    var showsSheet = false

    var comments: [ReviewComment] { store.comments }
    var stagedCount: Int { store.stagedCount }
    var stagedCommentIds: [String] { store.stagedComments.map(\.id) }

    func beginComment(_ request: SelectedTextPiRequest) {
        pendingDraft = ReviewCommentDraftContext(request: request)
    }

    func openSheet() {
        showsSheet = true
    }

    func closeSheet() {
        showsSheet = false
    }

    func load(api: APIClient?, workspaceId: String?, sessionId: String) async {
        guard let api, let workspaceId else { return }
        await store.load(api: api, workspaceId: workspaceId, sessionId: sessionId)
    }

    func appendReviewBlock(to text: String) -> String {
        store.appendReviewBlock(to: text)
    }

    @discardableResult
    func save(body: String, request: SelectedTextPiRequest, api: APIClient?, workspaceId: String?, sessionId: String) async -> String? {
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
            pendingDraft = nil
            return nil
        } catch {
            return "Failed to save review comment: \(error.localizedDescription)"
        }
    }

    func update(_ comment: ReviewComment, body: String? = nil, status: ReviewCommentStatus? = nil, api: APIClient?, workspaceId: String?) async -> String? {
        guard let api else { return nil }
        let targetWorkspaceId = comment.workspaceId
        do {
            _ = try await store.update(
                api: api,
                workspaceId: targetWorkspaceId,
                commentId: comment.id,
                body: body,
                status: status
            )
            return nil
        } catch let APIError.server(status, _) where status == 404 {
            return "Review comment was already deleted. Refreshing the list removed the stale item."
        } catch {
            return "Failed to update review comment: \(error.localizedDescription)"
        }
    }

    func delete(_ comment: ReviewComment, api: APIClient?, workspaceId: String?) async -> String? {
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

    private static func reviewReference(for request: SelectedTextPiRequest) -> ReviewCommentReference {
        let source = reviewReferenceSource(for: request.source.surface)
        return ReviewCommentReference(
            source: source,
            label: request.source.sourceLabel,
            path: request.source.filePath,
            side: nil,
            startLine: request.source.lineRange?.lowerBound,
            endLine: request.source.lineRange?.upperBound,
            selectedText: request.selectedText,
            languageHint: request.source.languageHint,
            toolCallId: nil,
            timelineItemId: nil,
            url: nil
        )
    }

    private static func reviewReferenceSource(for surface: SelectedTextSurfaceKind) -> ReviewCommentReferenceSource {
        switch surface {
        case .fullScreenDiff:
            return .gitDiff
        case .fullScreenCode, .fullScreenSource, .fullScreenMarkdown:
            return .file
        case .toolCommand, .toolOutput, .toolExpandedText, .fullScreenTerminal:
            return .toolOutput
        case .assistantProse, .userMessage, .assistantCodeBlock, .assistantTable, .thinking, .fullScreenThinking:
            return .timelineText
        }
    }
}
