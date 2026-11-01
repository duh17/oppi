import Darwin
import Foundation
import Network
import os
import Synchronization

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Rex")

/// Which way a host's Rex is reached.
enum RexRoute: Equatable, Sendable {
    /// The SSH bridge: `nc -U` to Rex's socket on the host.
    case ssh
    /// Rex's own Tailscale HTTPS serving at this URL, straight from this device.
    case tailscale(URL)

    var label: String {
        switch self {
        case .ssh: "Rex via SSH"
        case .tailscale: "Rex via Tailscale"
        }
    }

    /// The route in logs, without the host.
    var tag: String {
        switch self {
        case .ssh: "ssh"
        case .tailscale: "tailscale"
        }
    }
}

/// Whether this device has a route onto the tailnet right now: Oppi's own
/// Tailscale node has published its SOCKS proxy (`TailnetTransportRoute`), or
/// a system Tailscale VPN gave an interface an address in 100.64.0.0/10.
enum RexTailnetPath {
    static func usable() -> Bool {
        TailnetTransportRoute.proxy != nil || hasTailscaleAddress()
    }

    /// A tunnel interface (`utun*`) that is up holds a Tailscale (CGNAT) IPv4 address.
    static func hasTailscaleAddress() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            guard item.ifa_flags & UInt32(IFF_UP) != 0, let address = item.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            // A VPN's tunnel: a CGNAT address on Wi-Fi or cellular is not Tailscale.
            guard String(cString: item.ifa_name).hasPrefix("utun") else { continue }
            if isTailscaleAddress(UInt32(bigEndian: ipv4)) { return true }
        }
        return false
    }

    /// 100.64.0.0/10, host byte order.
    static func isTailscaleAddress(_ address: UInt32) -> Bool {
        address & 0xFFC0_0000 == 0x6440_0000
    }
}

/// One open's choice of route to a host's Rex (a terminal with its pane
/// switches, or one Rex list's subscriptions): Tailscale first when the host's
/// Rex said it serves there and this device has a tailnet route, else the SSH
/// bridge. A direct attempt that fails falls back to the bridge and is not
/// tried again in this open, nor by any open of the host for `failureHold`;
/// the next open after that tries again. Every bridge connection reads
/// `server.status` to learn, update, or forget the URL.
final class RexRoutePlan: Sendable {
    /// From the socket's open to Rex's welcome.
    static let directTimeout: Duration = .seconds(4)
    static let failureHold: Duration = .seconds(30)
    private static let held = Mutex<[UUID: ContinuousClock.Instant]>([:])

    let host: RexDirectHost
    let openDirect: RexLink.OpenDirect
    /// This plan's `directTimeout`: from the socket's open to Rex's welcome.
    let directDeadline: Duration
    private let store: RexDirectStore
    private let tailnetUsable: @Sendable () -> Bool
    private let isCurrent: @Sendable () -> Bool
    private let failedHere = Mutex(false)

    /// `isCurrent` says the saved host still signs in to the same target: a
    /// screen opened before Edit Host changed it must not reach the old
    /// host's Rex.
    init(
        host: RexDirectHost,
        store: RexDirectStore = RexDirectStore(),
        tailnetUsable: @escaping @Sendable () -> Bool = { RexTailnetPath.usable() },
        isCurrent: (@Sendable () -> Bool)? = nil,
        directDeadline: Duration = RexRoutePlan.directTimeout,
        openDirect: @escaping RexLink.OpenDirect = RexTLSStream.open
    ) {
        self.host = host
        self.directDeadline = directDeadline
        self.store = store
        self.tailnetUsable = tailnetUsable
        self.isCurrent = isCurrent ?? {
            SSHTerminalProfileStore().profile(id: host.id).map { RexDirectHost(profile: $0) == host } ?? false
        }
        self.openDirect = openDirect
    }

    /// The URL to try first, or nil for the bridge.
    func directCandidate(now: ContinuousClock.Instant = .now) -> URL? {
        guard let remembered = store.url(for: host), isCurrent() else { return nil }
        return Self.choose(
            remembered: remembered,
            tailnetUsable: tailnetUsable(),
            failedThisOpen: failedHere.withLock { $0 },
            heldUntil: Self.held.withLock { $0[host.id] },
            now: now
        )
    }

