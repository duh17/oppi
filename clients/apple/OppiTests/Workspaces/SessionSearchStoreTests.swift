import Foundation
import Testing
@testable import Oppi

@MainActor
private final class ControlledSessionSearchClient: SessionSearching {
    var pending: [String: CheckedContinuation<SessionSearchResponse, Never>] = [:]
    var requestedScopes: [String?] = []
    var returnedScopes: Set<String> = []

    func searchSessions(query: String, workspaceId: String?, limit: Int) async throws -> SessionSearchResponse {
        requestedScopes.append(workspaceId)
        let scope = workspaceId ?? "all"
        let response = await withCheckedContinuation { pending[scope] = $0 }
        returnedScopes.insert(scope)
        return response
    }

    func complete(scope: String, sessionID: String) {
        pending.removeValue(forKey: scope)?.resume(returning: SessionSearchResponse(
            results: [SessionSearchResult(
                sessionId: sessionID, workspaceId: scope, title: "Search hit",
                snippet: "Found <b>needle</b>", rank: 1, session: nil
            )],
            query: "needle", totalResults: 1
        ))
    }
}

// swiftlint:disable force_unwrapping

@Suite("SessionSearchStore", .serialized)
@MainActor
struct SessionSearchStoreTests {
    @Test func shortQueriesClearServerSearchState() {
        let store = SessionSearchStore()

        store.search(query: "ab", workspaceId: "ws-1", apiClient: makeClient())

        #expect(store.results.isEmpty)
        #expect(store.matchedSessionIds.isEmpty)
        #expect(store.snippetsBySessionId.isEmpty)
        #expect(store.activeServerQuery == nil)
        #expect(store.completedServerQuery == nil)
        #expect(store.isSearching == false)
    }

    @Test func parseSnippetTurnsBoldMarkersIntoPlainSearchTextAndEmphasis() {
        let attributed = SessionSearchStore.parseSnippet("Fixed <b>launch</b> flash")

        #expect(String(attributed.characters) == "Fixed launch flash")
        let emphasizedRuns = attributed.runs.filter { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        #expect(emphasizedRuns.count == 1)
        if let run = emphasizedRuns.first {
            #expect(String(attributed.characters[run.range]) == "launch")
        }
    }

    @Test func failedServerSearchClearsStaleServerState() async {
        let store = SessionSearchStore()
        let client = makeClient()
        defer { TestURLProtocol.handler = nil }

        TestURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        store.search(query: "offline", workspaceId: "ws-1", apiClient: client)

        let completed = await waitUntil(timeoutMs: 1_500) {
            store.isSearching == false && store.activeServerQuery == nil
        }
        #expect(completed)
        #expect(store.results.isEmpty)
        #expect(store.matchedSessionIds.isEmpty)
        #expect(store.snippetsBySessionId.isEmpty)
        #expect(store.completedServerQuery == nil)
    }

    @Test func sameQueryScopeChangeClearsCompletedResultsAndSnippetsImmediately() async {
        let store = SessionSearchStore()
        let client = ControlledSessionSearchClient()
        store.search(query: "needle", apiClient: client)
        #expect(await waitUntil(timeoutMs: 1_000) { client.pending["all"] != nil })
        client.complete(scope: "all", sessionID: "global-hit")
        #expect(await waitUntil(timeoutMs: 1_000) { store.completedServerQuery != nil })
        #expect(store.matchedSessionIds == ["global-hit"])
        #expect(store.snippetsBySessionId["global-hit"] != nil)

        store.search(query: "needle", workspaceId: "ws-2", apiClient: client)
        #expect(store.isSearching)
        #expect(store.results.isEmpty)
        #expect(store.snippetsBySessionId.isEmpty)
        #expect(store.completedServerQuery == nil)
        #expect(await waitUntil(timeoutMs: 1_000) { client.pending["ws-2"] != nil })
        client.complete(scope: "ws-2", sessionID: "scoped-hit")
        #expect(await waitUntil(timeoutMs: 1_000) { !store.isSearching })
        #expect(store.matchedSessionIds == ["scoped-hit"])
        #expect(client.requestedScopes == [nil, "ws-2"])
    }

    @Test func lateOldScopeResponseCannotReplaceNewScopeResults() async {
        let store = SessionSearchStore()
        let client = ControlledSessionSearchClient()
        store.search(query: "needle", workspaceId: "ws-1", apiClient: client)
        #expect(await waitUntil(timeoutMs: 1_000) { client.pending["ws-1"] != nil })
        store.search(query: "needle", apiClient: client)
        #expect(await waitUntil(timeoutMs: 1_000) { client.pending["all"] != nil })
        client.complete(scope: "all", sessionID: "new-hit")
        #expect(await waitUntil(timeoutMs: 1_000) { !store.isSearching })

        // This fake deliberately ignores cancellation like a late HTTP reply.
        client.complete(scope: "ws-1", sessionID: "old-hit")
        #expect(await waitUntil(timeoutMs: 1_000) { client.returnedScopes.contains("ws-1") })
        // Give the resumed search task a main-actor turn to apply (or reject) it.
        await Task.yield()
        #expect(store.matchedSessionIds == ["new-hit"])
        #expect(store.snippetsBySessionId["old-hit"] == nil)
        #expect(store.completedServerQuery == "needle")
        #expect(client.requestedScopes == ["ws-1", nil])
    }

    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "http://localhost:7749")!,
            token: "sk_test",
            configuration: config
        )
    }

    private func waitUntil(timeoutMs: Int, condition: @MainActor () -> Bool) async -> Bool {
        let attempts = max(1, timeoutMs / 20)
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
