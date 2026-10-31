import Foundation
import Testing
@testable import Oppi

@Suite("Workspace Session List Models")
struct WorkspaceSessionListModelsTests {
    @Test func decodesWorkspaceSessionCollectionResponseWithTuiRows() throws {
        let json = """
        {
          "workspaceId": "w1",
          "sinceMs": 1778396400000,
          "untilMs": 1778482800000,
          "serverNow": 1778482800000,
          "active": [
            {
              "id": "s-active",
              "workspaceId": "w1",
              "status": "ready",
              "createdAt": 1700000000000,
              "lastActivity": 1700001000000,
              "messageCount": 0,
              "tokens": {"input": 0, "output": 0},
              "cost": 0,
              "pendingAskCount": 2
            },
            {
              "id": "s-null",
              "workspaceId": "w1",
              "status": "ready",
              "createdAt": 1700000000000,
              "lastActivity": 1700001000000,
              "messageCount": 0,
              "tokens": {"input": 0, "output": 0},
              "cost": 0,
              "pendingAskCount": null
            }
          ],
          "stopped": [
            {
              "id": "s-old",
              "workspaceId": "w1",
              "status": "stopped",
              "createdAt": 1700000000000,
              "lastActivity": 1700001000000,
              "messageCount": 0,
              "tokens": {"input": 0, "output": 0},
              "cost": 0
            },
            {
              "id": "/tmp/local.jsonl",
              "source": "tui",
              "status": "stopped",
              "workspaceId": "w1",
              "path": "/tmp/local.jsonl",
              "piSessionId": "pi-1",
              "cwd": "/Users/example/workspace/oppi",
              "name": "Local Session",
              "messageCount": 3,
              "createdAt": 1700001000000,
              "lastModified": 1700002000000,
              "lastActivity": 1700002000000,
              "tokens": {"input": 0, "output": 0},
              "cost": 0
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(
            APIClient.WorkspaceSessionCollectionResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.workspaceId == "w1")
        #expect(response.sessionSummaries.map(\.id) == ["s-active", "s-null", "s-old"])
        #expect(response.importableSessions.map(\.path) == ["/tmp/local.jsonl"])

        // pendingAskCount: present keeps its value, null and absent decode as "not reported".
        let summaries = response.sessionSummaries
        #expect(summaries[0].pendingAskCount == 2)
        #expect(summaries[0].hasPendingAskCount)
        #expect(summaries[1].pendingAskCount == 0)
        #expect(!summaries[1].hasPendingAskCount)
        #expect(summaries[2].pendingAskCount == 0)
        #expect(!summaries[2].hasPendingAskCount)
    }
}
