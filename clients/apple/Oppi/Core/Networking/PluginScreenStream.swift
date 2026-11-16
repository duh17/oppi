import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "PluginScreenStream")

/// One server's `WS /screens/stream` (`protocol/screens.json`): open only while a plugin screen
/// watches a page, multiplexed by watch id. A screen watches its page and gets the page's first
/// value, then its changes as ops; its taps go out as `act` and come back as one `result`.
///
/// It reconnects with backoff while anything watches, and sends every watch again on connect,
/// which answers with the current value: nothing is replayed. An `act` whose socket closes
/// before its result fails with "connection lost" and is never sent again; the socket stays
/// open for a result still due after the last unwatch. While a socket is open, the
/// connection's `StreamAuthRenewer` renews its access (`auth_renew`).
@MainActor
final class PluginScreenStream {
    struct Result: Equatable {
        var ok: Bool
        var message: String?
        var nav: PluginScreenNav?
    }

    private struct Watch {
        let entry: String
        let scope: String
        let page: String
        let onMessage: (PluginScreenServerMessage) -> Void
    }

    /// One stream per server connection, shared by its screens while any is alive. Keyed by the
    /// connection's identity, which a later connection can reuse: an entry counts only while its
    /// own connection is alive.
    private static var streams: [ObjectIdentifier: WeakStream] = [:]

