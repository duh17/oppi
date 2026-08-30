import Foundation
import Testing
@testable import Oppi

@Suite("Mac Unix-socket AV range adapter")
struct MacUnixSocketRangeAdapterTests {
    @Test func rangeCapsRestOfFileRequestToOneMegabyteChunk() {
        let range = MacUnixSocketRequestedRange.make(
            offset: 4_096,
            requestedLength: Int.max,
            requestsAllDataToEndOfResource: true
        )
        #expect(range.headerValue == "bytes=4096-1052671")
        #expect(range.start == 4_096)
        #expect(range.end == 1_052_671)
        #expect(range.continuesToEnd)
    }

    @Test func rangeKeepsClosedHeaderForBoundedRequest() {
        let range = MacUnixSocketRequestedRange.make(
            offset: 1_024,
            requestedLength: 1_024,
            requestsAllDataToEndOfResource: false
        )
        #expect(range.headerValue == "bytes=1024-2047")
        #expect(range.continuesToEnd == false)
    }

    @Test func rangeCapsHugeLengthWithoutAllDataFlag() {
        let range = MacUnixSocketRequestedRange.make(
            offset: 0,
            requestedLength: Int.max,
            requestsAllDataToEndOfResource: false
        )
        #expect(range.headerValue == "bytes=0-1048575")
        #expect(range.continuesToEnd)
    }

    @Test func rangeDoesNotStreamBoundedRequestPastRequestedLength() {
        let range = MacUnixSocketRequestedRange.make(
            offset: 0,
            requestedLength: 2_097_152,
            requestsAllDataToEndOfResource: false
        )
        #expect(range.headerValue == "bytes=0-1048575")
        #expect(range.continuesToEnd == false)
    }

