import Foundation
import Testing
@testable import Oppi

@Suite("MacWorkspaceClient")
struct MacWorkspaceClientTests {

    @Test func decodesWorkspaceCatalogWithSummaries() throws {
        let data = try #"""
        {
          "workspaces": [
            {
              "id": "ws-1",
              "name": "Oppi",
              "description": "Main repo",
              "icon": "folder.badge.gearshape",
              "hostMount": "/Users/chenda/workspace/oppi",
              "createdAt": 1760000000000,
              "updatedAt": 1760000001000
            }
          ],
          "summaries": [
            {
              "workspaceId": "ws-1",
              "activeCount": 2,
              "stoppedCount": 7,
              "hasAttention": true,
              "hasErrorRoot": false,
              "latestActivity": 1760000002000
            }
          ]
        }
        """#.data(using: .utf8).unwrap()

        let catalog = try MacWorkspaceClient.decodeWorkspaceCatalog(data)

        #expect(catalog.workspaces.map(\.id) == ["ws-1"])
        #expect(catalog.workspaces.first?.name == "Oppi")
        #expect(catalog.summaries["ws-1"]?.activeCount == 2)
        #expect(catalog.summaries["ws-1"]?.stoppedCount == 7)
        #expect(catalog.summaries["ws-1"]?.hasAttention == true)
    }

    @Test func decodesCreateWorkspaceResponse() throws {
        let data = try #"""
        {
          "workspace": {
            "id": "ws-new",
            "name": "New Workspace",
            "description": "Created on Mac",
            "hostMount": "/Users/chenda/workspace/new",
            "runtime": "host",
            "gitStatusEnabled": true,
            "createdAt": 1760000000000,
            "updatedAt": 1760000001000
          }
        }
        """#.data(using: .utf8).unwrap()

        let response = try JSONDecoder().decode(MacWorkspaceClient.WorkspaceResponse.self, from: data)

        #expect(response.workspace.id == "ws-new")
        #expect(response.workspace.name == "New Workspace")
        #expect(response.workspace.hostMount == "/Users/chenda/workspace/new")
    }

    @Test func decodesModelList() throws {
        let data = try #"""
        {
          "models": [
            {
              "id": "openai/gpt-5.5",
              "name": "GPT 5.5",
              "provider": "openai",
              "contextWindow": 200000
            },
            {
              "id": "claude-sonnet-4-5",
              "name": "Claude Sonnet 4.5",
              "provider": "anthropic",
              "contextWindow": 200000
            }
          ]
        }
        """#.data(using: .utf8).unwrap()

        let models = try MacWorkspaceClient.decodeModels(data)

        #expect(models.map(\.id) == ["openai/gpt-5.5", "claude-sonnet-4-5"])
        #expect(models.first?.provider == "openai")
        #expect(models.last?.contextWindow == 200_000)
    }

    @Test func decodesAttachmentUploadResponses() throws {
        let createData = try #"""
        {
          "uploadId": "upload-1",
          "attachmentId": "upload-1",
          "contentUrl": "/workspaces/ws-1/sessions/session-1/attachments/upload-1/content",
          "maxFileBytes": 10485760,
          "expiresAt": 1760000000000
        }
        """#.data(using: .utf8).unwrap()
        let uploadData = try #"""
        {
          "attachment": {
            "type": "chat_attachment",
            "id": "upload-1",
            "source": "upload",
            "name": "note.txt",
            "mimeType": "text/plain",
            "sizeBytes": 5,
            "sha256": "abc123",
            "kind": "text",
            "workspacePath": ".pi/attachments/session/turn/note.txt"
          }
        }
        """#.data(using: .utf8).unwrap()

        let create = try JSONDecoder().decode(MacWorkspaceClient.CreateUploadResponse.self, from: createData)
        let uploaded = try JSONDecoder().decode(MacWorkspaceClient.UploadContentResponse.self, from: uploadData)

        #expect(create.uploadId == "upload-1")
        #expect(create.maxFileBytes == 10_485_760)
        #expect(uploaded.attachment.id == "upload-1")
        #expect(uploaded.attachment.source == .upload)
        #expect(uploaded.attachment.workspacePath == ".pi/attachments/session/turn/note.txt")
    }

    @Test func decodesWorkspaceFileBrowserResponses() throws {
        let listingData = try #"""
        {
          "path": "Sources/",
          "truncated": false,
          "entries": [
            {
              "name": "App",
              "type": "directory",
              "size": 128,
              "modifiedAt": 1760000000000,
              "path": "Sources/App"
            },
            {
              "name": "main.swift",
              "type": "file",
              "size": 42,
              "modifiedAt": 1760000001000,
              "path": "Sources/main.swift"
            }
          ]
        }
        """#.data(using: .utf8).unwrap()
        let indexData = try #"""
        {
          "paths": ["Sources/main.swift", "README.md"],
          "truncated": true
        }
        """#.data(using: .utf8).unwrap()

        let listing = try MacWorkspaceClient.decodeDirectoryListing(listingData)
        let index = try MacWorkspaceClient.decodeFileIndex(indexData)

        #expect(listing.path == "Sources/")
        #expect(listing.entries.map(\.name) == ["App", "main.swift"])
        #expect(listing.entries.first?.isDirectory == true)
        #expect(listing.entries.last?.formattedSize.isEmpty == false)
        #expect(index.paths == ["Sources/main.swift", "README.md"])
        #expect(index.truncated)
    }

    @Test func decodesSessionChanges() throws {
        let data = try #"""
        {
          "workspaceId": "ws-1",
          "sessionId": "session-1",
          "files": [
            { "path": "Sources/App.swift" },
            { "path": "README.md" }
          ],
          "changedFileCount": 5,
          "changedFilesOverflow": 3
        }
        """#.data(using: .utf8).unwrap()

        let changes = try MacWorkspaceClient.decodeSessionChanges(data)

        #expect(changes.workspaceId == "ws-1")
        #expect(changes.sessionId == "session-1")
        #expect(changes.files.map(\.path) == ["Sources/App.swift", "README.md"])
        #expect(changes.changedFileCount == 5)
        #expect(changes.changedFilesOverflow == 3)
    }

    @Test func decodesSessionDiff() throws {
        let data = try #"""
        {
          "workspaceId": "ws-1",
          "path": "Sources/App.swift",
          "baselineText": "old\n",
          "currentText": "new\n",
          "addedLines": 1,
          "removedLines": 1,
          "revisionCount": 2,
          "cacheKey": "session-1:Sources/App.swift:2",
          "hunks": [
            {
              "oldStart": 1,
              "oldCount": 1,
              "newStart": 1,
              "newCount": 1,
              "lines": [
                { "kind": "removed", "text": "old", "oldLine": 1, "newLine": null, "spans": null },
                { "kind": "added", "text": "new", "oldLine": null, "newLine": 1, "spans": null }
              ]
            }
          ]
        }
        """#.data(using: .utf8).unwrap()

        let diff = try MacWorkspaceClient.decodeSessionDiff(data)

        #expect(diff.workspaceId == "ws-1")
        #expect(diff.path == "Sources/App.swift")
        #expect(diff.addedLines == 1)
        #expect(diff.removedLines == 1)
        #expect(diff.revisionCount == 2)
        #expect(diff.hunks.first?.lines.map(\.kind) == [.removed, .added])
    }

    @Test func decodesSessionCommandResponseMessages() throws {
        let data = try #"""
        {
          "messages": [
            {
              "type": "command_result",
              "command": "set_model",
              "requestId": "request-1",
              "success": false,
              "error": "Unknown model"
            }
          ]
        }
        """#.data(using: .utf8).unwrap()

        let messages = try MacWorkspaceClient.decodeSessionCommandResponse(data)

        #expect(messages == [
            .commandResult(
                command: "set_model",
                requestId: "request-1",
                success: false,
                data: nil,
                error: "Unknown model"
            )
        ])
    }

    @Test func decodesWorkspaceCatalogWithoutSummaries() throws {
        let data = try #"""
        {
          "workspaces": [
            {
              "id": "ws-1",
              "name": "Oppi",
              "createdAt": 1760000000000,
              "updatedAt": 1760000001000
            }
          ]
        }
        """#.data(using: .utf8).unwrap()

        let catalog = try MacWorkspaceClient.decodeWorkspaceCatalog(data)

        #expect(catalog.workspaces.count == 1)
        #expect(catalog.summaries.isEmpty)
    }

    @Test func decodesWorkspaceSessionListRows() throws {
        let data = try #"""
        {
          "workspaceId": "ws-1",
          "serverNow": 1760000003000,
          "active": [
            {
              "id": "session-active",
              "workspaceId": "ws-1",
              "workspaceName": "Oppi",
              "name": "Active Chat",
              "status": "busy",
              "createdAt": 1760000000000,
              "lastActivity": 1760000002000,
              "model": "openai/gpt-5.5",
              "messageCount": 4,
              "tokens": { "input": 100, "output": 50 },
              "cost": 0.42,
              "pendingAskCount": 2
            }
          ],
          "stopped": [
            {
              "id": "session-stopped",
              "workspaceId": "ws-1",
              "workspaceName": "Oppi",
              "name": "Stopped Chat",
              "status": "stopped",
              "createdAt": 1760000000000,
              "lastActivity": 1760000001000,
              "messageCount": 8,
              "tokens": { "input": 10, "output": 20 },
              "cost": 0.12
            },
            {
              "source": "tui",
              "path": "/tmp/pi-session.jsonl",
              "piSessionId": "pi-1",
              "cwd": "/Users/chenda/workspace/oppi",
              "name": "Import me",
              "firstMessage": "hello",
              "model": "anthropic/claude-sonnet-4-5",
              "messageCount": 3,
              "createdAt": 1760000000000,
              "lastModified": 1760000002500
            }
          ]
        }
        """#.data(using: .utf8).unwrap()

        let list = try MacWorkspaceClient.decodeWorkspaceSessionList(data)

        #expect(list.workspaceId == "ws-1")
        #expect(list.serverNow == 1760000003000)
        #expect(list.active.map(\.id) == ["session-active"])
        #expect(list.active.first?.pendingAskCount == 2)
        #expect(list.stopped.map(\.id) == ["session-stopped"])
        #expect(list.importableSessions.map(\.piSessionId) == ["pi-1"])
        #expect(list.allSummaries.map(\.id) == ["session-active", "session-stopped"])
    }

    @Test func decodesCreateWorkspaceSessionResponse() throws {
        let data = try #"""
        {
          "session": {
            "id": "session-new",
            "workspaceId": "ws-1",
            "name": "New Chat",
            "status": "busy",
            "createdAt": 1760000000000,
            "lastActivity": 1760000002000,
            "messageCount": 1,
            "tokens": { "input": 0, "output": 0 },
            "cost": 0,
            "firstMessage": "Build the Mac view"
          },
          "prompted": true
        }
        """#.data(using: .utf8).unwrap()

        let response = try JSONDecoder().decode(MacWorkspaceClient.CreateSessionResponse.self, from: data)

        #expect(response.session.id == "session-new")
        #expect(response.session.workspaceId == "ws-1")
        #expect(response.prompted == true)
    }

    @Test func decodesStopWorkspaceSessionResponse() throws {
        let data = try #"""
        {
          "ok": true,
          "session": {
            "id": "session-stopped",
            "workspaceId": "ws-1",
            "name": "Stopped Chat",
            "status": "stopped",
            "createdAt": 1760000000000,
            "lastActivity": 1760000002000,
            "messageCount": 1,
            "tokens": { "input": 0, "output": 0 },
            "cost": 0
          }
        }
        """#.data(using: .utf8).unwrap()

        let response = try JSONDecoder().decode(MacWorkspaceClient.StopSessionResponse.self, from: data)

        #expect(response.session?.id == "session-stopped")
        #expect(response.session?.status == .stopped)
    }

    @Test func decodesStopWorkspaceSessionResponseWithoutSession() throws {
        let data = try #"""
        { "ok": true, "session": null }
        """#.data(using: .utf8).unwrap()

        let response = try JSONDecoder().decode(MacWorkspaceClient.StopSessionResponse.self, from: data)

        #expect(response.session == nil)
    }

    @Test func decodesSessionTracePage() throws {
        let data = try #"""
        {
          "session": {
            "id": "session-active",
            "workspaceId": "ws-1",
            "name": "Active Chat",
            "status": "ready",
            "createdAt": 1760000000000,
            "lastActivity": 1760000002000,
            "messageCount": 1,
            "tokens": { "input": 100, "output": 50 },
            "cost": 0.42,
            "firstMessage": "Hello"
          },
          "trace": [
            {
              "id": "event-1",
              "type": "user",
              "timestamp": "2026-06-28T20:00:00Z",
              "text": "Hello"
            }
          ],
          "page": {
            "hasOlder": false,
            "olderCursor": null,
            "traceVersion": "v1",
            "previewBytes": 8192,
            "staleCursor": false
          }
        }
        """#.data(using: .utf8).unwrap()

        let page = try JSONDecoder().decode(MacWorkspaceClient.SessionTracePage.self, from: data)

        #expect(page.session.id == "session-active")
        #expect(page.trace.map(\.id) == ["event-1"])
        #expect(page.page.hasOlder == false)
    }
}

private extension Optional where Wrapped == Data {
    func unwrap() throws -> Data {
        guard let self else { throw TestDataError.invalidUTF8 }
        return self
    }
}

private enum TestDataError: Error {
    case invalidUTF8
}
