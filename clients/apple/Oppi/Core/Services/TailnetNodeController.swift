import Foundation
import OSLog
import TailscaleKit

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Tailnet")

/// Owns Oppi's embedded userspace Tailscale node (official TailscaleKit).
///
/// The node joins the tailnet as its own device through interactive login; no
/// Network Extension, VPN profile, or auth key is involved. Login and run state
/// come from the IPN bus, the machine list from LocalAPI status, and while the
/// node runs its loopback SOCKS5 proxy is published to `TailnetTransportRoute`
/// for Oppi HTTPS/WSS to `*.ts.net`.
///
/// After Connect, launch starts the node only when a paired Tailscale hostname
/// needs it. Otherwise Settings, SSH preflight, or a `*.ts.net` connection
/// start it lazily. Disconnect stays off across launches.
@MainActor @Observable
final class TailnetNodeController {
    static let shared = TailnetNodeController()

    /// Shown in the Tailscale admin console; control de-duplicates repeats.
    nonisolated static let hostName = "oppi-ios"

    private(set) var isStarted = false
    private(set) var status = TailnetNodeStatus()
    private(set) var snapshot: TailnetStatusSnapshot?
    private(set) var failure: String?

    var state: TailnetNodeState {
        guard isStarted else { return .off }
        if let failure { return .failed(failure) }
        return status.nodeState
    }

    var onlinePeers: [TailnetPeer] { snapshot?.onlinePeers ?? [] }

    /// Called when the SOCKS route appears, moves, or goes away. Transports bake
    /// the route into their URLSession, so paired tailnet servers must rebuild.
    @ObservationIgnored var onRouteChange: (@MainActor () -> Void)?

    @ObservationIgnored private var node: TailscaleNode?
    @ObservationIgnored private var busProcessor: MessageProcessor?
    @ObservationIgnored private var generation: UInt64 = 0
    /// False until the current bus watch delivers a notification. A watch that
    /// fails before delivering means the loopback listener is gone (iOS
    /// reclaims it from a suspended app), so the node must be recreated.
    @ObservationIgnored private var busDeliveredSinceWatch = false
    @ObservationIgnored private var lastNodeRestart: ContinuousClock.Instant?

    private static let nodeRestartInterval: Duration = .seconds(30)

    // MARK: - Lifecycle

    /// Launch starts the node only when Tailnet is enabled and a paired server
    /// host is a Tailscale hostname (`ServerTLSTrustPolicy.isTailscaleHostname`
    /// / `TailnetTransportRoute.matchDomains`).
    nonisolated static func shouldStartAtLaunch(isEnabled: Bool, pairedHosts: some Sequence<String>) -> Bool {
        guard isEnabled else { return false }
        return pairedHosts.contains { ServerTLSTrustPolicy.isTailscaleHostname($0) }
    }

    func startIfEnabled() {
        guard AppPreferences.Tailnet.isEnabled else { return }
        start()
    }

    func startAtLaunchIfNeeded(pairedHosts: some Sequence<String>) {
        guard Self.shouldStartAtLaunch(
            isEnabled: AppPreferences.Tailnet.isEnabled,
            pairedHosts: pairedHosts
        ) else { return }
        start()
    }

    func connect() {
        AppPreferences.Tailnet.setEnabled(true)
        start()
    }

    #if DEBUG
    /// Shows a settled node in screenshot previews without starting TailscaleKit.
    func applyPreviewSnapshot(_ snapshot: TailnetStatusSnapshot) {
        isStarted = true
        failure = nil
        var next = TailnetNodeStatus()
        next.apply(snapshot)
        status = next
        self.snapshot = snapshot
    }
    #endif

    func disconnect() async {
        AppPreferences.Tailnet.setEnabled(false)
        await stop()
    }

    /// Recreates the node from its saved state after a failure.
    func restart() async {
        await stop()
        start()
    }

    /// `.running` can land before `publishRoute` finishes. Bootstrap URLSessions
    /// snapshot SOCKS at creation, so pairing waits for this generation's proxy.
    func waitUntilCurrentGenerationProxyReady(timeout: Duration = .seconds(20)) async throws {
        let expectedGeneration = generation
        try await TailnetSameUserPairing.waitForCurrentGenerationProxy(
            expectedGeneration: expectedGeneration,
            timeout: timeout,
            generation: { [weak self] in self?.generation ?? 0 },
            nodeState: { [weak self] in self?.state ?? .off },
            proxy: { TailnetTransportRoute.proxy }
        )
    }

