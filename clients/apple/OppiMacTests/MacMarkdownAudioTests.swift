@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Oppi

@Suite @MainActor
struct MacMarkdownAudioTests {
    @Test func sessionWithoutWorkspaceCannotImplyHostAuthority() async {
        let input = request(path: "/work/clip.wav", kind: .hostFile, session: "s", workspace: nil)
        await #expect(throws: (any Error).self) {
            try await MacMarkdownAudioSource.resolve(input, token: "sk_fixture", socketPath: "/fixture.sock") { _ in
                Issue.record("Missing session context must be settled before workspace lookup")
                return nil
            }
        }
    }

    @Test func recoveredSessionContextDistinguishesControlFromSandbox() async throws {
        let input = request(path: "/work/clip.wav", kind: .hostFile, session: "s", workspace: nil)
        var control = sessionRecord(workspace: nil)
        control.control = ControlSessionMetadata(domain: .workspaces, intent: .revise, targetId: nil, targetName: nil)
        let controlRecord = control
        let host = try await MacMarkdownAudioSource.resolve(
            input, token: "sk_fixture", socketPath: "/fixture.sock",
            session: { _ in controlRecord },
            workspace: { _ in Issue.record("Declared control must not invent a workspace"); return nil }
        )
        #expect(host.media.requestPath == "/files/raw?path=/work/clip.wav")
        let sandboxSession = sessionRecord(workspace: "sandbox", worktree: "session-branch")
        var workspace = Workspace(id: "sandbox", name: "Fixture", createdAt: Date(), updatedAt: Date())
        workspace.runtime = .sandbox
        let sandboxWorkspace = workspace
        let sandbox = try await MacMarkdownAudioSource.resolve(
            input, token: "sk_fixture", socketPath: "/fixture.sock",
            session: { _ in sandboxSession }, workspace: { _ in sandboxWorkspace }
        )
        #expect(sandbox.media.requestPath == "/workspaces/sandbox/sessions/s/raw/%2Fwork%2Fclip.wav")
        #expect(sandbox.filePlan.source == .workspaceFile(workspaceID: "sandbox", path: "/work/clip.wav"))
        #expect(sandbox.filePlan.worktreeId == "session-branch")
    }

    @Test func deniedMissingOrAmbiguousSessionMetadataCannotReadHost() async {
        let input = request(path: "/work/clip.wav", kind: .hostFile, session: "s", workspace: nil)
        for context in [nil, sessionRecord(workspace: nil), sessionRecord(id: "other", workspace: "w")] {
            await #expect(throws: (any Error).self) {
                try await MacMarkdownAudioSource.resolve(
                    input, token: "sk_fixture", socketPath: "/fixture.sock",
                    session: { _ in context }, workspace: { _ in Issue.record("Invalid session reached workspace lookup"); return nil }
                )
            }
        }
        await #expect(throws: (any Error).self) {
            try await MacMarkdownAudioSource.resolve(
                input, token: "sk_fixture", socketPath: "/fixture.sock",
                session: { _ in throw APIError.server(status: 403, message: "Denied") },
                workspace: { _ in Issue.record("Denied session reached workspace lookup"); return nil }
            )
        }
    }

    @Test func delayedSessionLookupCannotAuthorizeReboundPlayer() async {
        let input = request(path: "/work/clip.wav", kind: .hostFile, session: "s", workspace: nil)
        let gate = AudioSessionGate()
        let backend = AudioBackend()
        let controller = MacMarkdownAudioController(makeBackend: { _ in backend })
        controller.toggle(input) { request in
            try await MacMarkdownAudioSource.resolve(
                request, token: "sk_fixture", socketPath: "/fixture.sock",
                session: { _ in await gate.wait() },
                workspace: { _ in Issue.record("Cancelled session lookup must not start workspace lookup"); return nil }
            )
        }
        let task = controller.pendingTask
        await gate.started()
        controller.bind(request(worktree: "replacement"))
        await gate.finish(sessionRecord(workspace: "sandbox"))
        await task?.value
        #expect(controller.phase == .idle)
        #expect(backend.startCount == 0)
        #expect(backend.playCount == 0)
    }

    @Test func sameAbsoluteFilenameUsesAuthoritativeRuntime() async throws {
        let request = request(path: "/work/clip.wav", kind: .hostFile, session: "s")
        let host = try await resolve(request, runtime: .host)
        let sandbox = try await resolve(request, runtime: .sandbox)
        #expect(host.media.requestPath == "/files/raw?path=/work/clip.wav")
        #expect(sandbox.media.requestPath == "/workspaces/w/sessions/s/raw/%2Fwork%2Fclip.wav")
        #expect(!sandbox.media.identity.contains("sk_fixture"))
        #expect(try await sandbox.media.authorizationProvider() == "Bearer sk_fixture")
    }

    @Test func parserAdmitsOnlyAudioEmbedsAndPreservesOtherMedia() {
        for ext in ["wav", "mp3", "m4a", "aac", "flac", "ogg", "opus", "caf"] {
            for markdown in ["![[clips/clip.\(ext)]]", "![Clip](clips/clip.\(ext))"] {
                let kinds = MacMarkdownPaintDispatch.kinds(from: markdown, workspaceID: "w")
                #expect(kinds.contains { if case .audio = $0 { return true }; return false })
            }
        }
        for markdown in ["[[clip.wav]]", "[Clip](clip.wav)", "![Clip](https://example.com/clip.wav)", "<audio src='clip.wav'></audio>", "![[attachment:clip.wav]]"] {
            #expect(!MacMarkdownPaintDispatch.kinds(from: markdown, workspaceID: "w").contains {
                if case .audio = $0 { return true }; return false
            })
        }
        let kinds = MacMarkdownPaintDispatch.kinds(from: "![[a.png]]\n\n![[a.mp4]]", workspaceID: "w")
        #expect(kinds.contains { if case .image = $0 { return true }; return false })
        #expect(kinds.contains { if case .video = $0 { return true }; return false })
    }

    @Test func encodedHostPathAndSandboxOpenFallbackRetainOrigin() async throws {
        let host = try await resolve(request(path: "/work/a+b & c.wav", kind: .hostFile))
        #expect(host.media.requestPath == "/files/raw?path=/work/a%2Bb%20%26%20c.wav")
        #expect(host.filePlan.source == .hostFile(path: "/work/a+b & c.wav"))
        let sandbox = try await resolve(request(path: "/work/clip.wav", kind: .hostFile, worktree: "branch+one"), runtime: .sandbox)
        #expect(sandbox.media.requestPath == "/workspaces/w/raw/%2Fwork%2Fclip.wav?worktreeId=branch%2Bone")
        #expect(sandbox.filePlan.source == .workspaceFile(workspaceID: "w", path: "/work/clip.wav"))
        #expect(sandbox.filePlan.worktreeId == "branch+one")
    }

    @Test func resolvedAudioUsesAuthenticatedRangeTransportAndRejectsMissingBytes() async throws {
        let resolved = try await resolve(request(session: "s"))
        for status in [403, 404] {
            let transport = RecordingLocalHTTPTransport(response: MacLocalHTTPResponse(
                statusCode: status, headers: [:], body: Data()
            ))
            await #expect(throws: (any Error).self) {
                try await MacUnixSocketRangeClient.fetch(
                    source: resolved.media, range: .init(start: 0, end: 3), transport: transport
                )
            }
            let requests = await transport.requests
            #expect(requests.count == 1)
            #expect(requests.first?.path == "/workspaces/w/sessions/s/raw/clips%2Fclip.wav")
            #expect(requests.first?.headers["Authorization"] == "Bearer sk_fixture")
            #expect(requests.first?.headers["Range"] == "bytes=0-3")
        }
    }

    @Test func workspaceAndSessionKeepCheckoutIdentity() async throws {
        let main = try await resolve(request(worktree: "main"))
        let branch = try await resolve(request(worktree: "branch one"))
        let session = try await resolve(request(session: "s", worktree: "branch one"))
        #expect(main.media.requestPath == "/workspaces/w/raw/clips%2Fclip.wav")
        #expect(branch.media.requestPath == "/workspaces/w/raw/clips%2Fclip.wav?worktreeId=branch%20one")
        #expect(main.media.identity != branch.media.identity)
        #expect(session.media.requestPath == "/workspaces/w/sessions/s/raw/clips%2Fclip.wav")
    }

    @Test func missingOrDeniedContextNeverFallsBackToOwnerHost() async {
        let input = request(path: "/work/clip.wav", kind: .hostFile)
        await #expect(throws: (any Error).self) {
            try await MacMarkdownAudioSource.resolve(input, token: "sk_fixture", socketPath: "/fixture.sock") { _ in nil }
        }
        await #expect(throws: (any Error).self) {
            try await MacMarkdownAudioSource.resolve(input, token: "sk_fixture", socketPath: "/fixture.sock") { _ in
                throw APIError.server(status: 403, message: "Denied")
            }
        }
    }

    @Test func remoteAndUnsupportedNeverRequestContext() async {
        for path in ["https://example.com/clip.wav", "//example.com/clip.wav", "attachment:clip.wav", "data:clip.wav", "javascript:clip.wav", "readme.txt", "../clip.wav"] {
            await #expect(throws: (any Error).self) {
                try await MacMarkdownAudioSource.resolve(request(path: path), token: "sk_fixture", socketPath: "/fixture.sock") { _ in
                    Issue.record("Unsupported input requested context")
                    return nil
                }
            }
        }
    }

    @Test func noAutoplayAndPauseResumeAreExplicit() async throws {
        let backend = AudioBackend()
        let controller = MacMarkdownAudioController(makeBackend: { _ in backend })
        let input = request()
        var resolutions = 0
        let source = try await resolve(input)
        let provider: MacMarkdownAudioController.SourceProvider = { _ in resolutions += 1; return source }
        controller.bind(input)
        #expect(resolutions == 0)
        #expect(backend.playCount == 0)
        controller.toggle(input, source: provider)
        await controller.pendingTask?.value
        #expect(controller.phase == .loading)
        backend.emit(.ready)
        #expect(controller.phase == .playing)
        #expect(backend.playCount == 1)
        controller.toggle(input, source: provider)
        #expect(controller.phase == .paused)
        #expect(backend.pauseCount == 1)
        controller.toggle(input, source: provider)
        #expect(backend.playCount == 2)
        #expect(resolutions == 1)
        controller.cancel()
        backend.emit(.ready)
        #expect(backend.playCount == 2)
        #expect(backend.stopCount == 1)
    }

    @Test func staleLookupAndBackendEventsCannotStartReboundAudio() async throws {
        let gate = AudioLookupGate()
        let backend = AudioBackend()
        let controller = MacMarkdownAudioController(makeBackend: { _ in backend })
        let old = request()
        let source = try await resolve(old)
        controller.toggle(old) { _ in await gate.wait() }
        let pending = controller.pendingTask
        await gate.started()
        controller.bind(request(worktree: "other"))
        await gate.finish(source)
        await pending?.value
        #expect(controller.phase == .idle)
        #expect(backend.startCount == 0)
        #expect(backend.playCount == 0)
    }

    @Test func missingBytesAndDeniedPlaybackStayRetryable() async throws {
        let backend = AudioBackend()
        let controller = MacMarkdownAudioController(makeBackend: { _ in backend })
        let input = request()
        let source = try await resolve(input)
        for status in [404, 403] {
            controller.toggle(input) { _ in source }
            await controller.pendingTask?.value
            backend.emit(.failed)
            #expect(controller.phase == .unavailable)
            #expect(backend.playCount == 0)
            #expect(MacUnixSocketMediaResponseValidator.errorMessage(statusCode: status, requestedRange: nil, contentRange: nil) != nil)
        }
        #expect(backend.stopCount == 2)
    }

    @Test func openFallbackUsesResolvedPlanAndCannotNavigateAfterRemoval() async throws {
        let controller = MacMarkdownAudioController()
        let input = request(path: "/work/clip.wav", kind: .hostFile)
        let source = try await resolve(input, runtime: .sandbox)
        var opened: [FileViewerPlan] = []
        let action = MacOpenFileViewerAction { opened.append($0) }
        controller.open(input, source: { _ in source }, action: action)
        await controller.pendingTask?.value
        #expect(opened == [source.filePlan])
        let gate = AudioLookupGate()
        controller.open(input, source: { _ in await gate.wait() }, action: action)
        let task = controller.pendingTask
        await gate.started()
        controller.cancel()
        await gate.finish(source)
        await task?.value
        #expect(opened.count == 1)
    }

    @Test func rangedFixtureServesFirstLastByteCapsOversizeAndReturns416AtEOF() async throws {
        let wav = MarkdownAudioWAVFixture.silent(durationMilliseconds: 120)
        let total = wav.count
        let transport = RangedAudioHTTPTransport(body: wav, contentType: "audio/wav")
        func get(_ range: String) async throws -> MacLocalHTTPResponse {
            try await transport.perform(
                MacLocalHTTPRequest(method: "GET", path: "/workspaces/w/raw/clips%2Fclip.wav", headers: ["Range": range])
            )
        }
        let first = try await get("bytes=0-0")
        #expect(first.statusCode == 206)
        #expect(first.headers["content-range"] == "bytes 0-0/\(total)")
        #expect(first.body == wav.prefix(1))
        let last = try await get("bytes=\(total - 1)-\(total - 1)")
        #expect(last.statusCode == 206)
        #expect(last.headers["content-range"] == "bytes \(total - 1)-\(total - 1)/\(total)")
        #expect(last.body == wav.suffix(1))
        let oversize = try await get("bytes=0-999999")
        #expect(oversize.statusCode == 206)
        #expect(oversize.headers["content-range"] == "bytes 0-\(total - 1)/\(total)")
        #expect(oversize.body.count == total)
        let eof = try await get("bytes=\(total)-\(total)")
        #expect(eof.statusCode == 416)
        #expect(eof.headers["content-range"] == "bytes */\(total)")
        #expect(eof.body.isEmpty)
        let malformed = try await get("bytes=abc")
        #expect(malformed.statusCode == 416)
        #expect(malformed.headers["content-range"] == "bytes */\(total)")
        #expect(malformed.body.isEmpty)
    }

    @Test func deliveryWaitReturnsZeroWhenNoBytesArriveBeforeDeadline() async {
        let gate = AudioDeliveryGate()
        let started = ContinuousClock.now
        let value = await gate.wait(timeout: .milliseconds(200))
        #expect(value == 0)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func deliveryWaitReturnsWhenCancelledBeforeDelivery() async {
        let gate = AudioDeliveryGate()
        let beforeRegister = Task { await gate.wait(timeout: .seconds(30)) }
        beforeRegister.cancel()
        #expect(await beforeRegister.value == 0)
        let inFlight = Task { await gate.wait(timeout: .seconds(30)) }
        await Task.yield()
        inFlight.cancel()
        #expect(await inFlight.value == 0)
    }

    @Test func missingReadyEventDoesNotStartPlayback() async throws {
        let backend = AudioBackend()
        let controller = MacMarkdownAudioController(makeBackend: { _ in backend })
        let input = request()
        let source = try await resolve(input)
        controller.toggle(input) { _ in source }
        await controller.pendingTask?.value
        #expect(controller.phase == .loading)
        #expect(backend.startCount == 1)
        #expect(backend.playCount == 0)
        controller.cancel()
        backend.emit(.ready)
        #expect(backend.playCount == 0)
        #expect(controller.phase == .idle)
    }

    private func sessionRecord(id: String = "s", workspace: String?, worktree: String? = nil) -> Session {
        Session(id: id, workspaceId: workspace, worktreeId: worktree, status: .ready,
                createdAt: Date(timeIntervalSince1970: 0), lastActivity: Date(timeIntervalSince1970: 0),
                messageCount: 0, tokens: TokenUsage(input: 0, output: 0), cost: 0)
    }

    private func request(path: String = "clips/clip.wav", kind: ResourceReferenceKind = .workspaceFile,
                         session: String? = nil, worktree: String? = nil, workspace: String? = "w") -> MacMarkdownAudioRequest {
        MacMarkdownAudioRequest(embed: MarkdownAudioEmbed(reference: ResourceReference(
            target: path, sourceServerID: nil, workspaceID: workspace, sourceSessionID: session,
            fileCandidatePath: path, kind: kind
        )), worktreeId: worktree)
    }

    private func resolve(_ request: MacMarkdownAudioRequest, runtime: WorkspaceRuntime = .host) async throws -> MacMarkdownAudioSource.Resolved {
        try await MacMarkdownAudioSource.resolve(request, token: "sk_fixture", socketPath: "/fixture.sock") { id in
            var workspace = Workspace(id: id, name: "Fixture", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
            workspace.runtime = runtime
            return workspace
        }
    }
}

