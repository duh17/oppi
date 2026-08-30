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

    @Test func controlSessionAttachmentCreateAndContentUseControlRouteFamily() async throws {
        let createTransport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"uploadId":"upload-1","contentUrl":"/control-sessions/control-1/attachments/upload-1/content","maxFileBytes":10485760,"expiresAt":1760000000000}"#.utf8)
            )
        )
        let createClient = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: createTransport
        )

        _ = try await createClient.createSessionAttachmentUpload(
            scope: .control,
            sessionId: "control-1",
            name: "note.txt",
            mimeType: "text/plain",
            sizeBytes: 5
        )

        let createRequest = try #require(await createTransport.requests.first)
        #expect(createRequest.method == "POST")
        #expect(createRequest.path == "/control-sessions/control-1/attachments")
        #expect(createRequest.headers["Authorization"] == "Bearer sk_owner")

        let contentTransport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"attachment":{"type":"chat_attachment","id":"upload-1","source":"upload","name":"note.txt","mimeType":"text/plain","sizeBytes":5,"sha256":"abc123","kind":"text","workspacePath":".pi/attachments/control-1/turn/note.txt"}}"#.utf8)
            )
        )
        let contentClient = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: contentTransport
        )

        _ = try await contentClient.uploadSessionAttachmentContent(
            scope: .control,
            sessionId: "control-1",
            attachmentId: "upload-1",
            data: Data("hello".utf8),
            contentType: "text/plain"
        )

        let contentRequest = try #require(await contentTransport.requests.first)
        #expect(contentRequest.method == "PUT")
        #expect(contentRequest.path == "/control-sessions/control-1/attachments/upload-1/content")
        #expect(contentRequest.headers["Authorization"] == "Bearer sk_owner")
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

    @Test func decodesRecentSessionSummaries() throws {
        let data = try #"""
        {
          "sessions": [
            {
              "id": "s2",
              "workspaceId": "w2",
              "status": "busy",
              "createdAt": 0,
              "lastActivity": 2000,
              "currentTurnStartedAt": 1500,
              "messageCount": 5,
              "tokens": { "input": 100, "output": 50 },
              "cost": 0.01,
              "pendingAskCount": 1
            },
            {
              "id": "s1",
              "workspaceId": "w1",
              "status": "ready",
              "createdAt": 0,
              "lastActivity": 1000,
              "messageCount": 0,
              "tokens": { "input": 0, "output": 0 },
              "cost": 0
            }
          ]
        }
        """#.data(using: .utf8).unwrap()

        let summaries = try MacWorkspaceClient.decodeRecentSessions(data)

        #expect(summaries.map(\.id) == ["s2", "s1"])
        #expect(summaries[0].workspaceId == "w2")
        #expect(summaries[0].status == .busy)
        #expect(summaries[0].pendingAskCount == 1)
        #expect(summaries[1].workspaceId == "w1")
        #expect(summaries[1].pendingAskCount == 0)
    }

    @Test func getSessionRecordUsesOwnerUnixSocketWithoutHTTPSFallback() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"session":{"id":"session-old","workspaceId":"ws-1","status":"stopped","createdAt":0,"lastActivity":0,"messageCount":2,"tokens":{"input":0,"output":0},"cost":0}}"#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        let session = try await client.getSessionRecord(sessionId: "session-old")

        #expect(session.id == "session-old")
        #expect(session.status == .stopped)
        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/sessions/session-old")
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
        #expect(!request.path.contains("https"))
        #expect(!request.path.contains("sk_"))
        #expect(await transport.requests.count == 1)
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
        #expect(list.hasVisibleSessions)
        #expect(MacWorkspaceLocalSessionPresentation.showsList(list))
    }

    @Test func importableOnlyWorkspaceSessionListIsVisible() throws {
        let list = MacWorkspaceClient.WorkspaceSessionList(
            workspaceId: "ws-1",
            serverNow: 1_760_000_003_000,
            active: [],
            stopped: [],
            importableSessions: [
                LocalSession(
                    path: "/tmp/pi-session.jsonl",
                    piSessionId: "pi-1",
                    cwd: "/tmp",
                    name: "Import me",
                    firstMessage: "hello",
                    model: "anthropic/claude-sonnet-4-5",
                    messageCount: 3,
                    createdAt: Date(timeIntervalSince1970: 1_760_000_000),
                    lastModified: Date(timeIntervalSince1970: 1_760_000_002.5)
                )
            ]
        )

        #expect(list.allSummaries.isEmpty)
        #expect(list.hasVisibleSessions)
        #expect(MacWorkspaceLocalSessionPresentation.showsList(list))
        #expect(
            MacWorkspaceLocalSessionPresentation.accessibilityIdentifier(for: list.importableSessions[0])
                == "localSession.nav.pi-1"
        )
    }

    @Test func createWorkspaceSessionFromLocalPostsPiSessionFileOnOwnerSocket() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"""
                {"session":{"id":"session-imported","workspaceId":"ws-1","name":"Import me","status":"busy","createdAt":1760000000000,"lastActivity":1760000002000,"messageCount":3,"tokens":{"input":0,"output":0},"cost":0},"prompted":false}
                """#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        let response = try await client.createWorkspaceSessionFromLocal(
            workspaceId: "ws-1",
            piSessionFile: "/tmp/pi-session.jsonl"
        )

        #expect(response.session.id == "session-imported")
        #expect(response.session.workspaceId == "ws-1")
        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/workspaces/ws-1/sessions")
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
        #expect(!request.path.contains("https"))
        #expect(!request.path.contains("sk_"))
        let body = try JSONDecoder().decode(
            ImportLocalSessionBody.self,
            from: try #require(request.body)
        )
        #expect(body.piSessionFile == "/tmp/pi-session.jsonl")
        #expect(body.worktreeId == nil)
        #expect(await client.socketPath == "/tmp/oppi-test.sock")
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

    @Test func getWorkspaceSessionTracePageUsesOwnerUnixSocketNotHTTPS() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"session":{"id":"sess-1","workspaceId":"ws-1","status":"ready","createdAt":0,"lastActivity":0,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0},"trace":[],"page":{"hasOlder":false,"olderCursor":null,"traceVersion":"v1","previewBytes":4096,"staleCursor":false}}"#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        _ = try await client.getWorkspaceSessionTracePage(
            workspaceId: "ws-1",
            sessionId: "sess-1",
            previewBytes: 4_096,
            cursor: "older-1",
            aroundEntryId: "event-1"
        )

        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path.hasPrefix("/workspaces/ws-1/sessions/sess-1/trace-page?"))
        #expect(request.path.contains("cursor=older-1"))
        #expect(request.path.contains("aroundEntryId=event-1"))
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
        #expect(!request.path.contains("https"))
        #expect(!request.path.contains("sk_"))
        #expect(await client.socketPath == "/tmp/oppi-test.sock")
    }

    @Test func getWorkspaceSessionEventsUsesOwnerUnixSocketNotHTTPS() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"events":[{"seq":13,"type":"agent_start"}],"currentSeq":13,"catchUpComplete":true,"session":{"id":"sess-1","workspaceId":"ws-1","status":"ready","createdAt":0,"lastActivity":0,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}}"#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        let catchUp = try await client.getWorkspaceSessionEvents(
            workspaceId: "ws-1",
            sessionId: "sess-1",
            since: 12
        )

        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/workspaces/ws-1/sessions/sess-1/events?since=12")
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
        #expect(!request.path.contains("https"))
        #expect(!request.path.contains("wss"))
        #expect(catchUp.currentSeq == 13)
        #expect(catchUp.events.map(\.seq) == [13])
        #expect(await client.socketPath == "/tmp/oppi-test.sock")
    }

    @Test func controlSessionTraceAndEventsUseControlRouteFamily() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"session":{"id":"control-1","status":"ready","createdAt":0,"lastActivity":0,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0,"control":{"domain":"agents","intent":"create"}},"trace":[],"page":{"hasOlder":false,"olderCursor":null,"traceVersion":"v1","previewBytes":4096,"staleCursor":false},"events":[],"currentSeq":0,"catchUpComplete":true}"#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        _ = try await client.getSessionTracePage(
            scope: .control,
            sessionId: "control-1",
            previewBytes: 4_096
        )
        _ = try await client.getSessionEvents(
            scope: .control,
            sessionId: "control-1",
            since: 9
        )

        let requests = await transport.requests
        #expect(requests.map(\.method) == ["GET", "GET"])
        #expect(requests[0].path.hasPrefix("/control-sessions/control-1/trace-page?"))
        #expect(requests[1].path == "/control-sessions/control-1/events?since=9")
        #expect(requests.allSatisfy { !$0.path.contains("/workspaces/") })
        #expect(requests.allSatisfy { $0.headers["Authorization"] == "Bearer sk_owner" })
    }

    @Test func decodeSessionCatchUpReadsSequencedEvents() throws {
        let data = try #"""
        {
          "events": [
            { "seq": 13, "type": "agent_start" }
          ],
          "currentSeq": 13,
          "runtimeEpoch": "epoch-1",
          "catchUpComplete": true,
          "session": {
            "id": "sess-1",
            "workspaceId": "ws-1",
            "status": "ready",
            "createdAt": 1760000000000,
            "lastActivity": 1760000002000,
            "messageCount": 1,
            "tokens": { "input": 1, "output": 1 },
            "cost": 0
          }
        }
        """#.data(using: .utf8).unwrap()

        let catchUp = try MacWorkspaceClient.decodeSessionCatchUp(data)

        #expect(catchUp.currentSeq == 13)
        #expect(catchUp.runtimeEpoch == "epoch-1")
        #expect(catchUp.catchUpComplete)
        #expect(catchUp.events.map(\.seq) == [13])
        #expect(catchUp.session.id == "sess-1")
    }

    @Test func getFullToolOutputUsesOwnerSocketQuery() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"output":"full bash log\nline 2"}"#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        let output = try await client.getFullToolOutput(
            workspaceId: "ws-1",
            sessionId: "session-1",
            toolCallId: "tool-1"
        )

        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/workspaces/ws-1/sessions/session-1/tool-output/tool-1?full=true")
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
        #expect(output == "full bash log\nline 2")
        #expect(await transport.requests.count == 1)
    }

    @Test func getFullToolOutputUsesControlRouteFamilyWhenScopedToControl() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"output":"full control-session output"}"#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        let output = try await client.getFullToolOutput(
            scope: .control,
            sessionId: "control-1",
            toolCallId: "tool-1"
        )

        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/control-sessions/control-1/tool-output/tool-1?full=true")
        #expect(request.headers["Authorization"] == "Bearer sk_owner")
        #expect(output == "full control-session output")
    }

    @Test func getFullToolOutputReturnsNilOn404() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 404,
                headers: ["content-type": "application/json"],
                body: Data(#"{"error":"not found"}"#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        let output = try await client.getFullToolOutput(
            workspaceId: "ws-1",
            sessionId: "session-1",
            toolCallId: "missing-tool"
        )

        #expect(output == nil)
        let request = try #require(await transport.requests.first)
        #expect(request.path == "/workspaces/ws-1/sessions/session-1/tool-output/missing-tool?full=true")
    }

    @Test func decodeFullToolOutputReadsOutputField() throws {
        let data = try #"{"output":"complete tool text"}"#.data(using: .utf8).unwrap()
        #expect(try MacWorkspaceClient.decodeFullToolOutput(data) == "complete tool text")
    }

    @Test func listWorkspaceDirectoryAppendsWorktreeQueryAfterSwitch() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"path":"/","truncated":false,"entries":[]}"#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        _ = try await client.listWorkspaceDirectory(
            workspaceId: "ws-1",
            path: "",
            worktreeId: WorkspaceWorktree.mainId
        )
        _ = try await client.listWorkspaceDirectory(
            workspaceId: "ws-1",
            path: "Sources/",
            worktreeId: "wt_feature"
        )

        let requests = await transport.requests
        #expect(requests.map(\.method) == ["GET", "GET"])
        #expect(requests[0].path.hasPrefix("/workspaces/ws-1/contents/"))
        #expect(requests[1].path.hasPrefix("/workspaces/ws-1/contents/Sources/"))
        #expect(queryValue("worktreeId", in: requests[0].path) == WorkspaceWorktree.mainId)
        #expect(queryValue("worktreeId", in: requests[1].path) == "wt_feature")
        #expect(requests[0].headers["Authorization"] == "Bearer sk_owner")
        #expect(!requests[1].path.contains("https"))
    }

    @Test func getWorkspaceRawFileDataAppendsWorktreeQueryAfterSwitch() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/plain"],
                body: Data("feature-bytes".utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        let main = try await client.getWorkspaceRawFileData(
            workspaceId: "ws-1",
            path: "Notes.md",
            worktreeId: WorkspaceWorktree.mainId
        )
        let feature = try await client.getWorkspaceRawFileData(
            workspaceId: "ws-1",
            path: "clips/demo.mp4",
            worktreeId: "wt_feature"
        )

        let requests = await transport.requests
        #expect(main == Data("feature-bytes".utf8))
        #expect(feature == Data("feature-bytes".utf8))
        #expect(requests.map(\.method) == ["GET", "GET"])
        #expect(requests[0].path == "/workspaces/ws-1/raw/Notes.md")
        #expect(queryValue("worktreeId", in: requests[0].path) == nil)
        #expect(requests[1].path.hasPrefix("/workspaces/ws-1/raw/clips/demo.mp4"))
        #expect(queryValue("worktreeId", in: requests[1].path) == "wt_feature")
        #expect(requests[1].headers["Authorization"] == "Bearer sk_owner")
        #expect(!requests[1].path.contains("https"))
    }

    @Test func getWorkspaceRawFileDataOmitsWorktreeQueryWhenUnscoped() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "text/plain"],
                body: Data("main-bytes".utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        _ = try await client.getWorkspaceRawFileData(workspaceId: "ws-1", path: "Notes.md")

        let request = try #require(await transport.requests.first)
        #expect(request.path == "/workspaces/ws-1/raw/Notes.md")
        #expect(queryValue("worktreeId", in: request.path) == nil)
    }

    @Test func listWorkspaceDirectoryOmitsWorktreeQueryWhenUnscoped() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data(#"{"path":"/","truncated":false,"entries":[]}"#.utf8)
            )
        )
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-test.sock",
            token: "sk_owner",
            transport: transport
        )

        _ = try await client.listWorkspaceDirectory(workspaceId: "ws-1", path: "")

        let request = try #require(await transport.requests.first)
        #expect(request.path == "/workspaces/ws-1/contents/")
        #expect(queryValue("worktreeId", in: request.path) == nil)
    }

    private func queryValue(_ name: String, in path: String) -> String? {
        guard let query = path.split(separator: "?", maxSplits: 1).dropFirst().first else {
            return nil
        }
        return URLComponents(string: "http://local?\(query)")?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
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

private struct ImportLocalSessionBody: Decodable {
    let piSessionFile: String
    let worktreeId: String?
}
