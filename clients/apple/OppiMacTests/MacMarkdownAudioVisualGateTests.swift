import AppKit
import Darwin
import Foundation
import QuartzCore
import SwiftUI
import Testing
@testable import Oppi

@Suite(.serialized)
@MainActor
struct MacMarkdownAudioVisualGateTests {
    @Test(arguments: [
        "Before\n\n![[clips/sample.wav|Sample audio]]\n\nAfter",
        "**Before ![[clips/sample.wav|Sample audio]] after**",
    ])
    func markdownMountsCompactExplicitPlayControl(_ markdown: String) async throws {
        var requests: [MacMarkdownAudioRequest] = []
        let signal = AudioMountSignal()
        let host = NSHostingView(rootView: MacMarkdownDocumentView(
            markdown: markdown,
            workspaceID: "audio-fixture", worktreeId: "feature-audio"
        )
        .environment(\.macMarkdownAudioSource, { request in
            requests.append(request)
            signal.finish()
            throw APIError.server(status: 403, message: "Fixture denied")
        })
        .environment(\.theme, AppTheme.dark)
        .frame(width: 480).padding(12))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 504, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        settle(host)
        let play = try #require(buttons(host).first { $0.accessibilityIdentifier() == "markdown-audio.play" },
                                "Production Markdown must mount an explicit native audio control, not just its label")
        #expect(requests.isEmpty, "Mount must neither resolve nor play audio")
        #expect(play.accessibilityLabel() == "Play audio")
        #expect(play.bounds.height > 0 && play.bounds.height <= 64,
                "Native button alignment outsets must remain within the compact 64-point strip")
        #expect(play.title.isEmpty, "Icon-only controls must not overflow the compact strip")
        let suffix = markdown.hasPrefix("**") ? "-styled" : ""
        try capture(host, name: "mounted-idle\(suffix)")
        play.performClick(nil)
        await signal.wait()
        settle(host)
        #expect(requests.count == 1)
        #expect(requests.first?.embed.filePath == "clips/sample.wav")
        #expect(requests.first?.embed.reference.workspaceID == "audio-fixture")
        #expect(requests.first?.worktreeId == "feature-audio")
        #expect(play.accessibilityLabel() == "Retry audio")
        #expect(buttons(host).contains { $0.accessibilityIdentifier() == "markdown-audio.open" })
        try capture(host, name: "mounted-denied-retry\(suffix)")
    }

    @Test func markdownSessionReadyToPlayAdvancesCurrentTime() async throws {
        let wav = MarkdownAudioWAVFixture.silent(durationMilliseconds: 1_000)
        let transport = RangedAudioHTTPTransport(body: wav, contentType: "audio/wav")
        let input = MacMarkdownAudioRequest(
            embed: MarkdownAudioEmbed(reference: ResourceReference(
                target: "clips/clip.wav", sourceServerID: nil, workspaceID: "w",
                sourceSessionID: nil, fileCandidatePath: "clips/clip.wav", kind: .workspaceFile
            )),
            worktreeId: nil
        )
        let resolved = try await MacMarkdownAudioSource.resolve(
            input, token: "sk_fixture", socketPath: "/fixture.sock"
        ) { id in
            var workspace = Workspace(
                id: id, name: "Fixture",
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            )
            workspace.runtime = .host
            return workspace
        }
        #expect(!resolved.media.identity.contains("sk_fixture"))
        #expect(!resolved.media.requestPath.contains("sk_"))
        let session = MacAuthenticatedMediaPlaybackSession(source: resolved.media, transport: transport)
        session.player.isMuted = true
        session.player.volume = 0
        let probe = MarkdownAudioPlayerProbe()
        defer {
            probe.teardown(player: session.player)
            session.teardown()
        }
        let item = try #require(session.player.currentItem)
        let status = await probe.waitUntilReady(item, timeout: .seconds(4))
        if status == .failed {
            Issue.record("AVPlayerItem failed: \(String(describing: item.error))")
        }
        #expect(status == .readyToPlay, "Real range session must become readyToPlay, not only receive HTTP bytes")
        session.player.play()
        let advanced = await probe.waitUntilTimeAdvances(session.player, timeout: .seconds(2))
        session.player.pause()
        let requests = await transport.requests
        let delivered = await transport.deliveredBytes
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.method == "GET" })
        #expect(requests.allSatisfy { $0.path == "/workspaces/w/raw/clips%2Fclip.wav" })
        #expect(requests.allSatisfy { $0.headers["Authorization"] == "Bearer sk_fixture" })
        #expect(requests.allSatisfy { $0.headers["Range"]?.hasPrefix("bytes=") == true })
        #expect(requests.allSatisfy { !$0.path.contains("sk_") && !$0.path.contains("http") })
        #expect(delivered > 0)
        #expect(advanced, "Muted currentTime must advance after readyToPlay; byte delivery alone is not playback")
    }

    @Test func markdownExplicitPlayReachesPlayingThroughRealRangeAdapter() async throws {
        let wav = MarkdownAudioWAVFixture.silent(durationMilliseconds: 1_000)
        let server = try UnixRangeHTTPFixture.start(body: wav, contentType: "audio/wav")
        defer { server.stop() }
        var requests: [MacMarkdownAudioRequest] = []
        let host = NSHostingView(rootView: MacMarkdownDocumentView(
            markdown: "Before\n\n![[clips/sample.wav|Sample audio]]\n\nAfter",
            workspaceID: "audio-fixture", worktreeId: "feature-audio"
        )
        .environment(\.macMarkdownAudioSource, { request in
            requests.append(request)
            return try await MacMarkdownAudioSource.resolve(
                request, token: "sk_fixture", socketPath: server.socketPath
            ) { id in
                var workspace = Workspace(
                    id: id, name: "Fixture",
                    createdAt: Date(timeIntervalSince1970: 0),
                    updatedAt: Date(timeIntervalSince1970: 0)
                )
                workspace.runtime = .host
                return workspace
            }
        })
        .environment(\.theme, AppTheme.dark)
        .frame(width: 480).padding(12))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 504, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        settle(host)
        let play = try #require(buttons(host).first { $0.accessibilityIdentifier() == "markdown-audio.play" })
        #expect(requests.isEmpty, "Mount must neither resolve nor play audio")
        #expect(play.accessibilityLabel() == "Play audio")
        play.performClick(nil)
        let playing = await waitUntil(timeout: .seconds(4), host: host) {
            play.accessibilityLabel() == "Pause audio"
        }
        let recorded = server.snapshot()
        #expect(requests.count == 1)
        #expect(requests.first?.embed.filePath == "clips/sample.wav")
        #expect(requests.first?.worktreeId == "feature-audio")
        #expect(server.deliveredBytes > 0)
        #expect(!recorded.isEmpty)
        #expect(recorded.allSatisfy { $0.authorization == "Bearer sk_fixture" })
        #expect(recorded.allSatisfy { $0.range?.hasPrefix("bytes=") == true })
        #expect(recorded.allSatisfy {
            $0.path == "/workspaces/audio-fixture/raw/clips%2Fsample.wav?worktreeId=feature-audio"
        })
        #expect(recorded.allSatisfy { !$0.path.contains("sk_") && !$0.path.contains("http") })
        #expect(playing, "Production Markdown click must reach Pause/Playing through the real backend, not merely receive bytes")
        #expect(play.accessibilityLabel() == "Pause audio")
        try capture(host, name: "mounted-positive-playing")
    }

    @Test func markdownNeverReadySourceDoesNotReachPlayingWithinDeadline() async throws {
        var requests: [MacMarkdownAudioRequest] = []
        let host = NSHostingView(rootView: MacMarkdownDocumentView(
            markdown: "![[clips/sample.wav|Sample audio]]",
            workspaceID: "audio-fixture", worktreeId: "feature-audio"
        )
        .environment(\.macMarkdownAudioSource, { request in
            requests.append(request)
            try await Task.sleep(for: .seconds(30))
            throw APIError.server(status: 403, message: "Never ready")
        })
        .environment(\.theme, AppTheme.dark)
        .frame(width: 480).padding(12))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 504, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        settle(host)
        let play = try #require(buttons(host).first { $0.accessibilityIdentifier() == "markdown-audio.play" })
        play.performClick(nil)
        let playing = await waitUntil(timeout: .milliseconds(400), host: host) {
            play.accessibilityLabel() == "Pause audio"
        }
        #expect(requests.count == 1)
        #expect(!playing, "A source that never becomes ready must fail the Pause/Playing gate within its deadline")
        #expect(play.accessibilityLabel() != "Pause audio")
    }

    @Test func unixRangeFixtureReturns416AtEOF() async throws {
        let wav = MarkdownAudioWAVFixture.silent(durationMilliseconds: 120)
        let server = try UnixRangeHTTPFixture.start(body: wav, contentType: "audio/wav")
        defer { server.stop() }
        let client = MacUnixSocketHTTPClient(socketPath: server.socketPath, timeout: 2)
        let response = try await client.perform(MacLocalHTTPRequest(
            method: "GET",
            path: "/workspaces/audio-fixture/raw/clips%2Fsample.wav",
            headers: [
                "Authorization": "Bearer sk_fixture",
                "Range": "bytes=\(wav.count)-\(wav.count)",
            ]
        ))
        #expect(response.statusCode == 416)
        #expect(response.headers["content-range"] == "bytes */\(wav.count)")
        #expect(response.body.isEmpty)
    }

    private func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) }
    }

    private func settle(_ host: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
    }

    private func waitUntil(timeout: Duration, host: NSView, _ condition: @MainActor () -> Bool) async -> Bool {
        if condition() { return true }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            settle(host)
            if condition() { return true }
        }
        return condition()
    }

    private func capture(_ host: NSView, name: String) throws {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        // Measure the painted card at its clear center, not NSButton's native
        // alignment rect (which includes system-controlled outsets).
        // Sample the rendered center so color-profile conversion does not
        // turn a geometry assertion into a comparison with an unrendered Color.
        let expected = try #require(bitmap.colorAt(
            x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2
        )?.usingColorSpace(.deviceRGB))
        var longest = 0
        var current = 0
        for y in 0..<bitmap.pixelsHigh {
            let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y)?.usingColorSpace(.deviceRGB)
            if let color,
               abs(color.redComponent - expected.redComponent) < 0.01,
               abs(color.greenComponent - expected.greenComponent) < 0.01,
               abs(color.blueComponent - expected.blueComponent) < 0.01 {
                current += 1
                longest = max(longest, current)
            } else { current = 0 }
        }
        let paintedHeight = CGFloat(longest) * host.bounds.height / CGFloat(bitmap.pixelsHigh)
        #expect(abs(paintedHeight - 64) <= 1, "Mounted audio must paint a compact 64-point strip")
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".pi/audio-proof")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}

