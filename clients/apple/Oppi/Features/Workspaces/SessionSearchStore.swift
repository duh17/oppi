import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "SessionSearchStore")

/// Manages server-side full-text session search with debouncing.
///
/// Short queries (< 3 chars) are not sent to the server — the caller
/// should fall back to local `FuzzyMatch` on session titles.
@Observable @MainActor
final class SessionSearchStore {
    /// Server search results, ordered by FTS5 BM25 relevance.
    private(set) var results: [SessionSearchResult] = []

    /// Whether a server search request is in-flight.
    private(set) var isSearching = false

    /// Set of session IDs from server search (for fast lookup).
    private(set) var matchedSessionIds: Set<String> = []

    /// Snippets keyed by session ID for display in rows.
    private(set) var snippetsBySessionId: [String: AttributedString] = [:]

    /// Normalized query currently in-flight against the server.
    private(set) var activeServerQuery: String?

    /// Normalized query with a completed successful server response.
    private(set) var completedServerQuery: String?

    private var searchTask: Task<Void, Never>?

    /// Minimum query length before we hit the server.
    static let minQueryLength = SessionListSearchPresentation.minServerQueryLength

    /// Debounce interval between keystrokes.
    private static let debounceMs: UInt64 = 200

    /// Trigger a server search. Cancels any in-flight request.
    func search(query: String, workspaceId: String? = nil, apiClient: APIClient?) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = trimmed.lowercased()
        guard trimmed.count >= Self.minQueryLength, let apiClient else {
            results = []
            matchedSessionIds = []
            snippetsBySessionId = [:]
            activeServerQuery = nil
            completedServerQuery = nil
            isSearching = false
            return
        }

        // Reset state immediately for a new server query so stale results are not reused.
        results = []
        matchedSessionIds = []
        snippetsBySessionId = [:]
        activeServerQuery = normalizedQuery
        completedServerQuery = nil
        isSearching = true

        searchTask = Task {
            // Debounce
            try? await Task.sleep(for: .milliseconds(Self.debounceMs))
            guard !Task.isCancelled else { return }

            do {
                let response = try await apiClient.searchSessions(
                    query: trimmed,
                    workspaceId: workspaceId,
                    limit: 50
                )
                guard !Task.isCancelled else { return }
                guard activeServerQuery == normalizedQuery else { return }

                results = response.results
                matchedSessionIds = Set(response.results.map(\.sessionId))

                // Parse <b>...</b> snippets into AttributedString
                var snippets: [String: AttributedString] = [:]
                for result in response.results {
                    if let raw = result.snippet, !raw.isEmpty {
                        snippets[result.sessionId] = Self.parseSnippet(raw)
                    }
                }
                snippetsBySessionId = snippets
                completedServerQuery = normalizedQuery
                isSearching = false
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Search failed: \(error.localizedDescription)")
                if activeServerQuery == normalizedQuery {
                    activeServerQuery = nil
                    completedServerQuery = nil
                    results = []
                    matchedSessionIds = []
                    snippetsBySessionId = [:]
                    isSearching = false
                }
            }
        }
    }

    /// Clear all search state.
    func clear() {
        searchTask?.cancel()
        results = []
        matchedSessionIds = []
        snippetsBySessionId = [:]
        activeServerQuery = nil
        completedServerQuery = nil
        isSearching = false
    }

    // MARK: - Snippet parsing

    /// Parse HTML-like `<b>...</b>` markers into an AttributedString with bold ranges.
    static func parseSnippet(_ html: String) -> AttributedString {
        var result = AttributedString()
        var remaining = html[...]

        while !remaining.isEmpty {
            if let boldStart = remaining.range(of: "<b>") {
                // Text before <b>
                let prefix = remaining[remaining.startIndex..<boldStart.lowerBound]
                if !prefix.isEmpty {
                    result.append(AttributedString(String(prefix)))
                }
                remaining = remaining[boldStart.upperBound...]

                // Find closing </b>
                if let boldEnd = remaining.range(of: "</b>") {
                    let boldText = remaining[remaining.startIndex..<boldEnd.lowerBound]
                    var bold = AttributedString(String(boldText))
                    bold.inlinePresentationIntent = .stronglyEmphasized
                    bold.foregroundColor = .themeYellow
                    result.append(bold)
                    remaining = remaining[boldEnd.upperBound...]
                } else {
                    // No closing tag — append rest as-is
                    result.append(AttributedString(String(remaining)))
                    break
                }
            } else {
                // No more <b> tags
                result.append(AttributedString(String(remaining)))
                break
            }
        }

        return result
    }
}
