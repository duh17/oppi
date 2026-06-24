import Foundation
import Observation

enum ReviewCommentStoreError: LocalizedError {
    case emptyBody

    var errorDescription: String? {
        switch self {
        case .emptyBody:
            return "Review comment body is required."
        }
    }
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

    func appendReviewBlock(to text: String) -> String {
        let block = Self.reviewBlock(for: stagedComments)
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
        guard let data = defaults.data(forKey: key) else {
            comments = []
            lastError = nil
            return
        }

        do {
            comments = try JSONDecoder().decode([ReviewComment].self, from: data)
            lastError = nil
        } catch {
            comments = []
            lastError = "Failed to load local review comments: \(error.localizedDescription)"
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

    private static func makeStorageKey(prefix: String, workspaceId: String, sessionId: String) -> String {
        "\(prefix).\(workspaceId).\(sessionId)"
    }

    static func reviewBlock(for comments: [ReviewComment]) -> String {
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
            lines.append("**Where:** \(referenceTitle(comment.reference))")

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

    private static func referenceTitle(_ reference: ReviewCommentReference) -> String {
        let source = sourceDisplayName(reference.source)
        if let path = reference.displayPath, !path.isEmpty {
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