    private let url: URL
    private let token: @Sendable () async throws -> String
    private let renewer: StreamAuthRenewer?
    private let session: URLSession
    private let webSocketFactory: (URLRequest) -> PersistentWebSocketTransport
    private var socket: PersistentWebSocketTransport?
    private var loop: Task<Void, Never>?
    private var watches: [String: Watch] = [:]
    private var calls: [String: CheckedContinuation<Result, Never>] = [:]
    private var nextId = 0
    private static let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]

    init(
        url: URL,
        token: @escaping @Sendable () async throws -> String,
        renewer: StreamAuthRenewer?,
        tlsCertFingerprint: String?,
        tlsServerName: String?,
        tailnetRoute: TailnetTransportRoute.Snapshot,
        webSocketFactory: ((URLRequest) -> PersistentWebSocketTransport)? = nil
    ) {
        self.url = url
        self.token = token
        self.renewer = renewer
        let session = URLSession(
            configuration: TailnetTransportRoute.defaultSessionConfiguration(route: tailnetRoute),
            delegate: PinnedServerTrustDelegate(pinnedLeafFingerprint: tlsCertFingerprint, expectedServerName: tlsServerName),
            delegateQueue: nil
        )
        self.session = session
        self.webSocketFactory = webSocketFactory ?? { request in
            PersistentWebSocketTransport(task: session.webSocketTask(with: request))
        }
    }

    isolated deinit {
        loop?.cancel()
        renewer?.stop()
        socket?.cancel(.goingAway, nil)
        session.invalidateAndCancel()
    }

    /// The stream of `connection`'s server, made on first use.
    static func shared(for connection: ServerConnection) -> PluginScreenStream? {
        let key = ObjectIdentifier(connection)
        if let held = streams[key], held.connection === connection, let stream = held.stream { return stream }
        guard let stream = connection.makePluginScreenStream() else { return nil }
        streams = streams.filter { $0.value.stream != nil && $0.value.connection != nil }
        streams[key] = WeakStream(stream: stream, connection: connection)
        return stream
    }

    /// The stream URL of the server at `baseURL`.
    static func url(baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.percentEncodedPath = base + "/screens/stream"
        return components.url
    }

    /// Watches `page` of `entry` in `scope` (`server`, `workspace:<id>`); `onMessage` gets its
    /// `value`, `ops`, `failed` and `ended`.
    func watch(
        entry: String, scope: String, page: String,
        onMessage: @escaping (PluginScreenServerMessage) -> Void
    ) -> String {
        nextId += 1
        let id = "w\(nextId)"
        watches[id] = Watch(entry: entry, scope: scope, page: page, onMessage: onMessage)
        if loop == nil { start() } else { send(.watch(watch: id, entry: entry, scope: scope, page: page)) }
        return id
    }

    func unwatch(_ id: String) {
        guard watches.removeValue(forKey: id) != nil else { return }
        send(.unwatch(watch: id))
        stopWhenIdle()
    }

    /// Closes the socket once nothing watches and no result is due.
    private func stopWhenIdle() {
        if watches.isEmpty, calls.isEmpty { stop() }
    }

    /// Sends one action on `watch` and waits for its result.
    func act(watch: String, action: String, row: String?, values: [PluginScreenValue]?) async -> Result {
        guard let socket else { return Result(ok: false, message: String(localized: "Connection lost. Try again.")) }
        nextId += 1
        let call = "c\(nextId)"
        return await withCheckedContinuation { continuation in
            calls[call] = continuation
            send(.act(watch: watch, call: call, action: action, row: row, values: values), on: socket)
        }
    }

    private func start() {
        loop = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled, let self, !self.watches.isEmpty {
                let opened = await self.runOnce()
                failures = opened ? 0 : failures + 1
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: Self.backoff[min(failures, Self.backoff.count - 1)])
            }
        }
    }

    private func stop() {
        loop?.cancel()
        loop = nil
        renewer?.stop()
        socket?.cancel(.goingAway, nil)
        socket = nil
        failCalls()
    }

    private func failCalls() {
        let pending = calls
        calls = [:]
        for continuation in pending.values {
            continuation.resume(returning: Result(ok: false, message: String(localized: "Connection lost. Try again.")))
        }
    }

    private func send(_ message: PluginScreenClientMessage, on socket: PersistentWebSocketTransport? = nil) {
        guard let socket = socket ?? self.socket, let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        Task { try? await socket.send(.string(text)) }
    }

    /// One connection: every watch sent again, then frames until it closes. True once a frame came.
    private func runOnce() async -> Bool {
        guard let token = try? await token(), !token.isEmpty else { return false }
        var request = URLRequest(url: url)
        ServerAuthorization.apply(token: token, to: &request)
        let socket = webSocketFactory(request)
        self.socket = socket
        socket.resume()
        renewer?.start(token: token, send: { text in try await socket.send(.string(text)) }, onRenewed: { _ in })
        defer {
            renewer?.stop()
            socket.cancel(.goingAway, nil)
            if self.socket?.identity == socket.identity {
                self.socket = nil
                failCalls()
                // It stayed open only for a result: nothing watches, so it is done.
                stopWhenIdle()
            }
        }
        for (id, watch) in watches {
            send(.watch(watch: id, entry: watch.entry, scope: watch.scope, page: watch.page), on: socket)
        }
        var opened = false
        do {
            while !Task.isCancelled {
                guard case .string(let text) = try await socket.receive(),
                      let message = try? JSONDecoder().decode(PluginScreenServerMessage.self, from: Data(text.utf8)) else { continue }
                opened = true
                deliver(message)
            }
        } catch {
            logger.info("Plugin screen stream closed: \(error.localizedDescription, privacy: .public)")
        }
        return opened
    }

    private func deliver(_ message: PluginScreenServerMessage) {
        switch message {
        case .value(let id, _), .ops(let id, _), .failed(let id, _):
            watches[id]?.onMessage(message)
        case .ended(let id, _):
            // The server holds nothing for it any more; a later watch asks again.
            watches.removeValue(forKey: id)?.onMessage(message)
            stopWhenIdle()
        case let .result(call, ok, text, nav):
            calls.removeValue(forKey: call)?.resume(returning: Result(ok: ok, message: text, nav: nav))
            stopWhenIdle()
        case .authRenewResult(let result):
            renewer?.handle(result)
        case .unknown:
            break
        }
    }
}

private struct WeakStream {
    weak var stream: PluginScreenStream?
    weak var connection: ServerConnection?
}

extension ServerConnection {
    /// The plugin screens' stream of this server: pinned and routed as the connection's other
    /// sockets, its access renewed as theirs is.
    func makePluginScreenStream() -> PluginScreenStream? {
        guard let selection = endpointSelection, let credentials,
              let url = PluginScreenStream.url(baseURL: selection.baseURL) else { return nil }
        let access = streamAccess(role: "screens")
        return PluginScreenStream(
            url: url,
            token: access.token,
            renewer: access.renewer,
            tlsCertFingerprint: credentials.normalizedTLSCertFingerprint,
            tlsServerName: selection.tlsServerName,
            tailnetRoute: route.configuredTailnetRoute
        )
    }
}