@MainActor
private final class AudioBackend: MacMarkdownAudioBackend {
    var startCount = 0
    var playCount = 0
    var pauseCount = 0
    var stopCount = 0
    var event: (@MainActor @Sendable (MacMarkdownAudioEvent) -> Void)?
    func start(_ event: @escaping @MainActor @Sendable (MacMarkdownAudioEvent) -> Void) { startCount += 1; self.event = event }
    func play() { playCount += 1 }
    func pause() { pauseCount += 1 }
    func teardown() { stopCount += 1 }
    func emit(_ event: MacMarkdownAudioEvent) { self.event?(event) }
}

private actor AudioSessionGate {
    private var continuation: CheckedContinuation<Session, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    func wait() async -> Session {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            startWaiter?.resume(); startWaiter = nil
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finish(_ session: Session) { continuation?.resume(returning: session); continuation = nil }
}

private actor AudioLookupGate {
    private var continuation: CheckedContinuation<MacMarkdownAudioSource.Resolved, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    func wait() async -> MacMarkdownAudioSource.Resolved {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            startWaiter?.resume(); startWaiter = nil
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finish(_ source: MacMarkdownAudioSource.Resolved) { continuation?.resume(returning: source); continuation = nil }
}

enum MarkdownAudioWAVFixture {
    /// Silent 8 kHz PCM. Inaudible. Playback proofs use ~1 s so currentTime can advance.
    static func silent(sampleRate: Int = 8_000, durationMilliseconds: Int = 120) -> Data {
        let samples = max(sampleRate * durationMilliseconds / 1_000, 1)
        let dataSize = samples * 2
        var data = Data()
        data.reserveCapacity(44 + dataSize)
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 4))
        }
        func u16(_ value: UInt16) {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 2))
        }
        ascii("RIFF")
        u32(UInt32(36 + dataSize))
        ascii("WAVE")
        ascii("fmt ")
        u32(16)
        u16(1)
        u16(1)
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))
        u16(2)
        u16(16)
        ascii("data")
        u32(UInt32(dataSize))
        data.append(Data(count: dataSize))
        return data
    }
}