@MainActor
private final class AudioMountSignal {
    private var finished = false
    private var continuation: CheckedContinuation<Void, Never>?
    func finish() { finished = true; continuation?.resume(); continuation = nil }
    func wait() async {
        if finished { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private struct UnixRangeHTTPRecord: Sendable {
    var path: String
    var authorization: String?
    var range: String?
}

/// Test-only owner-socket HTTP/1.1 range server. Serves one generated WAV over AF_UNIX.
private final class UnixRangeHTTPFixture: @unchecked Sendable {
    let socketPath: String
    private let body: Data
    private let contentType: String
    private let listenFD: Int32
    private let queue = DispatchQueue(label: "dev.chenda.OppiMac.markdown-audio-range")
    private let lock = NSLock()
    private var stopped = false
    private var records: [UnixRangeHTTPRecord] = []
    private let gate = AudioDeliveryGate()

    private init(socketPath: String, body: Data, contentType: String, listenFD: Int32) {
        self.socketPath = socketPath
        self.body = body
        self.contentType = contentType
        self.listenFD = listenFD
    }

    static func start(body: Data, contentType: String) throws -> UnixRangeHTTPFixture {
        let socketPath = "/tmp/oppi-md-audio-\(UUID().uuidString).sock"
        unlink(socketPath)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        do {
            try bindUnix(fd: fd, path: socketPath)
        } catch {
            Darwin.close(fd)
            throw error
        }
        guard Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        let server = UnixRangeHTTPFixture(
            socketPath: socketPath, body: body, contentType: contentType, listenFD: fd
        )
        server.queue.async { server.acceptLoop() }
        return server
    }

    var deliveredBytes: Int { gate.current }

    func snapshot() -> [UnixRangeHTTPRecord] {
        withLock { records }
    }

    func waitUntilDelivered(timeout: Duration) async -> Int {
        await gate.wait(timeout: timeout)
    }

    func stop() {
        withLock { stopped = true }
        gate.finish()
        Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
        unlink(socketPath)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func acceptLoop() {
        while true {
            if withLock({ stopped }) { return }
            var addr = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(listenFD, sockPtr, &length)
                }
            }
            if client < 0 { continue }
            handle(clientFD: client)
        }
    }

    private func handle(clientFD: Int32) {
        defer { Darwin.close(clientFD) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil, buffer.count < 65_536 {
            let readCount = chunk.withUnsafeMutableBytes { raw in
                Darwin.read(clientFD, raw.baseAddress, raw.count)
            }
            if readCount <= 0 { return }
            buffer.append(contentsOf: chunk.prefix(readCount))
        }
        guard let headerRange = buffer.range(of: separator),
              let headerText = String(data: buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound), encoding: .utf8)
        else { return }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let record = UnixRangeHTTPRecord(
            path: String(parts[1]),
            authorization: headers["authorization"],
            range: headers["range"]
        )
        let reply = MarkdownAudioRangeReply.response(
            body: body, contentType: contentType, rangeHeader: record.range
        )
        let reason = reply.statusCode == 206 ? "Partial Content" : "Range Not Satisfiable"
        var header = "HTTP/1.1 \(reply.statusCode) \(reason)\r\n"
        for key in reply.headers.keys.sorted() {
            header += "\(key): \(reply.headers[key] ?? "")\r\n"
        }
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(reply.body)
        var offset = 0
        while offset < response.count {
            let written = response.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(clientFD, base.advanced(by: offset), response.count - offset)
            }
            if written <= 0 { return }
            offset += written
        }
        withLock { records.append(record) }
        if reply.statusCode == 206 {
            gate.note(gate.current + reply.body.count)
        }
    }

    private static func bindUnix(fd: Int32, path: String) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLength = path.utf8.count
        guard pathLength < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[pathLength] = 0
        }
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.EADDRINUSE) }
    }
}
