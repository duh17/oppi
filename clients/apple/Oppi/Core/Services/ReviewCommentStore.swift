import Foundation
import Observation

@MainActor @Observable
final class ReviewCommentStore {
    private(set) var comments: [ReviewComment] = []
    var lastError: String?

    var stagedComments: [ReviewComment] {
        comments(matching: { $0.status == .staged }) { $0.createdAt < $1.createdAt }
    }

    var stagedCount: Int { stagedComments.count }

    var sentOrOpenComments: [ReviewComment] {
        comments(matching: { $0.status == .sent || $0.status == .open }) { $0.updatedAt > $1.updatedAt }
    }

    var resolvedComments: [ReviewComment] {
        comments(matching: { $0.status == .resolved }) { $0.updatedAt > $1.updatedAt }
    }

    func load(api: APIClient, workspaceId: String, sessionId: String? = nil) async {
        do {
            comments = try await api.listReviewComments(
                workspaceId: workspaceId,
                sessionId: sessionId,
                status: nil
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func create(
        api: APIClient,
        workspaceId: String,
        sessionId: String?,
        body: String,
        reference: ReviewCommentReference
    ) async throws -> ReviewComment {
        let comment = try await api.createReviewComment(
            workspaceId: workspaceId,
            sessionId: sessionId,
            body: body,
            reference: reference
        )
        upsert(comment)
        lastError = nil
        return comment
    }

    @discardableResult
    func update(
        api: APIClient,
        workspaceId: String,
        commentId: String,
        body: String? = nil,
        status: ReviewCommentStatus? = nil,
        severity: ReviewCommentSeverity? = nil
    ) async throws -> ReviewComment {
        do {
            let comment = try await api.updateReviewComment(
                workspaceId: workspaceId,
                commentId: commentId,
                body: body,
                status: status,
                severity: severity
            )
            upsert(comment)
            lastError = nil
            return comment
        } catch let APIError.server(status, _) where status == 404 {
            removeLocalComment(id: commentId)
            lastError = "Review comment no longer exists"
            throw APIError.server(status: status, message: "Review comment no longer exists")
        }
    }

    func delete(api: APIClient, workspaceId: String, commentId: String) async throws {
        do {
            try await api.deleteReviewComment(workspaceId: workspaceId, commentId: commentId)
            removeLocalComment(id: commentId)
            lastError = nil
        } catch let APIError.server(status, _) where status == 404 {
            removeLocalComment(id: commentId)
            lastError = nil
        }
    }

    @discardableResult
    func markSent(api: APIClient, workspaceId: String, ids: [String], sessionId: String?) async -> Bool {
        guard !ids.isEmpty else { return true }
        do {
            let updated = try await api.markReviewCommentsSent(
                workspaceId: workspaceId,
                ids: ids,
                sessionId: sessionId
            )
            for comment in updated {
                upsert(comment)
            }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
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
        if let path = reference.path, !path.isEmpty {
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
