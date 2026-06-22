import Foundation
import Testing
@testable import Oppi

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
            #expect(run.foregroundColor == .themeYellow)
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
