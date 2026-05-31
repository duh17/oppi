import Foundation
import Testing
@testable import Oppi

final class WorkspaceReviewMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("Workspace review API")
struct WorkspaceReviewAPITests {

    @Test func getWorkspaceReviewDiffUsesGitDiffEndpoint() async throws {
        let client = makeClient()
        defer { WorkspaceReviewMockURLProtocol.handler = nil }

        WorkspaceReviewMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let path = components?.queryItems?.first(where: { $0.name == "path" })?.value

            #expect(url.path == "/workspaces/w1/git/diff")
            #expect(path == "Sources/App.swift")

            return self.mockResponse(json: """
            {
              "workspaceId": "w1",
              "path": "Sources/App.swift",
              "baselineText": "let value = oldName",
              "currentText": "let value = newName",
              "addedLines": 1,
              "removedLines": 1,
              "hunks": [
                {
                  "oldStart": 1,
                  "oldCount": 1,
                  "newStart": 1,
                  "newCount": 1,
                  "lines": [
                    {
                      "kind": "removed",
                      "text": "let value = oldName",
                      "oldLine": 1,
                      "newLine": null,
                      "spans": [{ "start": 12, "end": 19, "kind": "changed" }]
                    },
                    {
                      "kind": "added",
                      "text": "let value = newName",
                      "oldLine": null,
                      "newLine": 1,
                      "spans": [{ "start": 12, "end": 19, "kind": "changed" }]
                    }
                  ]
                }
              ]
            }
            """)
        }

        let response = try await client.getWorkspaceReviewDiff(workspaceId: "w1", path: "Sources/App.swift")
        #expect(response.workspaceId == "w1")
        #expect(response.path == "Sources/App.swift")
        #expect(response.addedLines == 1)
        #expect(response.removedLines == 1)
        #expect(response.hunks.count == 1)
        #expect(response.hunks[0].lines.count == 2)
        #expect(response.hunks[0].lines[0].spans?.count == 1)
        #expect(response.hunks[0].lines[1].spans?.count == 1)
    }

    @Test func getWorkspaceQuickActionsUsesPromptTemplateOptionsEndpoint() async throws {
        let client = makeClient()
        defer { WorkspaceReviewMockURLProtocol.handler = nil }

        WorkspaceReviewMockURLProtocol.handler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/workspaces/w1/quick-actions")

            return self.mockResponse(json: """
            {
              "actions": [
                {
                  "id": "prompt:grill-me",
                  "title": "Grill Me",
                  "commandName": "grill-me",
                  "description": "Stress-test selected files",
                  "argumentHint": "FILES",
                  "source": "prompt",
                  "sourceScope": "project",
                  "promptTemplateName": "grill-me"
                }
              ]
            }
            """)
        }

        let response = try await client.getWorkspaceQuickActions(workspaceId: "w1")
        #expect(response.actions.count == 1)
        #expect(response.actions[0].id == "prompt:grill-me")
        #expect(response.actions[0].source == .prompt)
        #expect(response.actions[0].promptTemplateName == "grill-me")
    }

    @Test func createWorkspaceQuickActionSessionPostsTemplateSelectionWithoutFixedAction() async throws {
        let client = makeClient()
        defer { WorkspaceReviewMockURLProtocol.handler = nil }

        WorkspaceReviewMockURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/workspaces/w1/quick-actions/session")

            let body = self.requestBodyData(request)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["action"] == nil)
            #expect(json?["selectedSessionId"] as? String == "s1")
            #expect(json?["promptTemplateName"] as? String == "commit-template")
            #expect(json?["paths"] as? [String] == ["Sources/App.swift", "README.md"])

            return self.mockResponse(json: """
            {
              "promptTemplateName": "commit-template",
              "selectedPathCount": 2,
              "session": {
                "id": "s-new",
                "workspaceId": "w1",
                "workspaceName": "Workspace",
                "name": "Commit Template: 2 files",
                "status": "ready",
                "createdAt": 1,
                "lastActivity": 1,
                "messageCount": 1,
                "tokens": { "input": 0, "output": 0 },
                "cost": 0
              },
              "visiblePrompt": "Prepare a commit for these selected changes.",
              "filePaths": ["Sources/App.swift", "README.md"]
            }
            """)
        }

        let response = try await client.createWorkspaceQuickActionSession(
            workspaceId: "w1",
            paths: ["Sources/App.swift", "README.md"],
            selectedSessionId: "s1",
            promptTemplateName: "commit-template"
        )
        #expect(response.promptTemplateName == "commit-template")
        #expect(response.selectedPathCount == 2)
        #expect(response.session.id == "s-new")
        #expect(response.session.workspaceId == "w1")
        #expect(response.visiblePrompt == "Prepare a commit for these selected changes.")
        #expect(response.filePaths == ["Sources/App.swift", "README.md"])
    }

    private func requestBodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)

        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 {
                break
            }
            data.append(contentsOf: buffer.prefix(read))
        }

        return data
    }

    private func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkspaceReviewMockURLProtocol.self]
        guard let baseURL = URL(string: "http://localhost:8080") else {
            fatalError("Invalid test base URL")
        }
        return APIClient(
            baseURL: baseURL,
            token: "test-token",
            configuration: config
        )
    }

    private func mockResponse(status: Int = 200, json: String) -> (Data, HTTPURLResponse) {
        let data = Data(json.utf8)
        guard let url = URL(string: "http://localhost") else {
            fatalError("Invalid mock response URL")
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            fatalError("Failed to construct HTTPURLResponse")
        }
        return (data, response)
    }
}