    @Test func rangeContinuationStopsAtKnownTotal() {
        #expect(
            MacUnixSocketRangeContinuation.nextOffset(
                afterEnd: 1_048_575,
                totalLength: 1_048_576
            ) == nil
        )
        #expect(
            MacUnixSocketRangeContinuation.nextOffset(
                afterEnd: 1_048_575,
                totalLength: 2_097_152
            ) == 1_048_576
        )
    }

    @Test func responseValidatorAcceptsMatchingPartialContent() {
        let range = MacUnixSocketRequestedRange(start: 1_024, end: 2_047)
        let error = MacUnixSocketMediaResponseValidator.errorMessage(
            statusCode: 206,
            requestedRange: range,
            contentRange: "bytes 1024-2047/4096"
        )
        #expect(error == nil)
    }

    @Test func responseValidatorRejectsRangeRequestWithFullResponse() {
        let range = MacUnixSocketRequestedRange(start: 1_024, end: 2_047)
        let error = MacUnixSocketMediaResponseValidator.errorMessage(
            statusCode: 200,
            requestedRange: range,
            contentRange: nil
        )
        #expect(error != nil)
    }

    @Test func responseValidatorRejectsMismatchedContentRange() {
        let range = MacUnixSocketRequestedRange(start: 1_024, end: 2_047)
        let error = MacUnixSocketMediaResponseValidator.errorMessage(
            statusCode: 206,
            requestedRange: range,
            contentRange: "bytes 0-1023/4096"
        )
        #expect(error != nil)
    }

    @Test func encodedRangeRequestPutsBearerOnUnixSocketHTTPNotTCP() {
        let range = MacUnixSocketRequestedRange(start: 0, end: 1_048_575)
        let request = MacUnixSocketMediaRequest.make(
            method: "GET",
            path: "/workspaces/ws/raw/clip.mp4",
            authorization: "Bearer sk_secret",
            range: range
        )
        let encoded = String(data: MacLocalHTTPCodec.encode(request), encoding: .utf8) ?? ""

        #expect(encoded.hasPrefix("GET /workspaces/ws/raw/clip.mp4 HTTP/1.1\r\n"))
        #expect(encoded.contains("Authorization: Bearer sk_secret"))
        #expect(encoded.contains("Range: bytes=0-1048575"))
        #expect(encoded.contains("Host: localhost"))
        #expect(!encoded.contains("https://"))
        #expect(!encoded.contains("127.0.0.1"))
        #expect(!encoded.contains("7749"))
        #expect(!request.path.contains("sk_"))
    }

    @Test func ownerSourceIdentityAndAssetURLNeverCarryOwnerToken() {
        let source = MacOwnerMediaSource.make(
            requestPath: "/workspaces/ws/raw/clip.mp4",
            socketPath: "/tmp/oppi.sock",
            token: "sk_secret",
            contentTypeHint: "video/mp4",
            sourceFileExtension: "mp4"
        )
        let assetURL = MacAuthenticatedMediaPlaybackSession.makeAssetURL()

        #expect(source.requestPath == "/workspaces/ws/raw/clip.mp4")
        #expect(source.socketPath == "/tmp/oppi.sock")
        #expect(!source.identity.contains("sk_"))
        #expect(!source.requestPath.contains("sk_"))
        #expect(!source.socketPath.contains("sk_"))
        #expect(assetURL.scheme == "oppi-media")
        #expect(assetURL.host == "owner-socket")
        #expect(!assetURL.absoluteString.contains("sk_"))
        #expect(!assetURL.absoluteString.contains("127.0.0.1"))
        #expect(!assetURL.absoluteString.contains("http"))
    }

    @Test func mediaPathsEncodeWorkspaceSessionAndAttachmentRoutes() throws {
        let workspace = try #require(
            MacUnixSocketMediaPath.workspaceRaw(workspaceID: "ws 1", filePath: "clips/demo.mp4")
        )
        let session = try #require(
            MacUnixSocketMediaPath.sessionRaw(
                workspaceID: "ws-1",
                sessionID: "sess-1",
                filePath: "out/demo.mp4"
            )
        )
        let attachment = try #require(
            MacUnixSocketMediaPath.sessionAttachment(sessionID: "sess-1", attachmentID: "att-9")
        )
        let controlAttachment = try #require(
            MacUnixSocketMediaPath.sessionAttachment(
                sessionID: "sess-1",
                attachmentID: "att-9",
                scope: .control
            )
        )

        #expect(workspace == "/workspaces/ws%201/raw/clips/demo.mp4")
        #expect(session == "/workspaces/ws-1/sessions/sess-1/raw/out/demo.mp4")
        #expect(attachment == "/sessions/sess-1/attachments/att-9")
        #expect(controlAttachment == "/control-sessions/sess-1/attachments/att-9")
        #expect(
            MacUnixSocketMediaPath.workspaceRaw(
                workspaceID: "ws-1",
                filePath: "clips/demo.mp4",
                worktreeId: "wt_feature"
            ) == "/workspaces/ws-1/raw/clips/demo.mp4?worktreeId=wt_feature"
        )
        #expect(
            MacUnixSocketMediaPath.workspaceRaw(
                workspaceID: "ws-1",
                filePath: "clips/demo.mp4",
                worktreeId: WorkspaceWorktree.mainId
            ) == "/workspaces/ws-1/raw/clips/demo.mp4"
        )
        #expect(!workspace.contains("sk_"))
        #expect(!session.contains("sk_"))
        #expect(!attachment.contains("sk_"))
    }

    @Test func rangeFetchUsesOwnerSocketRequestNotLoopbackHTTP() async throws {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 206,
                headers: [
                    "content-type": "video/mp4",
                    "content-range": "bytes 0-3/16",
                    "content-length": "4",
                ],
                body: Data([0, 1, 2, 3])
            )
        )
        let source = MacOwnerMediaSource.make(
            requestPath: "/workspaces/ws/raw/clip.mp4",
            socketPath: "/tmp/oppi.sock",
            token: "sk_secret",
            contentTypeHint: "video/mp4",
            sourceFileExtension: "mp4"
        )
        let chunk = try await MacUnixSocketRangeClient.fetch(
            source: source,
            range: MacUnixSocketRequestedRange(start: 0, end: 3),
            transport: transport
        )
        let request = try #require(await transport.requests.first)

        #expect(request.method == "GET")
        #expect(request.path == "/workspaces/ws/raw/clip.mp4")
        #expect(request.headers["Authorization"] == "Bearer sk_secret")
        #expect(request.headers["Range"] == "bytes=0-3")
        #expect(!request.path.contains("sk_"))
        #expect(!request.path.contains("http"))
        #expect(chunk.body == Data([0, 1, 2, 3]))
        #expect(chunk.totalLength == 16)
        #expect(chunk.deliveredEnd == 3)
    }

    @Test func rangeFetchRejectsHTTP200ForRangedRequest() async {
        let transport = RecordingLocalHTTPTransport(
            response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "video/mp4"],
                body: Data([0, 1, 2, 3])
            )
        )
        let source = MacOwnerMediaSource.make(
            requestPath: "/workspaces/ws/raw/clip.mp4",
            socketPath: "/tmp/oppi.sock",
            token: "sk_secret",
            contentTypeHint: "video/mp4",
            sourceFileExtension: "mp4"
        )

        await #expect(throws: MacUnixSocketMediaError.self) {
            _ = try await MacUnixSocketRangeClient.fetch(
                source: source,
                range: MacUnixSocketRequestedRange(start: 0, end: 3),
                transport: transport
            )
        }
    }

    @Test func playbackURLPolicyRejectsOwnerTokenOnTCP() throws {
        let loopback = try #require(URL(string: "http://127.0.0.1:7749/workspaces/ws/raw/clip.mp4?token=sk_secret"))
        let https = try #require(URL(string: "https://cdn.example.com/clip.mp4"))
        let file = URL(fileURLWithPath: "/tmp/clip.mp4")
        let custom = try #require(URL(string: "oppi-media://owner-socket/abc"))

        #expect(!MacAVPlaybackURLPolicy.allows(loopback))
        #expect(MacAVPlaybackURLPolicy.allows(https))
        #expect(MacAVPlaybackURLPolicy.allows(file))
        #expect(MacAVPlaybackURLPolicy.allows(custom))
    }

    @Test func wikiVideoUsesOwnerSocketNotTemporaryFile() throws {
        let embed = MarkdownVideoEmbed(
            reference: ResourceReference(
                target: "demo.mp4",
                sourceServerID: nil,
                workspaceID: "ws-mac",
                sourceSessionID: "sess-mac",
                fileCandidatePath: "clips/demo.mp4",
                kind: .workspaceFile
            )
        )
        let playback = MacMarkdownVideoView.playback(
            for: embed,
            ownerToken: "sk_secret",
            socketPath: "/tmp/oppi.sock"
        )

        guard case .ownerSocket(let source) = playback else {
            Issue.record("Expected owner-socket playback, got \(playback)")
            return
        }
        #expect(source.requestPath == "/workspaces/ws-mac/sessions/sess-mac/raw/clips/demo.mp4")
        #expect(source.socketPath == "/tmp/oppi.sock")
        #expect(source.contentTypeHint == "video/mp4")
        #expect(!source.identity.contains("sk_"))
        #expect(!source.requestPath.contains("sk_"))
    }

    @Test func markdownWorkspaceVideoPlaybackSendsWorktreeQueryOnRawRangePath() throws {
        let embed = MarkdownVideoEmbed(
            reference: ResourceReference(
                target: "demo.mp4",
                sourceServerID: nil,
                workspaceID: "ws-1",
                sourceSessionID: nil,
                fileCandidatePath: "clips/demo.mp4",
                kind: .workspaceFile
            )
        )
        let feature = MacMarkdownVideoView.playback(
            for: embed,
            worktreeId: "wt_feature",
            ownerToken: "sk_secret",
            socketPath: "/tmp/oppi.sock"
        )
        let main = MacMarkdownVideoView.playback(
            for: embed,
            worktreeId: WorkspaceWorktree.mainId,
            ownerToken: "sk_secret",
            socketPath: "/tmp/oppi.sock"
        )

        guard case .ownerSocket(let featureSource) = feature else {
            Issue.record("Expected owner-socket playback, got \(feature)")
            return
        }
        guard case .ownerSocket(let mainSource) = main else {
            Issue.record("Expected main-checkout playback, got \(main)")
            return
        }
        #expect(featureSource.requestPath == "/workspaces/ws-1/raw/clips/demo.mp4?worktreeId=wt_feature")
        #expect(mainSource.requestPath == "/workspaces/ws-1/raw/clips/demo.mp4")
        #expect(!featureSource.requestPath.contains("sk_"))
    }

    @Test func workspaceFileAudioAndVideoPlayThroughOwnerSocket() throws {
        let video = try #require(
            MacToolDocumentMediaPlayback.playback(
                media: ToolContentDescriptor.Media(
                    output: "",
                    filePath: "clips/demo.mp4",
                    startLine: 1,
                    attachments: [],
                    audio: nil
                ),
                workspaceID: "ws-1",
                sessionID: nil,
                ownerToken: "sk_secret",
                socketPath: "/tmp/oppi.sock"
            )
        )
        let audio = try #require(
            MacToolDocumentMediaPlayback.playback(
                media: ToolContentDescriptor.Media(
                    output: "Voice message",
                    filePath: nil,
                    startLine: 1,
                    attachments: [],
                    audio: ToolContentDescriptor.AudioMessage(
                        text: "Voice message",
                        attachmentId: "att-1",
                        mimeType: "audio/wav",
                        durationSeconds: 1.5,
                        playbackBehavior: nil,
                        base64: nil
                    )
                ),
                workspaceID: "ws-1",
                sessionID: "sess-1",
                ownerToken: "sk_secret",
                socketPath: "/tmp/oppi.sock"
            )
        )
        let controlAudio = try #require(
            MacToolDocumentMediaPlayback.playback(
                media: ToolContentDescriptor.Media(
                    output: "Voice message",
                    filePath: nil,
                    startLine: 1,
                    attachments: [],
                    audio: ToolContentDescriptor.AudioMessage(
                        text: "Voice message",
                        attachmentId: "att-1",
                        mimeType: "audio/wav",
                        durationSeconds: 1.5,
                        playbackBehavior: nil,
                        base64: nil
                    )
                ),
                workspaceID: nil,
                sessionID: "control-1",
                routeScope: .control,
                ownerToken: "sk_secret",
                socketPath: "/tmp/oppi.sock"
            )
        )

        guard case .ownerSocket(let videoSource) = video else {
            Issue.record("Expected workspace video to use the Unix-socket adapter, got \(video)")
            return
        }
        guard case .ownerSocket(let audioSource) = audio else {
            Issue.record("Expected tool audio to use the Unix-socket adapter, got \(audio)")
            return
        }
        guard case .ownerSocket(let controlAudioSource) = controlAudio else {
            Issue.record("Expected control-session audio to use the Unix-socket adapter, got \(controlAudio)")
            return
        }
        #expect(videoSource.requestPath == "/workspaces/ws-1/raw/clips/demo.mp4")
        #expect(audioSource.requestPath == "/sessions/sess-1/attachments/att-1")
        #expect(controlAudioSource.requestPath == "/control-sessions/control-1/attachments/att-1")
        #expect(!videoSource.identity.contains("sk_"))
        #expect(!audioSource.identity.contains("sk_"))
        #expect(!controlAudioSource.identity.contains("sk_"))
        #expect(MacToolDocumentColumnPaint.surface(for: .media(
            ToolContentDescriptor.Media(
                output: "",
                filePath: "clips/demo.mp4",
                startLine: 1,
                attachments: [],
                audio: nil
            )
        )) == .media)
    }

    @Test func workspaceFileMediaPlaybackSendsWorktreeQueryOnRawRangePath() throws {
        let video = try #require(
            MacToolDocumentMediaPlayback.playback(
                media: ToolContentDescriptor.Media(
                    output: "",
                    filePath: "clips/demo.mp4",
                    startLine: 1,
                    attachments: [],
                    audio: nil
                ),
                workspaceID: "ws-1",
                sessionID: nil,
                worktreeId: "wt_feature",
                ownerToken: "sk_secret",
                socketPath: "/tmp/oppi.sock"
            )
        )
        let main = try #require(
            MacToolDocumentMediaPlayback.playback(
                media: ToolContentDescriptor.Media(
                    output: "",
                    filePath: "clips/demo.mp4",
                    startLine: 1,
                    attachments: [],
                    audio: nil
                ),
                workspaceID: "ws-1",
                sessionID: nil,
                worktreeId: WorkspaceWorktree.mainId,
                ownerToken: "sk_secret",
                socketPath: "/tmp/oppi.sock"
            )
        )

        guard case .ownerSocket(let featureSource) = video else {
            Issue.record("Expected workspace video to use the Unix-socket adapter, got \(video)")
            return
        }
        guard case .ownerSocket(let mainSource) = main else {
            Issue.record("Expected main-checkout video to use the Unix-socket adapter, got \(main)")
            return
        }
        #expect(featureSource.requestPath == "/workspaces/ws-1/raw/clips/demo.mp4?worktreeId=wt_feature")
        #expect(mainSource.requestPath == "/workspaces/ws-1/raw/clips/demo.mp4")
        #expect(!featureSource.requestPath.contains("sk_"))
    }

    @Test func markdownVideoViewDoesNotDownloadWorkspaceFilesToTemp() throws {
        let videoView = try source(named: "OppiMac/Views/MacMarkdownVideoView.swift")
        let media = try source(named: "OppiMac/Views/MacToolDocumentMedia.swift")

        #expect(videoView.contains("MacAuthenticatedAVPlayerView"))
        #expect(videoView.contains("ownerSocket"))
        #expect(!videoView.contains("temporaryFileURL"))
        #expect(!videoView.contains("AVPlayer(url:"))
        #expect(media.contains("MacAuthenticatedAVPlayerView"))
        #expect(media.contains("mac.documentColumn.mediaPlayer"))
        #expect(media.contains("suppressAutoplay"))
        #expect(!media.contains("autoplay:"))
        #expect(!media.contains("shouldAutoplay"))
        #expect(!media.contains("playWhenReady"))
        #expect(!media.contains("Audio preview is not available"))
        #expect(!media.contains("Video preview is not available"))
    }

    @Test func cancelAllCancelsInFlightUnixGET() async {
        let transport = GateableLocalHTTPTransport(mode: .hang)
        let adapter = makeRangeAdapter(transport: transport)
        adapter.debugStartFulfillment()
        defer { adapter.cancelAll() }

        #expect(await transport.waitUntilStarted())
        adapter.cancelAll()

        #expect(await transport.waitUntilCancelled())
        #expect(!adapter.debugDidCommit)
    }

    @Test func didCancelCancelsInFlightUnixGET() async {
        let transport = GateableLocalHTTPTransport(mode: .hang)
        let adapter = makeRangeAdapter(transport: transport)
        adapter.debugStartFulfillment()
        defer { adapter.cancelAll() }

        #expect(await transport.waitUntilStarted())
        adapter.debugDidCancelCurrent()

        #expect(await transport.waitUntilCancelled())
        #expect(!adapter.debugDidCommit)
    }

    @Test func fulfillDropsBytesWhenCancelledOnDelegateQueue() async {
        let transport = GateableLocalHTTPTransport(mode: .complete(partialContentResponse()))
        let adapter = makeRangeAdapter(transport: transport)
        adapter.debugBeforeCommit = { adapter.cancelAll() }
        adapter.debugStartFulfillment()
        defer { adapter.cancelAll() }

        #expect(await transport.waitUntilStarted())
        #expect(await waitUntil { adapter.debugCheckedCommit })
        #expect(!adapter.debugDidCommit)
    }

    @Test func fulfillCommitsBytesWhenNotCancelled() async {
        let transport = GateableLocalHTTPTransport(mode: .complete(partialContentResponse()))
        let adapter = makeRangeAdapter(transport: transport)
        adapter.debugStartFulfillment()
        defer { adapter.cancelAll() }

        #expect(await transport.waitUntilStarted())
        #expect(await waitUntil { adapter.debugDidCommit })
    }

    private func source(named relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeRangeAdapter(transport: GateableLocalHTTPTransport) -> MacUnixSocketRangeAdapter {
        MacUnixSocketRangeAdapter(
            source: MacOwnerMediaSource.make(
                requestPath: "/workspaces/ws/raw/clip.mp4",
                socketPath: "/tmp/oppi.sock",
                token: "sk_secret",
                contentTypeHint: "video/mp4",
                sourceFileExtension: "mp4"
            ),
            transport: transport
        )
    }

    private func partialContentResponse() -> MacLocalHTTPResponse {
        MacLocalHTTPResponse(
            statusCode: 206,
            headers: [
                "content-type": "video/mp4",
                "content-range": "bytes 0-3/16",
                "content-length": "4",
            ],
            body: Data([0, 1, 2, 3])
        )
    }
}

