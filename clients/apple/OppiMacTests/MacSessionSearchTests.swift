import Foundation
import Testing
@testable import Oppi

@Suite("Mac session search")
struct MacSessionSearchTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func emptyQueryKeepsGroupedInbox() {
        let recent = makeTarget(makeSession(id: "recent", name: "Debug Skill Edit"))

        let matches = MacSessionSearchPresentation.matches(
            localTargets: [recent],
            query: "   "
        )
        let content = MacSessionSearchPresentation.ListContent.resolve(
            query: "   ",
            matches: matches,
            isSearching: false
        )

        #expect(matches == nil)
        #expect(content == .groupedInbox)
    }

    @Test func shortQueryUsesSharedFuzzyMatchInsteadOfSubstringFilter() {
        let matching = makeTarget(makeSession(id: "skill", name: "Debug Skill Edit Fix"))
        let other = makeTarget(makeSession(id: "digest", name: "Daily HN digest"))

        let matches = MacSessionSearchPresentation.matches(
            localTargets: [matching, other],
            query: "skl"
        )
        let content = MacSessionSearchPresentation.ListContent.resolve(
            query: "skl",
            matches: matches,
            isSearching: false
        )

        #expect(matches?.map(\.target.sessionId) == ["skill"])
        #expect(content == .results(matches ?? []))
    }

    @Test func inFlightServerQueryShowsSearchingAndHidesLocalFallback() {
        let local = makeTarget(makeSession(id: "local", name: "Debug Skill Edit"))

        let matches = MacSessionSearchPresentation.matches(
            localTargets: [local],
            query: "skill",
            activeServerQuery: "skill"
        )
        let content = MacSessionSearchPresentation.ListContent.resolve(
            query: "skill",
            matches: matches,
            isSearching: true
        )

        #expect(matches == [])
        #expect(content == .searching)
    }

    @Test func completedServerResultsIncludeOlderSessionsOutsideLocalProjection() {
        let recent = makeTarget(makeSession(id: "recent", name: "Recent skill edit"))
        let older = makeSession(
            id: "older",
            name: "Older skill investigation",
            lastActivity: now.addingTimeInterval(-10 * 86_400)
        )
        let snippet = AttributedString("Found skill notes")

        let matches = MacSessionSearchPresentation.matches(
            localTargets: [recent],
            query: "skill",
            serverResults: [
                SessionSearchResult(
                    sessionId: older.id,
                    workspaceId: older.workspaceId ?? "",
                    title: older.displayTitle,
                    snippet: "Found <b>skill</b> notes",
                    rank: 0.1,
                    session: older
                ),
            ],
            completedServerQuery: "skill",
            snippetsBySessionId: [older.id: snippet]
        )
        let content = MacSessionSearchPresentation.ListContent.resolve(
            query: "skill",
            matches: matches,
            isSearching: false
        )

        #expect(matches?.map(\.target.sessionId) == ["older", "recent"])
        #expect(matches?.first?.target.workspaceId == "ws1")
        #expect(matches?.first?.snippet != nil)
        #expect(content == .results(matches ?? []))
    }

    @Test func noServerOrLocalHitsShowEmptyState() {
        let digest = makeTarget(makeSession(id: "digest", name: "Daily HN digest"))
        let matches = MacSessionSearchPresentation.matches(
            localTargets: [digest],
            query: "skill",
            completedServerQuery: "skill"
        )
        let content = MacSessionSearchPresentation.ListContent.resolve(
            query: "skill",
            matches: matches,
            isSearching: false
        )

        #expect(matches == [])
        #expect(content == .noMatches(query: "skill"))
    }

    @Test func searchMatchesFeedRowSnippets() {
        let target = makeTarget(makeSession(id: "skill", name: "Debug Skill Edit"))
        let snippet = AttributedString("Edited the skill file")
        let matches = MacSessionSearchPresentation.matches(
            localTargets: [target],
            query: "skill",
            snippetsBySessionId: [target.sessionId: snippet]
        )

        let presentation = MacSessionInboxPresentation.rowPresentation(
            for: target,
            searchSnippet: matches?.first?.snippet
        )

        let snippetText = presentation.searchSnippet.map { String($0.characters) }
        #expect(snippetText == "Edited the skill file")
    }

    @Test func workspaceClientSearchSessionsUsesOwnerUnixSocketQueryItems() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"""
                {
                  "results": [
                    {
                      "sessionId": "sess-1",
                      "workspaceId": "ws-1",
                      "title": "Launch bug",
                      "snippet": "Fixed <b>launch</b> flash",
                      "rank": 0.25,
                      "session": null
                    }
                  ],
                  "query": "launch bug",
                  "totalResults": 1
                }
                """#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        let response = try await client.searchSessions(
            query: "launch bug",
            workspaceId: "ws-1",
            limit: 7
        )

        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path.hasPrefix("/sessions/search?"))
        #expect(request.path.contains("q=launch%20bug") || request.path.contains("q=launch+bug"))
        #expect(request.path.contains("workspaceId=ws-1"))
        #expect(request.path.contains("limit=7"))
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
        #expect(response.results.map(\.sessionId) == ["sess-1"])
        #expect(response.results.first?.snippet == "Fixed <b>launch</b> flash")
    }

    @Test func runtimeRowsUseSharedFuzzyMatchDuringSearch() {
        let matching = makeRuntimeSession(id: "skill", name: "Debug Skill Edit")
        let other = makeRuntimeSession(id: "digest", name: "Daily HN digest")

        let hits = MacSessionSearchPresentation.matchingRuntimeSessions(
            [matching, other],
            query: "skl"
        )

        #expect(hits.map(\.id) == ["skill"])
        #expect(
            MacSessionSearchPresentation.matchingRuntimeSessions(
                [matching, other],
                query: "   "
            ).map(\.id) == ["skill", "digest"]
        )
    }

    private func makeSession(
        id: String,
        name: String,
        workspaceName: String = "oppi",
        model: String = "openai/gpt-5.5",
        lastActivity: Date? = nil
    ) -> Session {
        Session(
            id: id,
            workspaceId: "ws1",
            workspaceName: workspaceName,
            name: name,
            status: .stopped,
            createdAt: now.addingTimeInterval(-3_600),
            lastActivity: lastActivity ?? now,
            model: model,
            messageCount: 1,
            tokens: TokenUsage(input: 1, output: 1),
            cost: 0
        )
    }

    private func makeTarget(_ session: Session) -> MacSelectedSessionTarget {
        MacSelectedSessionTarget(
            workspaceId: session.workspaceId ?? "ws1",
            sessionId: session.id,
            summary: SessionSummary(from: session)
        )
    }

    private func makeRuntimeSession(id: String, name: String) -> StatsActiveSession {
        StatsActiveSession(
            id: id,
            status: "busy",
            model: "test/model",
            cost: 0,
            name: name,
            firstMessage: nil,
            workspaceName: "Oppi",
            thinkingLevel: nil,
            contextTokens: nil,
            contextWindow: nil,
            createdAt: nil
        )
    }
}