    static func choose(
        remembered: URL?, tailnetUsable: Bool, failedThisOpen: Bool,
        heldUntil: ContinuousClock.Instant?, now: ContinuousClock.Instant
    ) -> URL? {
        guard let remembered, tailnetUsable, !failedThisOpen else { return nil }
        if let heldUntil, now < heldUntil { return nil }
        return remembered
    }

    func directFailed(now: ContinuousClock.Instant = .now) {
        failedHere.withLock { $0 = true }
        Self.held.withLock { $0[host.id] = now.advanced(by: Self.failureHold) }
    }

    func directWorked() {
        _ = Self.held.withLock { $0.removeValue(forKey: host.id) }
    }

    /// Reads `server.status` over a bridge connection and remembers what it
    /// says about Rex's Tailscale serving.
    func discover(over control: RexControl) async {
        guard let answer = try? await control.call("server.status", [:]) else { return }
        store.apply(RexDirectDiscovery.outcome(statusJSON: answer), for: host)
    }

    /// Reads `server.status` over a direct connection and drops the address
    /// if another Rex answered there, or its serving moved or stopped
    /// (`RexDirectStore.confirm`).
    func confirm(over control: RexControl) async {
        guard let answer = try? await control.call("server.status", [:]) else { return }
        store.confirm(RexDirectDiscovery.outcome(statusJSON: answer), for: host)
    }

    /// The same from Rex's CLI on the host, for a host whose bridge cannot
    /// run (no `nc` that speaks Unix sockets).
    func discover(run: RexLink.Run) async {
        guard let result = try? await run(RexBridge.statusCommand), result.exitStatus == 0 else { return }
        store.apply(RexDirectDiscovery.outcome(statusJSON: result.output), for: host)
    }

    /// A control connection Rex welcomed over Tailscale within
    /// `directDeadline`, or nil when this open does not try (`directCandidate`)
    /// or the attempt failed, which is remembered.
    func attemptDirect(
        openStream: @escaping RexLink.OpenStream, onWritable: (@Sendable (Bool) -> Void)?
    ) async throws -> (RexLink, RexControl)? {
        guard let url = directCandidate() else { return nil }
        let link = RexLink(route: .tailscale(url), openStream: openStream, openDirect: openDirect)
        let started = ContinuousClock.now
        do {
            let deadline = directDeadline
            let control = try await Self.within(deadline) {
                try await link.connect(timeout: deadline, onWritable: onWritable)
            }
            // Cancelled while the welcome came in: nobody takes it.
            guard !Task.isCancelled else {
                control.close()
                throw CancellationError()
            }
            directWorked()
            RexRouteLog.chosen(link.route, directMs: Int((ContinuousClock.now - started) / .milliseconds(1)))
            Task { await confirm(over: control) }
            return (link, control)
        } catch {
            try Task.checkCancellation()
            directFailed()
            RexRouteLog.directFailed(error, milliseconds: Int((ContinuousClock.now - started) / .milliseconds(1)))
            return nil
        }
    }

    /// `body`'s control connection if it comes within `limit`. The deadline
    /// returns at once, cancelling `body` without waiting for it, so the
    /// fallback never waits on a stalled attempt. The caller's cancellation
    /// cancels `body` and returns when `body` gives up, or at the deadline at
    /// the latest. A connection that comes after either is closed.
    static func within(
        _ limit: Duration, _ body: @escaping @Sendable () async throws -> RexControl
    ) async throws -> RexControl {
        let attempt = Task { try await body() }
        let settled = Mutex(false)
        /// True for the first outcome only; later ones are someone else's to clean up.
        @Sendable func first() -> Bool { settled.withLock { done in defer { done = true }; return !done } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RexControl, any Error>) in
                Task {
                    do {
                        let control = try await attempt.value
                        if first() { continuation.resume(returning: control) } else { control.close() }
                    } catch {
                        if first() { continuation.resume(throwing: error) }
                    }
                }
                Task {
                    try? await Task.sleep(for: limit)
                    if first() {
                        attempt.cancel()
                        continuation.resume(throwing: RexClientError.timedOut)
                    }
                }
            }
        } onCancel: {
            attempt.cancel()
        }
    }
}

extension RexBridge {
    /// `rex api call server.status` with the CLI the bridge looks for.
    static let statusCommand = SSHTerminalRemoteShell.word(
        "r=\"$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex\"; "
            + "[ -x \"$r\" ] || r=rex; exec \"$r\" api call server.status"
    )
}

extension RexLink {
    /// A one-shot command on the host's SSH connection.
    typealias Run = @Sendable (_ command: String) async throws -> SSHExecResult

