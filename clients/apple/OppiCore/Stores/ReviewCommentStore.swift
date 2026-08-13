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
            return "Stored review comments could not be moved."
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

struct ReviewCommentMoveJournal: Codable, Equatable {
    let sourceKey: String
    let destinationKey: String
    let sourceData: Data
    let destinationData: Data
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
        do {
            try recoverPendingMove()
            loadComments(forKey: key)
        } catch {
            comments = []
            lastError = "Failed to recover local review comments: \(error.localizedDescription)"
        }
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

    func clearSent(ids: [String]) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        comments.removeAll { idSet.contains($0.id) }
        if persist() {
            lastError = nil
        }
    }

    /// Moves staged comments from a resource draft into the session that will
    /// apply them. A write-ahead journal finishes an interrupted two-key move
    /// the next time either scope loads; encoding failures leave the source intact.
    @discardableResult
    func moveStagedComments(
        fromWorkspaceId: String,
        fromSessionId: String,
        toWorkspaceId: String,
        toSessionId: String
    ) throws -> Int {
        try recoverPendingMove()
        let sourceKey = Self.makeStorageKey(
            prefix: keyPrefix,
            workspaceId: fromWorkspaceId,
            sessionId: fromSessionId
        )
        let destinationKey = Self.makeStorageKey(
            prefix: keyPrefix,
            workspaceId: toWorkspaceId,
            sessionId: toSessionId
        )
        guard sourceKey != destinationKey else { return 0 }

        let sourceComments = try storedComments(forKey: sourceKey)
        let staged = sourceComments.filter { $0.status == .staged }
        guard !staged.isEmpty else { return 0 }

        var destinationComments = try storedComments(forKey: destinationKey)
        var destinationIds = Set(destinationComments.map(\.id))
        for comment in staged where destinationIds.insert(comment.id).inserted {
            destinationComments.append(comment.retargeted(
                workspaceId: toWorkspaceId,
                sessionId: toSessionId
            ))
        }
        let remainingSourceComments = sourceComments.filter { $0.status != .staged }

        let destinationData: Data
        let sourceData: Data
        do {
            destinationData = try JSONEncoder().encode(destinationComments)
            sourceData = try JSONEncoder().encode(remainingSourceComments)
        } catch {
            throw ReviewCommentStoreError.invalidStoredComments
        }

        let journal = ReviewCommentMoveJournal(
            sourceKey: sourceKey,
            destinationKey: destinationKey,
            sourceData: sourceData,
            destinationData: destinationData
        )
        let journalData: Data
        do {
            journalData = try JSONEncoder().encode(journal)
        } catch {
            throw ReviewCommentStoreError.invalidStoredComments
        }

        defaults.set(journalData, forKey: Self.moveJournalKey(prefix: keyPrefix))
        defaults.set(destinationData, forKey: destinationKey)
        defaults.set(sourceData, forKey: sourceKey)
        defaults.removeObject(forKey: Self.moveJournalKey(prefix: keyPrefix))
        if storageKey == sourceKey {
            comments = remainingSourceComments
        } else if storageKey == destinationKey {
            comments = destinationComments
        }
        lastError = nil
        return staged.count
    }

    func appendReviewBlock(
        to text: String,
        pathFormatting: ReviewCommentPathFormatting = .normalizedDisplay
    ) -> String {
        let block = Self.reviewBlock(for: stagedComments, pathFormatting: pathFormatting)
        guard !block.isEmpty else { return text }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return block
        }
        return "\(trimmed)\n\n\(block)"
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

    private func recoverPendingMove() throws {
        let key = Self.moveJournalKey(prefix: keyPrefix)
        guard let data = defaults.data(forKey: key) else { return }
        let journal: ReviewCommentMoveJournal
        do {
            journal = try JSONDecoder().decode(ReviewCommentMoveJournal.self, from: data)
        } catch {
            throw ReviewCommentStoreError.invalidStoredComments
        }
        defaults.set(journal.destinationData, forKey: journal.destinationKey)
        defaults.set(journal.sourceData, forKey: journal.sourceKey)
        defaults.removeObject(forKey: key)
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

    static func moveJournalKey(prefix: String) -> String {
        "\(prefix).moveJournal.v1"
    }

    static func reviewBlock(
        for comments: [ReviewComment],
        pathFormatting: ReviewCommentPathFormatting = .normalizedDisplay
    ) -> String {
        let staged = comments
            .filter { $0.status == .staged }
            .sorted { $0.createdAt < $1.createdAt }
        guard !staged.isEmpty else { return "" }

        var lines: [String] = [
            "## Review comments",
            "",
            "Please address these review comments.",
            "",
        ]

        for (index, comment) in staged.enumerated() {
            lines.append("### Comment \(index + 1)")
            lines.append("")
            let title = referenceTitle(
                comment.reference,
                pathFormatting: pathFormatting
            )
            lines.append("**Where:** \(title)")

            if let selectedText = comment.reference.selectedText,
               !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("")
                lines.append("**Selected text:**")
                lines.append("")
                lines.append(contentsOf: fencedContextLines(
                    selectedText,
                    language: comment.reference.languageHint ?? languageHint(for: comment.reference.path),
                    maxLines: 12
                ))
            }

            lines.append("")
            lines.append("**Comment:**")
            lines.append("")
            lines.append(contentsOf: quotedCommentLines(comment.body))

            if index < staged.count - 1 {
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func referenceTitle(
        _ reference: ReviewCommentReference,
        pathFormatting: ReviewCommentPathFormatting
    ) -> String {
        let source = sourceDisplayName(reference.source)
        let path = switch pathFormatting {
        case .normalizedDisplay: reference.displayPath
        case .verbatim: reference.path
        }
        if let path, !path.isEmpty {
            var title = "`\(path)`"
            if let start = reference.startLine {
                if let end = reference.endLine, end != start {
                    title += ":\(start)-\(end)"
                } else {
                    title += ":\(start)"
                }
            }
            if let side = reference.side {
                title += " (\(side), \(source))"
            } else {
                title += " (\(source))"
            }
            return title
        }

        if let label = reference.label, !label.isEmpty {
            return "\(label) (\(source))"
        }

        return source
    }

    private static func fencedContextLines(_ text: String, language: String?, maxLines: Int) -> [String] {
        let contextLines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(maxLines)
            .map(String.init)
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: contextLines.joined(separator: "\n")) + 1))
        let languageSuffix = language.map { $0 } ?? ""
        return ["\(fence)\(languageSuffix)"]
            + contextLines
            + ["\(fence)"]
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private static func languageHint(for path: String?) -> String? {
        guard let ext = path?.split(separator: ".").last?.lowercased() else { return nil }
        switch ext {
        case "swift":
            return "swift"
        case "ts", "tsx":
            return "typescript"
        case "js", "jsx", "mjs", "cjs":
            return "javascript"
        case "py":
            return "python"
        case "go":
            return "go"
        case "rs":
            return "rust"
        case "rb":
            return "ruby"
        case "sh", "bash", "zsh":
            return "bash"
        case "json":
            return "json"
        case "yaml", "yml":
            return "yaml"
        case "md", "markdown":
            return "markdown"
        case "html":
            return "html"
        case "css":
            return "css"
        default:
            return nil
        }
    }

    private static func quotedCommentLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.isEmpty ? ">" : "> \(line)"
        }
    }

    private static func sourceDisplayName(_ source: ReviewCommentReferenceSource) -> String {
        switch source {
        case .gitDiff:
            return "git diff"
        case .file:
            return "file"
        case .timelineText:
            return "timeline text"
        case .toolOutput:
            return "tool output"
        case .terminalOutput:
            return "terminal output"
        case .image:
            return "image"
        case .unknown:
            return "unknown source"
        }
    }
}

private extension ReviewComment {
    func retargeted(workspaceId: String, sessionId: String) -> ReviewComment {
        ReviewComment(
            id: id,
            workspaceId: workspaceId,
            sessionId: sessionId,
            turnId: turnId,
            author: author,
            status: status,
            severity: severity,
            body: body,
            attachments: attachments,
            reference: reference,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sentAt: sentAt
        )
    }
}
