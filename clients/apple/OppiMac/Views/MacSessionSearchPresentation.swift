import Foundation

/// Mac Home session search. Shared `SessionListSearchPresentation` owns matching;
/// this type maps hits onto Mac inbox targets and list chrome.
enum MacSessionSearchPresentation {
    struct Match: Equatable {
        let target: MacSelectedSessionTarget
        let snippet: AttributedString?
    }

    enum ListContent: Equatable {
        case groupedInbox
        case searching
        case noMatches(query: String)
        case results([Match])

        static func resolve(
            query: String,
            matches: [Match]?,
            isSearching: Bool
        ) -> Self {
            guard let matches else { return .groupedInbox }
            if isSearching && matches.isEmpty {
                return .searching
            }
            if matches.isEmpty {
                return .noMatches(query: SessionListSearchPresentation.normalizedQuery(query))
            }
            return .results(matches)
        }
    }

    static func matches(
        localTargets: [MacSelectedSessionTarget],
        query: String,
        extraCandidates: (Session) -> [String?] = { _ in [] },
        serverResults: [SessionSearchResult] = [],
        completedServerQuery: String? = nil,
        activeServerQuery: String? = nil,
        snippetsBySessionId: [String: AttributedString] = [:]
    ) -> [Match]? {
        let localByID = Dictionary(uniqueKeysWithValues: localTargets.map { ($0.sessionId, $0) })
        guard let flattened = SessionListSearchPresentation.flattenedMatches(
            localSessions: localTargets.map(\.summary.session),
            query: query,
            extraCandidates: { session in
                [localByID[session.id]?.workspaceId] + extraCandidates(session)
            },
            serverResults: serverResults,
            completedServerQuery: completedServerQuery,
            activeServerQuery: activeServerQuery,
            snippetsBySessionId: snippetsBySessionId
        ) else {
            return nil
        }

        return flattened.compactMap { match in
            if let existing = localByID[match.session.id] {
                return Match(target: existing, snippet: match.snippet)
            }
            let workspaceId = match.session.workspaceId
            guard let workspaceId, !workspaceId.isEmpty else { return nil }
            return Match(
                target: MacSelectedSessionTarget(
                    workspaceId: workspaceId,
                    sessionId: match.session.id,
                    summary: SessionSummary(from: match.session)
                ),
                snippet: match.snippet
            )
        }
    }

    static func matchingRuntimeSessions(
        _ sessions: [StatsActiveSession],
        query: String
    ) -> [StatsActiveSession] {
        let normalized = SessionListSearchPresentation.normalizedQuery(query)
        guard !normalized.isEmpty else { return sessions }

        return sessions.filter { session in
            let candidates: [String?] = [
                session.displayTitle,
                session.workspaceName,
                session.model,
                session.id,
            ]
            return SessionListSearchPresentation.matchesLocally(
                session: Session(
                    id: session.id,
                    workspaceId: nil,
                    workspaceName: session.workspaceName,
                    name: session.name,
                    status: .busy,
                    createdAt: Date(timeIntervalSince1970: 0),
                    lastActivity: Date(timeIntervalSince1970: 0),
                    model: session.model,
                    messageCount: 0,
                    tokens: TokenUsage(input: 0, output: 0),
                    cost: session.cost
                ),
                query: normalized,
                extraCandidates: candidates
            )
        }
    }
}