    /// A control connection Rex has welcomed, by `plan`'s route: over
    /// Tailscale when it says so, else over the SSH bridge, which then reads
    /// `server.status` for the next open. A host without a usable `nc` still
    /// tells its Tailscale address through Rex's CLI (`run`), and is reached
    /// that way if it can be. Without a plan, the bridge.
    static func connect(
        plan: RexRoutePlan?,
        openStream: @escaping OpenStream,
        run: Run?,
        onWritable: (@Sendable (Bool) -> Void)? = nil
    ) async throws -> (RexLink, RexControl) {
        if let direct = try await plan?.attemptDirect(openStream: openStream, onWritable: onWritable) { return direct }
        let bridge = RexLink(openStream: openStream)
        do {
            let control = try await bridge.connect(onWritable: onWritable)
            if let plan {
                RexRouteLog.chosen(.ssh)
                Task { await plan.discover(over: control) }
            }
            return (bridge, control)
        } catch RexClientError.bridgeMissing {
            guard let plan, let run else { throw RexClientError.bridgeMissing }
            await plan.discover(run: run)
            if let direct = try await plan.attemptDirect(openStream: openStream, onWritable: onWritable) { return direct }
            throw RexClientError.bridgeMissing
        }
    }
}

/// The route breadcrumb: which way Rex was reached, how long a direct attempt
/// took, and why one fell back. No host names.
enum RexRouteLog {
    static func chosen(_ route: RexRoute, directMs: Int? = nil) {
        var metadata = ["route": route.tag, "tailnetProxy": TailnetTransportRoute.proxy == nil ? "system" : "in-app"]
        if let directMs { metadata["directMs"] = String(directMs) }
        logger.info("Rex route \(route.tag, privacy: .public) directMs=\(directMs ?? -1, privacy: .public)")
        ClientLog.info("Network", "Rex route", metadata: metadata)
    }

    static func directFailed(_ error: any Error, milliseconds: Int) {
        var metadata = ["route": "tailscale", "status": "error", "directMs": String(milliseconds)]
        metadata.merge(ClientLog.networkErrorMetadata(error)) { current, _ in current }
        // Rex's refusal carries its JSON reason (the Tailscale login): private.
        logger.info("Rex direct failed after \(milliseconds, privacy: .public) ms (\(String(describing: type(of: error)), privacy: .public)): \(String(describing: error), privacy: .private)")
        ClientLog.info("Network", "Rex direct failed", metadata: metadata)
    }

    /// A pane's snapshot arrived: how long from asking for its stream.
    static func snapshot(_ route: RexRoute, milliseconds: Int, bytes: Int) {
        logger.info("Rex snapshot route=\(route.tag, privacy: .public) ms=\(milliseconds, privacy: .public) bytes=\(bytes, privacy: .public)")
    }
}

/// A TLS byte stream to Rex's Tailscale HTTPS serving (`<name>.ts.net:443`),
/// which Rex's WebSockets then run over with this side doing the framing
/// (`RexPipeSocket`, `RexWebSocketCodec`), exactly as over the SSH bridge:
/// the same upgrade, extensions, and frames. It goes through Oppi's Tailscale
/// node's SOCKS proxy while it runs (`TailnetTransportRoute`), else the system
/// network (a Tailscale VPN). The certificate is checked against the system's
/// roots for that name; the tailnet identity is the sign-in, and Rex admits
/// its owner's Tailscale user (or its tailnet's members, when it allows them).
///
/// Its events reach the sink on one serial queue, in order, as an SSH
/// channel's do; a network failure is reported before `.closed` the way a
/// channel reports a signal (`.exitSignal` with the error), which
/// `RexPipeSocket` turns into `RexClientError.lost`. With `inboundFlow`, a
/// paused consumer stops the reads. TCP keepalives (10 s idle, then 3 probes
/// 10 s apart) end a stream whose path died without a word.
final class RexTLSStream: Sendable {
    private struct State {
        var opened: CheckedContinuation<Void, any Error>?
        var openResult: Result<Void, any Error>?
        var reading = false
        var closed = false
        /// The owner closed the stream: its end is `.closed`, not the
        /// cancellation error the connection reports for it.
        var closing = false
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let inboundFlow: SSHPTYInboundFlow?
    private let sink: SSHPTYByteSink
    private let state = Mutex(State())

