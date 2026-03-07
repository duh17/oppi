import Foundation
import Testing
@testable import Oppi

// swiftlint:disable force_unwrapping

@Suite("AppletStore", .serialized)
struct AppletStoreTests {
    @MainActor
    @Test func loadStoresAppletListForWorkspace() async {
        defer { AppletStoreMockURLProtocol.handler = nil }

        AppletStoreMockURLProtocol.handler = { request in
            #expect(request.url?.path == "/workspaces/w1/applets")
            return self.mockResponse(
                url: request.url,
                json: """
                {
                  "applets": [
                    {
                      "id": "a1",
                      "workspaceId": "w1",
                      "title": "First",
                      "currentVersion": 1,
                      "createdAt": 1700000000000,
                      "updatedAt": 1700000010000
                    },
                    {
                      "id": "a2",
                      "workspaceId": "w1",
                      "title": "Second",
                      "currentVersion": 2,
                      "createdAt": 1700000020000,
                      "updatedAt": 1700000030000
                    }
                  ]
                }
                """
            )
        }

        let store = AppletStore()
        await store.load(workspaceId: "w1", api: makeAPIClient())

        #expect(store.loadedWorkspaceId == "w1")
        #expect(store.applets(for: "w1").map(\.id) == ["a1", "a2"])
        #expect(store.applets(for: "other").isEmpty)
        #expect(store.lastError == nil)
        #expect(store.isLoading == false)
    }

    @MainActor
    @Test func loadFailureSetsLastErrorAndKeepsWorkspaceSelection() async {
        defer { AppletStoreMockURLProtocol.handler = nil }

        AppletStoreMockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let store = AppletStore()
        await store.load(workspaceId: "w1", api: makeAPIClient())

        #expect(store.loadedWorkspaceId == "w1")
        #expect(store.applets(for: "w1").isEmpty)
        #expect(store.lastError != nil)
        #expect(store.isLoading == false)
    }

    @MainActor
    @Test func staleLoadResultIsIgnoredAfterWorkspaceSwitch() async throws {
        defer { AppletStoreMockURLProtocol.handler = nil }

        AppletStoreMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/workspaces/w1/applets" {
                Thread.sleep(forTimeInterval: 0.15)
                return self.mockResponse(
                    url: request.url,
                    json: """
                    {
                      "applets": [
                        {
                          "id": "old-w1",
                          "workspaceId": "w1",
                          "title": "Old",
                          "currentVersion": 1,
                          "createdAt": 1700000000000,
                          "updatedAt": 1700000005000
                        }
                      ]
                    }
                    """
                )
            }

            if path == "/workspaces/w2/applets" {
                return self.mockResponse(
                    url: request.url,
                    json: """
                    {
                      "applets": [
                        {
                          "id": "new-w2",
                          "workspaceId": "w2",
                          "title": "New",
                          "currentVersion": 1,
                          "createdAt": 1700000010000,
                          "updatedAt": 1700000020000
                        }
                      ]
                    }
                    """
                )
            }

            Issue.record("Unexpected path: \(path)")
            return self.mockResponse(url: request.url, status: 404, json: "{\"error\":\"not found\"}")
        }

        let store = AppletStore()
        let api = makeAPIClient()

        let staleLoad = Task { @MainActor in
            await store.load(workspaceId: "w1", api: api)
        }

        try await Task.sleep(for: .milliseconds(20))
        await store.load(workspaceId: "w2", api: api)
        await staleLoad.value

        #expect(store.loadedWorkspaceId == "w2")
        #expect(store.applets(for: "w2").map(\.id) == ["new-w2"])
        #expect(store.applets(for: "w1").isEmpty)
    }

    @MainActor
    @Test func refreshIfNeededOnlyLoadsWhenWorkspaceChanges() async {
        defer { AppletStoreMockURLProtocol.handler = nil }

        let counter = RequestCounter()

        AppletStoreMockURLProtocol.handler = { request in
            counter.increment()

            return self.mockResponse(
                url: request.url,
                json: """
                {
                  "applets": [
                    {
                      "id": "\(request.url?.path.contains("w2") == true ? "a2" : "a1")",
                      "workspaceId": "\(request.url?.path.contains("w2") == true ? "w2" : "w1")",
                      "title": "T",
                      "currentVersion": 1,
                      "createdAt": 1700000000000,
                      "updatedAt": 1700000000000
                    }
                  ]
                }
                """
            )
        }

        let store = AppletStore()
        let api = makeAPIClient()

        await store.load(workspaceId: "w1", api: api)
        await store.refreshIfNeeded(workspaceId: "w1", api: api)
        await store.refreshIfNeeded(workspaceId: "w2", api: api)

        #expect(counter.value == 2)
        #expect(store.loadedWorkspaceId == "w2")
    }

    private func makeAPIClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AppletStoreMockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "http://localhost:7749")!,
            token: "sk_test",
            configuration: config
        )
    }

    private func mockResponse(
        url: URL?,
        status: Int = 200,
        json: String
    ) -> (Data, HTTPURLResponse) {
        let data = Data(json.utf8)
        let response = HTTPURLResponse(
            url: url ?? URL(string: "http://localhost:7749")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "AppletStoreTests.RequestCounter")
    private var storage = 0

    func increment() {
        queue.sync {
            storage += 1
        }
    }

    var value: Int {
        queue.sync { storage }
    }
}

typealias AppletStoreMockURLProtocol = TestURLProtocol
