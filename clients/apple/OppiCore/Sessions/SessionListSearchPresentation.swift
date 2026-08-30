import Foundation

/// Shared session-list search matching and flattened result ordering.
///
/// Short queries stay local so typing feels instant. Queries of
/// `SessionSearchStore.minQueryLength` or more wait for the server FTS
/// response, then merge those hits with any local fuzzy matches so older
/// sessions can appear outside the recent 3-day list projection.
enum SessionListSearchPresentation {
    /// Minimum query length before session lists hit server FTS.
    static let minServerQueryLength = 3

    struct Match: Equatable {
        let session: Session
        let snippet: AttributedString?
    }

    static func normalizedQuery(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func hasQuery(_ raw: String) -> Bool {
        !normalizedQuery(raw).isEmpty
    }

    static func matchesLocally(
        session: Session,
        query: String,
        extraCandidates: [String?] = []
    ) -> Bool {
        let normalized = normalizedQuery(query)
        guard !normalized.isEmpty else { return true }

        let candidates = ([
            session.displayTitle,
            session.workspaceName,
            session.model,
            session.id,
        ] + extraCandidates).compactMap { candidate -> String? in
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        return candidates.contains { FuzzyMatch.match(query: normalized, candidate: $0) != nil }
    }

    static func flattenedMatches(
        localSessions: [Session],
        query: String,
        extraCandidates: (Session) -> [String?] = { _ in [] },
        serverResults: [SessionSearchResult] = [],
        completedServerQuery: String? = nil,
        activeServerQuery: String? = nil,
        snippetsBySessionId: [String: AttributedString] = [:]
    ) -> [Match]? {
        let normalized = normalizedQuery(query)
        guard !normalized.isEmpty else { return nil }

        if normalized.count >= minServerQueryLength,
           activeServerQuery == normalized,
           completedServerQuery != normalized {
            return []
        }

        var matchesByID: [String: Match] = [:]
        var order: [String] = []

        func append(_ session: Session, snippet: AttributedString? = nil) {
            guard SessionInboxStoppedDayPolicy.includesStoppedSession(session)
                    || session.status != .stopped else { return }
            if matchesByID[session.id] == nil {
                order.append(session.id)
            }
            matchesByID[session.id] = Match(
                session: session,
                snippet: snippet ?? snippetsBySessionId[session.id]
            )
        }

        if completedServerQuery == normalized {
            for result in serverResults {
                if let session = result.session {
                    append(session, snippet: snippetsBySessionId[session.id])
                }
            }
        }

        for session in localSessions where matchesLocally(
            session: session,
            query: normalized,
            extraCandidates: extraCandidates(session)
        ) {
            append(session)
        }

        return order.compactMap { matchesByID[$0] }
    }
}