private actor GateableLocalHTTPTransport: MacLocalHTTPPerforming {
    enum Mode: Sendable {
        case hang
        case complete(MacLocalHTTPResponse)
    }

    private let mode: Mode
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelledWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = false
    private var cancelled = false

    init(mode: Mode) {
        self.mode = mode
    }

    func waitUntilStarted(timeout: Duration = .milliseconds(1_500)) async -> Bool {
        if started { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitForStartedFlag()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func waitForStartedFlag() async {
        if started { return }
        await withCheckedContinuation { continuation in
            if started {
                continuation.resume()
            } else {
                startedWaiters.append(continuation)
            }
        }
    }

    func waitUntilCancelled(timeout: Duration = .milliseconds(1_500)) async -> Bool {
        if cancelled { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitForCancelledFlag()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        started = true
        let waiters = startedWaiters
        startedWaiters = []
        waiters.forEach { $0.resume() }

        switch mode {
        case .complete(let response):
            return response
        case .hang:
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                markCancelled()
                throw CancellationError()
            }
            throw MacUnixSocketMediaError.http("hang transport timed out")
        }
    }

    private func waitForCancelledFlag() async {
        if cancelled { return }
        await withCheckedContinuation { continuation in
            if cancelled {
                continuation.resume()
            } else {
                cancelledWaiters.append(continuation)
            }
        }
    }

    private func markCancelled() {
        cancelled = true
        let waiters = cancelledWaiters
        cancelledWaiters = []
        waiters.forEach { $0.resume() }
    }
}

private func waitUntil(
    timeoutYields: Int = 400,
    _ predicate: () -> Bool
) async -> Bool {
    for _ in 0..<timeoutYields {
        if predicate() { return true }
        await Task.yield()
    }
    return predicate()
}
