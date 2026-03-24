import Foundation
import Testing
@testable import Oppi

typealias WorkspaceReviewMockURLProtocol = TestURLProtocol

@Suite("Workspace review API")
struct WorkspaceReviewAPITests {

    @Test func getWorkspaceReviewDiffUsesWorkspaceScopedEndpoint() async throws {
        let client = makeClient()
        defer { WorkspaceReviewMockURLProtocol.handler = nil }

        WorkspaceReviewMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let path = components?.queryItems?.first(where: { $0.name == "path" })?.value

            #expect(url.path == "/workspaces/w1/review/diff")
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

    @Test func createWorkspaceReviewSessionPostsSelectionAndAction() async throws {
        let client = makeClient()
        defer { WorkspaceReviewMockURLProtocol.handler = nil }

        WorkspaceReviewMockURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/workspaces/w1/review/session")

            let body = self.requestBodyData(request)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["action"] as? String == "prepare_commit")
            #expect(json?["selectedSessionId"] as? String == "s1")
            #expect(json?["paths"] as? [String] == ["Sources/App.swift", "README.md"])

            return self.mockResponse(json: """
            {
              "action": "prepare_commit",
              "selectedPathCount": 2,
              "session": {
                "id": "s-new",
                "workspaceId": "w1",
                "workspaceName": "Workspace",
                "name": "Prepare commit: 2 files",
                "status": "ready",
                "createdAt": 1,
                "lastActivity": 1,
                "messageCount": 1,
                "tokens": { "input": 0, "output": 0 },
                "cost": 0
              },
              "visiblePrompt": "Prepare a commit for these selected changes.",
              "contextSummary": [
                { "kind": "file_diff", "path": "Sources/App.swift", "addedLines": 5, "removedLines": 2 },
                { "kind": "file_diff", "path": "README.md", "addedLines": 1, "removedLines": 0 }
              ]
            }
            """)
        }

        let response = try await client.createWorkspaceReviewSession(
            workspaceId: "w1",
            action: .prepareCommit,
            paths: ["Sources/App.swift", "README.md"],
            selectedSessionId: "s1"
        )
        #expect(response.action == .prepareCommit)
        #expect(response.selectedPathCount == 2)
        #expect(response.session.id == "s-new")
        #expect(response.session.workspaceId == "w1")
        #expect(response.visiblePrompt == "Prepare a commit for these selected changes.")
        #expect(response.contextSummary.count == 2)
        #expect(response.contextSummary[0].path == "Sources/App.swift")
        #expect(response.contextSummary[0].addedLines == 5)
        #expect(response.contextSummary[0].removedLines == 2)
        #expect(response.contextSummary[1].path == "README.md")
        #expect(response.contextSummary[1].addedLines == 1)
        #expect(response.contextSummary[1].removedLines == 0)
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
