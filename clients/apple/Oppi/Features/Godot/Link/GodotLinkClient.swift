import Foundation
import os

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "GodotLink")

/// The app's side of a server's games (`protocol/godot.json`): the projects
/// it discovered, one project with its current release, a pack's download
/// (`GodotPackCache`), capture uploads, and the player link that brings new
/// releases and commands (`GodotPlayerLink`).
@MainActor
final class GodotLinkClient {
    /// The largest capture the server takes.
    static let captureLimit = 20 * 1024 * 1024

    private let api: APIClient
    private let makePlayerLink: (String) -> GodotPlayerLink?

    /// `playerLink` makes a project's link from the server connection, which owns its access
    /// renewal (`ServerConnection.makeGodotPlayerLink`).
    init(api: APIClient, playerLink: @escaping (String) -> GodotPlayerLink?) {
        self.api = api
        makePlayerLink = playerLink
    }

    /// `GET /godot`.
    func projects() async throws -> [GodotProject] {
        try JSONDecoder().decode(GodotProjectList.self, from: try await api.get(url: api.makeURL(pathSegments: ["godot"]))).projects
    }

    /// `GET /godot/{projectId}`; nil when the server has no project by this id.
    func project(_ id: String) async throws -> GodotProject? {
        do {
            let data = try await api.get(url: api.makeURL(pathSegments: ["godot", id]))
            return try JSONDecoder().decode(GodotProjectDetail.self, from: data).project
        } catch let error as APIError {
            switch error {
            case .server(404, _), .codedServer(404, _, _): return nil
            default: throw error
            }
        }
    }

    /// A resumable download of one pack (`ETag` is its SHA-256, so a resume
    /// is safe) through the server's bearer and pinned certificate.
    func packDownload(project: String, sha256: String) async throws -> ResumableFileDownload {
        ResumableFileDownload(
            url: try await api.makeURL(pathSegments: ["godot", project, "packs", sha256]),
            authorizationProvider: await api.mediaAuthorizationProvider(),
            pinnedLeafFingerprint: api.tlsCertFingerprint,
            expectedServerName: api.environment.tlsServerName,
            configuration: api.sessionConfiguration
        )
    }

    /// `PUT /godot/{projectId}/captures/{captureId}`.
    func uploadCapture(_ data: Data, mimeType: String, project: String, captureId: String) async throws {
        let path = "/" + ["godot", project, "captures", captureId]
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? $0 }
            .joined(separator: "/")
        let (body, response) = try await api.request("PUT", path: path, body: data, contentType: mimeType)
        try await api.checkStatus(response, data: body)
    }

    /// The player link for `project`, `WS /godot/{projectId}/link?role=player`.
    func playerLink(project: String) -> GodotPlayerLink? {
        makePlayerLink(project)
    }
}

/// One Godot pane's player link (`protocol/godot.json`): it attaches within the
/// server's 10 s window, hears the project's releases and the commands
/// controllers (agents, the CLI) send, and reports the pane's state, its
/// game's log, and each command's result. It reconnects with backoff until
/// stopped; the pane stays usable on its HTTP reads while the link is down.
/// While a socket is open, the connection's `StreamAuthRenewer` renews its
/// access (`auth_renew`) as every other stream's, so the server never closes
/// it for an expired token.
@MainActor
final class GodotPlayerLink {
    enum Event {
        case attached(playerId: String, project: GodotProject)
        case release(GodotRelease)
        case command(GodotLinkServerMessage.Command)
        case cancel(String)
    }

    var onEvent: ((Event) -> Void)?
    /// What the link says when it attaches, asked at each attach.
    var attachment: (() -> GodotLinkPlayerMessage.Attach)?

    private let url: URL
    /// The current access token (without `Bearer`).
    private let token: @Sendable () async throws -> String
    private let renewer: StreamAuthRenewer?
    private let session: URLSession
    private let webSocketFactory: (URLRequest) -> PersistentWebSocketTransport
    private var socket: PersistentWebSocketTransport?
    private var loop: Task<Void, Never>?
    private static let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30)]

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

    /// The link URL for `project` on the server at `baseURL`.
    static func url(baseURL: URL, project: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        let id = project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? project
        components.percentEncodedPath = base + "/godot/\(id)/link"
        components.queryItems = [URLQueryItem(name: "role", value: "player")]
        return components.url
    }

    isolated deinit {
        loop?.cancel()
        renewer?.stop()
        socket?.cancel(.goingAway, nil)
        session.invalidateAndCancel()
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled, let self {
                let attached = await self.runOnce()
                failures = attached ? 0 : failures + 1
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: Self.backoff[min(failures, Self.backoff.count - 1)])
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        renewer?.stop()
        socket?.cancel(.goingAway, nil)
        socket = nil
    }

    /// Sends when connected; a message while the link is down is dropped
    /// (the state is sent again on attach).
    func send(_ message: GodotLinkPlayerMessage) {
        guard let socket, let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        Task { try? await socket.send(.string(text)) }
    }

    /// One connection: attach, then read until it closes. True once attached.
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
            if self.socket?.identity == socket.identity { self.socket = nil }
        }
        if let attachment {
            send(.attach(attachment()))
        }
        var attached = false
        do {
            while !Task.isCancelled {
                guard case .string(let text) = try await socket.receive(),
                      let message = try? JSONDecoder().decode(GodotLinkServerMessage.self, from: Data(text.utf8)) else { continue }
                switch message {
                case .attached(let info):
                    attached = true
                    onEvent?(.attached(playerId: info.playerId ?? "", project: info.project))
                case .release(let release):
                    onEvent?(.release(release))
                case .command(let command):
                    onEvent?(.command(command))
                case .cancel(let id):
                    onEvent?(.cancel(id))
                case .authRenewResult(let result):
                    renewer?.handle(result)
                case .error(let error):
                    logger.error("Godot link refused: \(error.message, privacy: .public)")
                case .players, .log, .unknown:
                    break
                }
            }
        } catch {
            logger.info("Godot link closed: \(error.localizedDescription, privacy: .public)")
        }
        return attached
    }
}
