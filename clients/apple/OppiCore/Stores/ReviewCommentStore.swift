import Foundation
import Observation

enum ReviewCommentStoreError: LocalizedError, Equatable {
    case emptyBody
    case commentNotFound
    case invalidStoredComments

    var errorDescription: String? {
        switch self {
        case .emptyBody:
            return "Review comment body is required."
        case .commentNotFound:
            return "Review comment was not found."
        case .invalidStoredComments:
            return "Stored review comments could not be read."
        }
    }
}

enum ReviewCommentLocalScope {
    static let controlDraft = "__oppi_control_draft__"
}

enum ReviewCommentPathFormatting: Equatable {
    case normalizedDisplay
    case verbatim
}

@MainActor @Observable
final class ReviewCommentStore {
    private static let defaultKeyPrefix = "reviewComments.localDrafts.v1"

    private let defaults: UserDefaults
    private let keyPrefix: String
    private var storageKey: String?

    private(set) var comments: [ReviewComment] = []
    var lastError: String?

    init(defaults: UserDefaults = .standard, keyPrefix: String = ReviewCommentStore.defaultKeyPrefix) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    var stagedComments: [ReviewComment] {
        comments(matching: { $0.status == .staged }) { $0.createdAt < $1.createdAt }
    }

    var stagedCount: Int { stagedComments.count }

    func clearLoadedScope() {
        storageKey = nil
        comments = []
        lastError = nil
    }

    func load(workspaceId: String, sessionId: String) {
        let key = Self.makeStorageKey(prefix: keyPrefix, workspaceId: workspaceId, sessionId: sessionId)
        storageKey = key
        loadComments(forKey: key)
    }

    @discardableResult
    func create(
        workspaceId: String,
        sessionId: String,
        body: String,
        reference: ReviewCommentReference
    ) throws -> ReviewComment {
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBody.isEmpty else {
            throw ReviewCommentStoreError.emptyBody
        }

        let key = Self.makeStorageKey(prefix: keyPrefix, workspaceId: workspaceId, sessionId: sessionId)
        if storageKey != key {
            storageKey = key
            loadComments(forKey: key)
        }

        // Every capture path stages through here: a selection longer than the server takes is
        // trimmed now, visibly, rather than failing the send that carries it.
        var reference = reference
        reference.selectedText = reference.selectedText.map(PromptContextItem.capturedQuote)

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let comment = ReviewComment(
            id: UUID().uuidString,
            workspaceId: workspaceId,
            sessionId: sessionId,
            turnId: nil,
            author: .human,
            status: .staged,
            severity: nil,
            body: normalizedBody,
            attachments: nil,
            reference: reference,
            createdAt: now,
            updatedAt: now,
            sentAt: nil
        )
        upsert(comment)
        if persist() {
            lastError = nil
        }
        return comment
    }

    @discardableResult
    func updateBody(commentId: String, body: String) throws -> ReviewComment {
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBody.isEmpty else {
            throw ReviewCommentStoreError.emptyBody
        }
        guard let index = comments.firstIndex(where: { $0.id == commentId }) else {
            throw ReviewCommentStoreError.commentNotFound
        }

        var updated = comments[index]
        updated.body = normalizedBody
        updated.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        comments[index] = updated
        if persist() {
            lastError = nil
        }
        return updated
    }

    func delete(commentId: String) {
        removeLocalComment(id: commentId)
        if persist() {
            lastError = nil
        }
    }

    /// Drop sent comments from what is stored now, not from this copy. The ack
    /// can land after the chat that sent them is gone, when the session's next
    /// chat may have stored comments this copy never saw.
    func clearSent(ids: [String]) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        comments.removeAll { idSet.contains($0.id) }
        guard let storageKey,
              let stored = try? storedComments(forKey: storageKey) else {
            if persist() {
                lastError = nil
            }
            return
        }
        if persist(stored.filter { !idSet.contains($0.id) }) {
            lastError = nil
        }
    }

    private func comments(
        matching predicate: (ReviewComment) -> Bool,
        sortedBy areInIncreasingOrder: (ReviewComment, ReviewComment) -> Bool
    ) -> [ReviewComment] {
        comments.filter(predicate).sorted(by: areInIncreasingOrder)
    }

    private func loadComments(forKey key: String) {
        do {
            comments = try storedComments(forKey: key)
            lastError = nil
        } catch {
            comments = []
            lastError = "Failed to load local review comments: \(error.localizedDescription)"
        }
    }

    private func storedComments(forKey key: String) throws -> [ReviewComment] {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([ReviewComment].self, from: data)
        } catch {
            throw ReviewCommentStoreError.invalidStoredComments
        }
    }

    private func upsert(_ comment: ReviewComment) {
        if let index = comments.firstIndex(where: { $0.id == comment.id }) {
            comments[index] = comment
        } else {
            comments.append(comment)
        }
    }

    private func removeLocalComment(id: String) {
        comments.removeAll { $0.id == id }
    }

    private func persist() -> Bool {
        persist(comments)
    }

    private func persist(_ comments: [ReviewComment]) -> Bool {
        guard let storageKey else { return true }
        do {
            let data = try JSONEncoder().encode(comments)
            defaults.set(data, forKey: storageKey)
            return true
        } catch {
            lastError = "Failed to save local review comments: \(error.localizedDescription)"
            return false
        }
    }

    static func makeStorageKey(prefix: String, workspaceId: String, sessionId: String) -> String {
        "\(prefix).\(workspaceId).\(sessionId)"
    }
}