enum MarkdownAudioRangeReply {
    static func response(body: Data, contentType: String, rangeHeader: String?) -> MacLocalHTTPResponse {
        let total = body.count
        let unsatisfiable = MacLocalHTTPResponse(
            statusCode: 416,
            headers: [
                "content-type": contentType,
                "content-range": "bytes */\(total)",
                "content-length": "0",
            ],
            body: Data()
        )
        guard total > 0 else { return unsatisfiable }
        guard let header = rangeHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty else {
            return unsatisfiable
        }
        let lowered = header.lowercased()
        guard lowered.hasPrefix("bytes=") else { return unsatisfiable }
        let spec = String(lowered.dropFirst("bytes=".count))
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]), start >= 0 else { return unsatisfiable }
        let end: Int
        if parts[1].isEmpty {
            end = total - 1
        } else if let parsed = Int(parts[1]), parsed >= start {
            end = parsed
        } else {
            return unsatisfiable
        }
        if start >= total { return unsatisfiable }
        let cappedEnd = min(end, total - 1)
        let slice = body.subdata(in: start..<(cappedEnd + 1))
        return MacLocalHTTPResponse(
            statusCode: 206,
            headers: [
                "content-type": contentType,
                "content-range": "bytes \(start)-\(cappedEnd)/\(total)",
                "content-length": "\(slice.count)",
            ],
            body: slice
        )
    }
}

