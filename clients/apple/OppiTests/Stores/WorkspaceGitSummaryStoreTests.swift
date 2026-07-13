import Foundation
import Testing
@testable import Oppi

@Suite("Workspace Git summary store")
@MainActor
struct WorkspaceGitSummaryStoreTests {
    @Test func catalogProbeFailurePreservesLastTrustworthyGitState() async throws {
        let store = WorkspaceStore()
        store.setActiveServer("server-1")
        let gitSummary = WorkspaceGitSummary(
            isGitRepo: true,
            changedCount: 9,
            ahead: 2,
            behind: 0
        )
        let initial = WorkspaceListSummary(
            workspaceId: "w1",
            activeCount: 1,
            stoppedCount: 0,
            hasAttention: false,
            gitSummary: gitSummary
        )
        store.setStoredWorkspaceSummariesForTesting(["w1": initial])
        store.workspaceSummaries = ["w1": initial]

        TestURLProtocol.handler = { request in
            let responseURL = try #require(request.url)
            let json: String
            switch responseURL.path {
            case "/workspaces":
                json = #"{"serverNow":1,"workspaces":[{"id":"w1","name":"Oppi","hostMount":"/tmp/oppi","createdAt":0,"updatedAt":0}],"summaries":[{"workspaceId":"w1","activeCount":1,"stoppedCount":0,"hasAttention":false,"hasErrorRoot":false}]}"#
            case "/skills":
                json = #"{"skills":[]}"#
            default:
                throw URLError(.badURL)
            }
            let response = try #require(HTTPURLResponse(
                url: responseURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (Data(json.utf8), response)
        }
        defer { TestURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let api = APIClient(
            baseURL: try #require(URL(string: "https://preview.oppi")),
            token: "token",
            configuration: configuration
        )

        await store.loadServer(serverId: "server-1", api: api)

        #expect(store.workspaceSummaries["w1"]?.gitSummary == gitSummary)
        #expect(store.storedWorkspaceSummaries["w1"]?.gitSummary == gitSummary)
    }

    @Test func refreshReplacesGitStateWithoutLosingSessionSummary() {
        let store = WorkspaceStore()
        store.setActiveServer("server-1")
        let initial = WorkspaceListSummary(
            workspaceId: "w1",
            activeCount: 2,
            stoppedCount: 3,
            hasAttention: true,
            gitSummary: WorkspaceGitSummary(
                isGitRepo: true,
                changedCount: 1,
                ahead: 0,
                behind: 0
            )
        )
        store.setStoredWorkspaceSummariesForTesting(["w1": initial])
        store.workspaceSummaries = ["w1": initial]

        let refreshed = WorkspaceGitSummary(
            isGitRepo: true,
            changedCount: 14,
            ahead: 3,
            behind: 1
        )
        store.updateGitSummary(refreshed, workspaceId: "w1")

        #expect(store.workspaceSummaries["w1"]?.gitSummary == refreshed)
        #expect(store.storedWorkspaceSummaries["w1"]?.gitSummary == refreshed)
        #expect(store.workspaceSummaries["w1"]?.activeCount == 2)
        #expect(store.workspaceSummaries["w1"]?.hasAttention == true)
    }
}