    private func start() {
        guard !isStarted else { return }
        isStarted = true
        failure = nil
        status = TailnetNodeStatus()
        snapshot = nil
        generation &+= 1
        let generation = generation
        ClientLog.info("Tailnet", "Starting embedded node")

        Task { [weak self] in
            let node: TailscaleNode
            do {
                node = try await Self.makeNode(logSink: TailnetLogSink())
            } catch {
                self?.fail(generation, "Tailscale could not start: \(error.localizedDescription)")
                return
            }
            guard let self, self.generation == generation else {
                try? await node.close()
                return
            }
            self.node = node
            await self.watchBus(node: node, generation: generation)
            // up() blocks until the node is Running, which may wait on login.
            // Bus notifications drive state; this only surfaces a hard failure.
            Task { [weak self] in
                do {
                    try await node.up()
                } catch {
                    self?.fail(generation, "Tailscale could not connect: \(error.localizedDescription)")
                }
            }
        }
    }

    private func stop() async {
        generation &+= 1
        busProcessor?.cancel()
        busProcessor = nil
        let node = self.node
        self.node = nil
        isStarted = false
        status = TailnetNodeStatus()
        snapshot = nil
        failure = nil
        unpublishRoute()
        if let node {
            try? await node.close()
        }
        ClientLog.info("Tailnet", "Stopped embedded node")
    }

    nonisolated private static func makeNode(logSink: TailnetLogSink) async throws -> TailscaleNode {
        let directory = try stateDirectory()
        let config = Configuration(
            hostName: hostName,
            path: directory.path(percentEncoded: false),
            authKey: nil,
            controlURL: kDefaultControlURL,
            ephemeral: false
        )
        // tailscale_start does disk I/O; keep it off the main actor.
        return try await Task.detached { try TailscaleNode(config: config, logger: logSink) }.value
    }

    /// Node keys and login state. Excluded from backup so a restore onto
    /// another device does not clone this tailnet identity.
    nonisolated private static func stateDirectory() throws -> URL {
        var directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Tailscale", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
    }

    private func fail(_ generation: UInt64, _ message: String) {
        guard generation == self.generation, isStarted else { return }
        logger.error("\(message, privacy: .public)")
        ClientLog.error("Tailnet", "Embedded node failed", metadata: ["error": message])
        failure = message
        unpublishRoute()
    }

    // MARK: - IPN bus

    private func watchBus(node: TailscaleNode, generation: UInt64) async {
        busProcessor?.cancel()
        busProcessor = nil
        busDeliveredSinceWatch = false
        let consumer = TailnetBusConsumer(
            onEvent: { [weak self] event in
                Task { @MainActor in self?.apply(event, generation: generation) }
            },
            onError: { [weak self] message in
                Task { @MainActor in await self?.handleBusError(message, generation: generation) }
            }
        )
        do {
            let client = LocalAPIClient(localNode: node, logger: TailnetLogSink())
            let processor = try await client.watchIPNBus(
                mask: [.initialState, .netmap, .rateLimitNetmaps, .noPrivateKeys],
                consumer: consumer
            )
            guard generation == self.generation else {
                processor.cancel()
                return
            }
            busProcessor = processor
        } catch {
            fail(generation, "Tailscale LocalAPI is unavailable: \(error.localizedDescription)")
        }
    }

    private func apply(_ event: TailnetBusEvent, generation: UInt64) {
        guard generation == self.generation else { return }
        busDeliveredSinceWatch = true
        let wasRunning = status.isRunning
        status.apply(event)
        if status.isRunning != wasRunning {
            ClientLog.info("Tailnet", "Backend state changed", metadata: [
                "state": status.backendState.rawValue,
            ])
            if status.isRunning {
                failure = nil
                Task { await publishRoute(generation: generation) }
            } else {
                unpublishRoute()
            }
        }
        if event.state != nil || event.netmapChanged {
            Task { await refresh() }
        }
    }

    private func handleBusError(_ message: String, generation: UInt64) async {
        guard generation == self.generation, isStarted, let node else { return }
        logger.notice("IPN bus ended: \(message, privacy: .public)")
        if busDeliveredSinceWatch {
            // Idle long-poll timeout or a dropped stream; watch again.
            await watchBus(node: node, generation: generation)
            return
        }
        let now = ContinuousClock.now
        if let lastNodeRestart, now - lastNodeRestart < Self.nodeRestartInterval {
            fail(generation, "Tailscale LocalAPI is unavailable: \(message)")
            return
        }
        lastNodeRestart = now
        ClientLog.warning("Tailnet", "Recreating node after LocalAPI loss", metadata: ["error": message])
        await stop()
        start()
    }

    // MARK: - LocalAPI status