    private init(connection: NWConnection, queue: DispatchQueue, inboundFlow: SSHPTYInboundFlow?, sink: @escaping SSHPTYByteSink) {
        self.connection = connection
        self.queue = queue
        self.inboundFlow = inboundFlow
        self.sink = sink
    }

    /// Connects to `url`'s host and port (443 by default) within `timeout`.
    static func open(
        _ url: URL, inboundFlow: SSHPTYInboundFlow?, timeout: Duration, sink: @escaping SSHPTYByteSink
    ) async throws -> SSHExecStream {
        guard let host = url.host, !host.isEmpty, let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 443)) else {
            throw RexClientError.unreadable("Rex's Tailscale address")
        }
        let tls = NWProtocolTLS.Options()
        // A WebSocket upgrade is HTTP/1.1.
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        TailnetTransportRoute.apply(to: parameters, route: .forHost(host))
        let queue = DispatchQueue(label: "Rex Tailscale stream")
        let stream = RexTLSStream(
            connection: NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters),
            queue: queue, inboundFlow: inboundFlow, sink: sink
        )
        stream.connection.stateUpdateHandler = { [weak stream] state in stream?.changed(state) }
        let timer = Task { [weak stream] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            stream?.settleOpen(.failure(RexClientError.timedOut))
        }
        defer { timer.cancel() }
        do {
            try await withTaskCancellationHandler {
                stream.connection.start(queue: queue)
                try await withCheckedThrowingContinuation { continuation in
                    let ready = stream.state.withLock { state -> Result<Void, any Error>? in
                        if let result = state.openResult { return result }
                        state.opened = continuation
                        return nil
                    }
                    if let ready { continuation.resume(with: ready) }
                }
            } onCancel: {
                stream.settleOpen(.failure(CancellationError()))
            }
        } catch {
            stream.state.withLock { $0.closed = true }
            stream.connection.cancel()
            throw error
        }
        // The consumer's resume reads on, once per pause.
        inboundFlow?.attach { [weak stream] in stream?.queue.async { stream?.readNext() } }
        queue.async { stream.readNext() }
        return SSHExecStream(send: { try await stream.send($0) }, close: { stream.close() })
    }

    private func send(_ bytes: Data) async throws {
        guard !state.withLock({ $0.closed }) else { throw RexClientError.connectionClosed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Closes without waiting; the sink then hears `.closed`, which
    /// `RexPipeSocket` reads as `RexClientError.connectionClosed`.
    private func close() {
        state.withLock { $0.closing = true }
        connection.cancel()
    }

    // MARK: - On the queue

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            settleOpen(.success(()))
        case .waiting(let error):
            // No route to the name right now: fall back rather than wait.
            if !opened { settleOpen(.failure(error)); connection.cancel() }
        case .failed(let error):
            if opened { finish(error) } else { settleOpen(.failure(error)) }
            connection.cancel()
        case .cancelled:
            if opened { finish() } else { settleOpen(.failure(RexClientError.connectionClosed)) }
        default:
            break
        }
    }

    private var opened: Bool {
        state.withLock { state in
            guard case .success? = state.openResult else { return false }
            return true
        }
    }

    /// Reads the next chunk, unless the consumer paused reading: then
    /// `inboundFlow`'s resume reads on.
    private func readNext() {
        if inboundFlow?.isPaused == true { return }
        let start = state.withLock { state -> Bool in
            guard !state.closed, !state.reading else { return false }
            state.reading = true
            return true
        }
        guard start else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            state.withLock { $0.reading = false }
            if let data, !data.isEmpty, !state.withLock({ $0.closed }) { sink(.data(data)) }
            if complete || error != nil {
                connection.cancel()
                finish(error)
            } else {
                readNext()
            }
        }
    }

    /// The stream is over: the sink hears it once, with the network error
    /// that ended it, if one did.
    private func finish(_ error: NWError? = nil) {
        let (first, closing) = state.withLock { state -> (Bool, Bool) in
            guard !state.closed else { return (false, state.closing) }
            state.closed = true
            return (true, state.closing)
        }
        guard first else { return }
        sink(.eof)
        if let error, !closing { sink(.exitSignal(error.localizedDescription)) }
        sink(.closed)
    }

    private func settleOpen(_ result: Result<Void, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard state.openResult == nil else { return nil }
            state.openResult = result
            defer { state.opened = nil }
            return state.opened
        }
        waiter?.resume(with: result)
    }
}
