import Foundation
import Testing
@testable import Oppi

@Suite("Session list search presentation")
struct SessionListSearchPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func emptyQueryDoesNotFlatten() {
        let session = makeSession(id: "recent", name: "Debug Skill Edit")
        let matches = SessionListSearchPresentation.flattenedMatches(
            localSessions: [session],
            query: "   "
        )

        #expect(matches == nil)
    }

    @Test func shortQueryUsesLocalFuzzyMatchAndDropsDayGrouping() {
        let matching = makeSession(id: "skill", name: "Debug Skill Edit Fix")
        let other = makeSession(id: "digest", name: "Daily HN digest")

        let matches = SessionListSearchPresentation.flattenedMatches(
            localSessions: [matching, other],
            query: "skl"
        )

        #expect(matches?.map(\.session.id) == ["skill"])
    }

    @Test func localMatchIncludesWorkspaceAndModel() {
        let workspaceHit = makeSession(
            id: "ws-hit",
            name: "Unrelated title",
            workspaceName: "chaosdonkey.dev"
        )
        let modelHit = makeSession(
            id: "model-hit",
            name: "Unrelated title",
            model: "gpt-5.6-sol"
        )
        let miss = makeSession(id: "miss", name: "Daily digest")

        let workspaceMatches = SessionListSearchPresentation.flattenedMatches(
            localSessions: [workspaceHit, miss],
            query: "chaos"
        )
        let modelMatches = SessionListSearchPresentation.flattenedMatches(
            localSessions: [modelHit, miss],
            query: "gpt56"
        )

        #expect(workspaceMatches?.map(\.session.id) == ["ws-hit"])
        #expect(modelMatches?.map(\.session.id) == ["model-hit"])
    }

    @Test func inFlightServerQueryHidesLocalFallback() {
        let local = makeSession(id: "local", name: "Debug Skill Edit")
        let matches = SessionListSearchPresentation.flattenedMatches(
            localSessions: [local],
            query: "skill",
            activeServerQuery: "skill"
        )

        #expect(matches == [])
    }

    @Test func completedServerResultsIncludeOlderSessionsOutsideLocalProjection() {
        let recent = makeSession(id: "recent", name: "Recent skill edit")
        let older = makeSession(
            id: "older",
            name: "Older skill investigation",
            lastActivity: now.addingTimeInterval(-10 * 86_400)
        )
        let matches = SessionListSearchPresentation.flattenedMatches(
            localSessions: [recent],
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
            snippetsBySessionId: [older.id: AttributedString("Found skill notes")]
        )

        #expect(matches?.map(\.session.id) == ["older", "recent"])
        #expect(matches?.first?.snippet != nil)
    }

    @Test func completedServerResultsKeepLocalFuzzyHitsMissingFromServer() {
        let localOnly = makeSession(id: "local-only", name: "Skill shorthand")
        let serverOnly = makeSession(id: "server-only", name: "Skill archive")
        let matches = SessionListSearchPresentation.flattenedMatches(
            localSessions: [localOnly],
            query: "skill",
            serverResults: [
                SessionSearchResult(
                    sessionId: serverOnly.id,
                    workspaceId: serverOnly.workspaceId ?? "",
                    title: serverOnly.displayTitle,
                    snippet: nil,
                    rank: 0.2,
                    session: serverOnly
                ),
            ],
            completedServerQuery: "skill"
        )

        #expect(matches?.map(\.session.id) == ["server-only", "local-only"])
    }

    @Test func hiddenIncognitoStoppedSessionsStayHidden() {
        var incognito = makeSession(id: "incognito", name: "Skill private")
        incognito.ephemeral = true
        let matches = SessionListSearchPresentation.flattenedMatches(
            localSessions: [incognito],
            query: "skill"
        )

        #expect(matches == [])
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
}