    /// Re-reads LocalAPI status for login state and the machine list. Uses the
    /// in-memory LocalAPI, which survives iOS reclaiming the loopback listener.
    func refresh() async {
        guard let node else { return }
        let generation = generation
        do {
            let data = try await node.statusJSON()
            let snapshot = try TailnetStatusProjection.snapshot(fromStatusJSON: data)
            guard generation == self.generation else { return }
            self.snapshot = snapshot
            let wasRunning = status.isRunning
            status.apply(snapshot)
            if status.isRunning, !wasRunning {
                await publishRoute(generation: generation)
            } else if wasRunning, !status.isRunning {
                unpublishRoute()
            }
        } catch {
            logger.error("LocalAPI status failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Outgoing TCP

    /// Opens a TCP connection to `host:port` through the node's userspace
    /// netstack (`tailscale_dial`) and returns the connected local socket. The
    /// caller owns it; closing it ends the tailnet connection.
    ///
    /// `tailscale_dial` blocks with no deadline; `BlockingSocketDial` bounds it.
    /// Throws `SSHPreflightFailure` or `CancellationError`.
    func dialTCP(host: String, port: UInt16, timeout: Duration) async throws -> Int32 {
        guard state == .running, let node else { throw SSHPreflightFailure.tailnetNotRunning }
        guard let handle = await node.tailscale else { throw SSHPreflightFailure.tailnetNotRunning }
        let address = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        return try await BlockingSocketDial.run(timeout: timeout) {
            var conn: Int32 = 0
            guard tailscale_dial(handle, "tcp", address, &conn) == 0 else {
                return .failure(.dialFailed(Self.lastError(handle)))
            }
            return .success(conn)
        }
    }

    nonisolated private static func lastError(_ handle: TailscaleHandle) -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        buffer.withUnsafeMutableBufferPointer { raw in
            raw.withMemoryRebound(to: CChar.self) { _ = tailscale_errmsg(handle, $0.baseAddress, $0.count) }
        }
        let bytes = buffer.prefix { $0 != 0 }
        let message = (String(bytes: bytes, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "connection failed" : message
    }

    // MARK: - Transport route

    private func publishRoute(generation: UInt64) async {
        guard let node else { return }
        do {
            let loopback = try await node.loopback()
            guard generation == self.generation, status.isRunning else { return }
            guard let host = loopback.ip,
                  let port = loopback.port.flatMap(UInt16.init(exactly:)) else {
                fail(generation, "Tailscale returned an invalid proxy address.")
                return
            }
            let proxy = TailnetSOCKSProxy(host: host, port: port, credential: loopback.proxyCredential)
            guard TailnetTransportRoute.proxy != proxy else { return }
            TailnetTransportRoute.publish(proxy, generation: generation)
            ClientLog.info("Tailnet", "Published tailnet transport route")
            onRouteChange?()
        } catch {
            fail(generation, "Tailscale proxy is unavailable: \(error.localizedDescription)")
        }
    }

    private func unpublishRoute() {
        guard TailnetTransportRoute.proxy != nil else { return }
        TailnetTransportRoute.publish(nil)
        ClientLog.info("Tailnet", "Withdrew tailnet transport route")
        onRouteChange?()
    }
}

/// Receives IPN bus notifications from TailscaleKit's MessageProcessor.
private actor TailnetBusConsumer: MessageConsumer {
    private let onEvent: @Sendable (TailnetBusEvent) -> Void
    private let onError: @Sendable (String) -> Void

    init(
        onEvent: @escaping @Sendable (TailnetBusEvent) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        self.onEvent = onEvent
        self.onError = onError
    }

    func notify(_ notify: Ipn.Notify) {
        onEvent(TailnetBusEvent(
            state: notify.State.map(Self.backendState),
            browseToURL: notify.BrowseToURL,
            loginFinished: notify.LoginFinished != nil,
            errorMessage: notify.ErrMessage,
            netmapChanged: notify.NetMap != nil
        ))
    }

    func error(_ error: any Error) {
        onError(error.localizedDescription)
    }

    private static func backendState(_ state: Ipn.State) -> TailnetBackendState {
        switch state {
        case .NoState: .noState
        case .InUseOtherUser: .inUseOtherUser
        case .NeedsLogin: .needsLogin
        case .NeedsMachineAuth: .needsMachineAuth
        case .Stopped: .stopped
        case .Starting: .starting
        case .Running: .running
        @unknown default: .noState
        }
    }
}

/// TailscaleKit wrapper logs go to the unified log at debug level; Go backend
/// logs are dropped (no log fd), since they include peer and endpoint detail.
private struct TailnetLogSink: LogSink {
    var logFileHandle: Int32? { nil }

    func log(_ message: String) {
        logger.debug("\(message, privacy: .private)")
    }
}