/// Delivery, timeout, and cancellation resume the same waiter exactly once.
final class AudioDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = 0
    private var waiters: [UUID: CheckedContinuation<Int, Never>] = [:]
    private var cancelledBeforeRegister: Set<UUID> = []

    var current: Int {
        withLock { delivered }
    }

    func note(_ bytes: Int) {
        let pending: [CheckedContinuation<Int, Never>] = withLock {
            delivered = bytes
            let values = Array(waiters.values)
            waiters.removeAll()
            return values
        }
        for waiter in pending { waiter.resume(returning: bytes) }
    }

    func finish() {
        let pendingAndValue: ([CheckedContinuation<Int, Never>], Int) = withLock {
            let values = Array(waiters.values)
            waiters.removeAll()
            return (values, delivered)
        }
        for waiter in pendingAndValue.0 { waiter.resume(returning: pendingAndValue.1) }
    }

    func wait(timeout: Duration) async -> Int {
        let existing = withLock { delivered }
        if existing > 0 { return existing }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: Int? = withLock {
                    if delivered > 0 { return delivered }
                    if cancelledBeforeRegister.remove(id) != nil { return delivered }
                    waiters[id] = continuation
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                    return
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    self.finish(id)
                }
            }
        } onCancel: {
            self.cancel(id)
        }
    }

    private func finish(_ id: UUID) {
        let waiterAndValue: (CheckedContinuation<Int, Never>?, Int) = withLock {
            cancelledBeforeRegister.remove(id)
            let waiter = waiters.removeValue(forKey: id)
            return (waiter, delivered)
        }
        waiterAndValue.0?.resume(returning: waiterAndValue.1)
    }

    private func cancel(_ id: UUID) {
        let waiterAndValue: (CheckedContinuation<Int, Never>?, Int?) = withLock {
            if let waiter = waiters.removeValue(forKey: id) {
                return (waiter, delivered)
            }
            cancelledBeforeRegister.insert(id)
            return (nil, nil)
        }
        if let waiter = waiterAndValue.0, let value = waiterAndValue.1 {
            waiter.resume(returning: value)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

actor RangedAudioHTTPTransport: MacLocalHTTPPerforming {
    private(set) var requests: [MacLocalHTTPRequest] = []
    private let body: Data
    private let contentType: String
    private let gate = AudioDeliveryGate()

    var deliveredBytes: Int { gate.current }

    init(body: Data, contentType: String) {
        self.body = body
        self.contentType = contentType
    }

    func perform(_ request: MacLocalHTTPRequest) async throws -> MacLocalHTTPResponse {
        requests.append(request)
        let response = MarkdownAudioRangeReply.response(
            body: body, contentType: contentType, rangeHeader: request.headers["Range"]
        )
        if response.statusCode == 206 {
            gate.note(gate.current + response.body.count)
        }
        return response
    }

    func waitUntilDelivered(timeout: Duration = .seconds(4)) async -> Int {
        await gate.wait(timeout: timeout)
    }
}

final class ResumeOnceValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var didResume = false
    private var pending: Value?

    func arm(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if didResume {
            let value = pending
            lock.unlock()
            if let value { continuation.resume(returning: value) }
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: Value) {
        lock.lock()
        if didResume {
            lock.unlock()
            return
        }
        didResume = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        } else {
            pending = value
            lock.unlock()
        }
    }
}

@MainActor
final class MarkdownAudioPlayerProbe {
    private var observation: NSKeyValueObservation?
    private var timeObserver: Any?

    func teardown(player: AVPlayer) {
        observation?.invalidate()
        observation = nil
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    func waitUntilReady(_ item: AVPlayerItem, timeout: Duration) async -> AVPlayerItem.Status {
        if item.status == .readyToPlay || item.status == .failed { return item.status }
        let once = ResumeOnceValue<AVPlayerItem.Status>()
        return await withCheckedContinuation { continuation in
            once.arm(continuation)
            observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
                let status = item.status
                if status == .readyToPlay || status == .failed {
                    once.resume(status)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.resume(item.status)
            }
        }
    }

    func waitUntilTimeAdvances(_ player: AVPlayer, timeout: Duration) async -> Bool {
        if player.currentTime().seconds > 0 { return true }
        let once = ResumeOnceValue<Bool>()
        return await withCheckedContinuation { continuation in
            once.arm(continuation)
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                queue: .main
            ) { time in
                if time.seconds > 0 { once.resume(true) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.resume(player.currentTime().seconds > 0)
            }
        }
    }
}
