import Foundation
import Testing
@testable import Oppi

@Suite("Workspace Session List Models")
struct WorkspaceSessionListModelsTests {
    @Test func decodesWorkspaceSessionListResponseWithArchiveBuckets() throws {
        let json = """
        {
          "workspace": {
            "id": "w1",
            "name": "Oppi",
            "skills": [],
            "createdAt": 1700000000000,
            "updatedAt": 1700000000000
          },
          "serverNow": 1700004000000,
          "sessions": [
            {
              "id": "s1",
              "workspaceId": "w1",
              "status": "ready",
              "createdAt": 1700000000000,
              "lastActivity": 1700003000000,
              "messageCount": 0,
              "tokens": {"input": 0, "output": 0},
              "cost": 0
            }
          ],
          "attention": {
            "permissions": [],
            "asks": []
          },
          "importableSessions": [
            {
              "path": "/tmp/local.jsonl",
              "piSessionId": "pi-1",
              "cwd": "/Users/example/workspace/oppi",
              "name": "Local Session",
              "messageCount": 3,
              "createdAt": 1700001000000,
              "lastModified": 1700002000000
            }
          ],
          "archiveBuckets": [
            {
              "bucketId": "day:2026-05-10",
              "bucketKind": "day",
              "startMs": 1778396400000,
              "endMs": 1778482800000,
              "itemCount": 17,
              "managedStoppedCount": 16,
              "importableLocalCount": 1,
              "latestActivity": 1778452656439
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(
            APIClient.WorkspaceSessionListResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.workspace.id == "w1")
        #expect(response.sessionSummaries.map(\.id) == ["s1"])
        #expect(response.importableSessions.map(\.path) == ["/tmp/local.jsonl"])
        #expect(response.archiveBuckets.count == 1)
        #expect(response.archiveBuckets[0].id == "day:2026-05-10")
        #expect(response.archiveBuckets[0].kind == .day)
        #expect(response.archiveBuckets[0].managedStoppedCount == 16)
        #expect(response.archiveBuckets[0].importableLocalCount == 1)
        #expect(response.archiveBuckets[0].latestActivity?.timeIntervalSince1970 == 1778452656.439)
    }

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
              "pendingAskCount": 0
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
        #expect(response.sessionSummaries.map(\.id) == ["s-active", "s-old"])
        #expect(response.sessionSummaries.first?.pendingAskCount == 0)
        #expect(response.importableSessions.map(\.path) == ["/tmp/local.jsonl"])
        if case .session(let row) = response.active[0] {
            #expect(row.pendingAskCount == 0)
        } else {
            Issue.record("Expected managed session row")
        }
    }
}
