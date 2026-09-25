import Foundation
import Testing
@testable import Oppi

@Suite("MacCurrentFileRequest")
struct MacCurrentFileRequestTests {
    @Test func unifiedRoutePerOrigin() throws {
        let host = try #require(MacCurrentFileRequest(origin: .host, path: "/work/a+b & c.wav"))
        let workspace = try #require(MacCurrentFileRequest(
            origin: .workspace(workspaceID: "ws 1", worktreeId: "branch+one"),
            path: "clips/demo.mp4"
        ))
        let main = try #require(MacCurrentFileRequest(
            origin: .workspace(workspaceID: "ws-1", worktreeId: WorkspaceWorktree.mainId),
            path: "Notes.md"
        ))
        let sandbox = try #require(MacCurrentFileRequest(
            origin: .session(workspaceID: "sandbox", sessionID: "s-1"),
            path: "/work/clip.wav"
        ))

        #expect(host.requestTarget() == "/files/current?origin=host&path=%2Fwork%2Fa%2Bb%20%26%20c.wav")
        #expect(
            workspace.requestTarget()
                == "/files/current?origin=workspace&workspaceId=ws%201&worktreeId=branch%2Bone&path=clips%2Fdemo.mp4"
        )
        #expect(main.requestTarget() == "/files/current?origin=workspace&workspaceId=ws-1&path=Notes.md")
        #expect(
            sandbox.requestTarget()
                == "/files/current?origin=session&sessionId=s-1&path=%2Fwork%2Fclip.wav"
        )
        #expect(MacCurrentFileRequest(origin: .host, path: "") == nil)
    }

    @Test func clientReadsUnifiedRouteWithoutServerInfoProbe() async throws {
        let transport = CurrentFilesServerTransport()
        let client = MacWorkspaceClient(
            socketPath: "/tmp/oppi-current-files.sock",
            token: "sk_owner",
            transport: transport
        )

        let workspace = try await client.getCurrentFileData(try #require(MacCurrentFileRequest(
            origin: .workspace(workspaceID: "ws-1", worktreeId: "wt_feature"),
            path: "Notes.md"
        )))
        _ = try await client.getCurrentFileData(try #require(MacCurrentFileRequest(
            origin: .session(workspaceID: "ws-1", sessionID: "sess-1"),
            path: "out/report.md"
        )))
        _ = try await client.getCurrentFileData(try #require(MacCurrentFileRequest(origin: .host, path: "~/notes.md")))

        let requests = await transport.requests
        #expect(workspace == CurrentFilesServerTransport.fileBody)
        #expect(requests.map(\.path) == [
            "/files/current?origin=workspace&workspaceId=ws-1&worktreeId=wt_feature&path=Notes.md",
            "/files/current?origin=session&sessionId=sess-1&path=out%2Freport.md",
            "/files/current?origin=host&path=~%2Fnotes.md",
        ])
        #expect(requests.allSatisfy { $0.method == "GET" && $0.headers["Authorization"] == "Bearer sk_owner" })
        #expect(requests.allSatisfy { !$0.path.contains("sk_") })
        #expect(requests.allSatisfy { !$0.path.contains("/server/info") })
    }

    @Test func mediaRangeFetchUsesCurrentFileRoute() async throws {
        let request = try #require(MacCurrentFileRequest(
            origin: .workspace(workspaceID: "ws-1", worktreeId: "wt_feature"),
            path: "clips/demo.mp4"
        ))
        let expected =
            "/files/current?origin=workspace&workspaceId=ws-1&worktreeId=wt_feature&path=clips%2Fdemo.mp4"
        let transport = CurrentFilesServerTransport()
        let source = MacOwnerMediaSource.make(
            target: .currentFile(request),
            socketPath: "/tmp/oppi-media.sock",
            token: "sk_owner",
            contentTypeHint: "video/mp4",
            sourceFileExtension: "mp4"
        )

        for start in [Int64(0), 4] {
            _ = try await MacUnixSocketRangeClient.fetch(
                source: source,
                range: MacUnixSocketRequestedRange(start: start, end: start + 3),
                transport: transport
            )
        }

        let requests = await transport.requests
        #expect(requests.map(\.path) == [expected, expected])
        #expect(requests.map { $0.headers["Range"] } == ["bytes=0-3", "bytes=4-7"])
        #expect(requests.allSatisfy { $0.headers["Authorization"] == "Bearer sk_owner" })
    }
}

/// Owner-socket fake: file reads return bytes. No `/server/info` probe.
actor CurrentFilesServerTransport: MacLocalHTTPPerforming {
    static let fileBody = Data("0123456789abcdef".utf8)

    private(set) var requests: [MacLocalHTTPRequest] = []

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        requests.append(request)
        guard let range = request.headers["Range"] else {
            return MacLocalHTTPResponse(statusCode: 200, headers: [:], body: Self.fileBody)
        }
        return MarkdownAudioRangeReply.response(body: Self.fileBody, contentType: "video/mp4", rangeHeader: range)
    }
}
