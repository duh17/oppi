import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "APIClient")

/// Network failures that may make an HTTP route unavailable for future work.
/// HTTP responses, decoding failures, cancellation, and TLS failures are intentionally excluded.
enum APIClientAvailabilityFailure: Sendable, Equatable {
    case timedOut
    case cannotFindHost
    case cannotConnectToHost
    case networkConnectionLost
    case notConnectedToInternet
    case dnsLookupFailed
    case cannotLoadFromNetwork

    init?(error: Error) {
        guard let urlError = error as? URLError else { return nil }
        switch urlError.code {
        case .timedOut: self = .timedOut
        case .cannotFindHost: self = .cannotFindHost
        case .cannotConnectToHost: self = .cannotConnectToHost
        case .networkConnectionLost: self = .networkConnectionLost
        case .notConnectedToInternet: self = .notConnectedToInternet
        case .dnsLookupFailed: self = .dnsLookupFailed
        case .cannotLoadFromNetwork: self = .cannotLoadFromNetwork
        default: return nil
        }
    }
}

typealias APIClientAvailabilityObserver = @Sendable (APIClientAvailabilityFailure) async -> Void
typealias APIClientResponseFailureObserver = @Sendable (APIError) async -> Void

private final class APIClientResponseFailureObserverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var observer: APIClientResponseFailureObserver?

    func set(_ observer: APIClientResponseFailureObserver?) {
        lock.withLock { self.observer = observer }
    }

    func notify(_ error: APIError) {
        let observer = lock.withLock { self.observer }
        guard let observer else { return }
        Task { await observer(error) }
    }
}

private final class DeviceAuthSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var session: DeviceAuthSession?

    func set(_ session: DeviceAuthSession?) {
        lock.withLock { self.session = session }
    }

    func get() -> DeviceAuthSession? {
        lock.withLock { self.session }
    }
}

/// REST client for oppi server.
///
/// This file owns the transport: auth and its 401 refresh, URL building, status
/// checks, and failure observation. The endpoints live in `APIClient+<Area>.swift`
/// and go through `get`/`post`/`put`/`patch`/`delete`, whose `as:` forms decode
/// the JSON body. An endpoint with its own status handling, headers, or decoding
/// calls `request` or `performAuthorized` and `checkStatus` itself.
actor APIClient: ClientLogUploading {
    /// A total deadline for one candidate bootstrap request. This races the
    /// complete URLSession task and cancels that task when the deadline wins.
    struct BootstrapDeadline: Sendable {
        private let wait: @Sendable () async throws -> Void

        static func after(_ duration: Duration) -> Self {
            Self(wait: { try await Task.sleep(for: duration) })
        }

        init(wait: @escaping @Sendable () async throws -> Void) {
            self.wait = wait
        }

        func waitForExpiry() async throws {
            try await wait()
        }
    }

    /// The JSON body `{}`.
    struct EmptyBody: Encodable {}

    let baseURL: URL
    let token: String
    let environment: OppiClientEnvironment
    nonisolated let tailnetRoute: TailnetTransportRoute.Snapshot
    /// Device-key auth session. When set, the bearer comes from this session and
    /// a 401 triggers a single-flight refresh with exactly one retry.
    nonisolated private let authSessionBox = DeviceAuthSessionBox()
    let tlsCertFingerprint: String?
    private let session: URLSession
    private let trustDelegate: PinnedServerTrustDelegate
    private let availabilityObserver: APIClientAvailabilityObserver?
    nonisolated private let responseFailureObserverBox = APIClientResponseFailureObserverBox()
    /// `workspaceFileEditing`, `skillFileEditing`, `piFileEditing`, and
    /// `fileEditOrigins` from this client's own `/server/info`. Nil keeps those
    /// files read-only.
    private(set) var workspaceFileEditing: ServerInfo.WorkspaceFileEditingCapability?
    private(set) var skillFileEditing: ServerInfo.WorkspaceFileEditingCapability?
    private(set) var piFileEditing: ServerInfo.WorkspaceFileEditingCapability?
    private(set) var fileEditOrigins: ServerInfo.WorkspaceFileEditingCapability?

    init(
        environment: OppiClientEnvironment,
        availabilityObserver: APIClientAvailabilityObserver? = nil
    ) {
        self.init(environment: environment, sessionConfiguration: nil, availabilityObserver: availabilityObserver)
    }

    init(
        baseURL: URL,
        token: String,
        tlsCertFingerprint: String? = nil,
        availabilityObserver: APIClientAvailabilityObserver? = nil
    ) {
        self.init(
            environment: OppiClientEnvironment(
                baseURL: baseURL,
                bearerToken: token,
                pinnedCertificateFingerprint: tlsCertFingerprint
            ),
            sessionConfiguration: nil,
            availabilityObserver: availabilityObserver
        )
    }

    // periphery:ignore - used by APIClientTests via @testable import
    /// Test-only init with custom URLSessionConfiguration.
    init(
        environment: OppiClientEnvironment,
        configuration: URLSessionConfiguration,
        availabilityObserver: APIClientAvailabilityObserver? = nil
    ) {
        self.init(environment: environment, sessionConfiguration: configuration, availabilityObserver: availabilityObserver)
    }

    /// Test-only init with custom URLSessionConfiguration.
    init(
        baseURL: URL,
        token: String,
        configuration: URLSessionConfiguration,
        tlsCertFingerprint: String? = nil,
        availabilityObserver: APIClientAvailabilityObserver? = nil
    ) {
        self.init(
            environment: OppiClientEnvironment(
                baseURL: baseURL,
                bearerToken: token,
                pinnedCertificateFingerprint: tlsCertFingerprint
            ),
            sessionConfiguration: configuration,
            availabilityObserver: availabilityObserver
        )
    }

    /// `sessionConfiguration` nil is a client the app builds for a server: the
    /// route's default configuration with the API timeouts, and file uploads
    /// that may run in the background session. A test passes its stub configuration.
    private init(
        environment: OppiClientEnvironment,
        sessionConfiguration: URLSessionConfiguration?,
        availabilityObserver: APIClientAvailabilityObserver?
    ) {
        self.tailnetRoute = .forHost(environment.baseURL.host)
        self.environment = environment
        self.baseURL = environment.baseURL
        self.token = environment.bearerToken
        self.tlsCertFingerprint = environment.pinnedCertificateFingerprint
        self.availabilityObserver = availabilityObserver
        trustDelegate = PinnedServerTrustDelegate(
            pinnedLeafFingerprint: environment.pinnedCertificateFingerprint,
            expectedServerName: environment.tlsServerName
        )

        let config: URLSessionConfiguration
        if let sessionConfiguration {
            config = sessionConfiguration
        } else {
            config = TailnetTransportRoute.defaultSessionConfiguration(route: tailnetRoute)
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
        }
        session = URLSession(
            configuration: config,
            delegate: trustDelegate,
            delegateQueue: nil
        )
        backgroundUploadsAllowed = sessionConfiguration == nil
    }

    /// A session that is never invalidated keeps its delegate and connection
    /// pool until the app exits. Each route candidate and reconfigure makes a
    /// new client; a request in flight holds its client, so nothing is cut off.
    deinit {
        session.finishTasksAndInvalidate()
        foregroundUploads?.invalidate()
    }

    /// Attachment bodies can take many minutes. The API session ends any request at
    /// 30 seconds total; uploads run on `AttachmentUploadTransport`, which fails one
    /// only when no bytes move for `AttachmentUploadTransport.idleTimeout`.
    private var foregroundUploads: AttachmentUploadTransport?
    /// Whether a file upload may run in the app's background session. Only the
    /// clients the app builds for a server; test clients keep their stub configuration.
    nonisolated private let backgroundUploadsAllowed: Bool

    /// A file upload keeps going while Oppi is in the background. Not through the
    /// in-app Tailscale node: its proxy runs in this process and stops when iOS
    /// suspends it, so such an upload waits for Oppi to come back.
    nonisolated var fileUploadsContinueInBackground: Bool {
        backgroundUploadsAllowed && tailnetRoute.proxy == nil
    }

    private func uploadTransport(for body: AttachmentUploadBody) -> AttachmentUploadTransport {
        if case .file = body, fileUploadsContinueInBackground {
            return .background
        }
        if let foregroundUploads { return foregroundUploads }
        let transport = AttachmentUploadTransport(configuration: session.configuration)
        foregroundUploads = transport
        return transport
    }

    // MARK: - Health & Server Info

    /// Check server reachability.
    func health() async throws -> Bool {
        try await performHealth(timeoutInterval: nil)
    }

    func health(timeoutInterval: TimeInterval) async throws -> Bool {
        try await performHealth(timeoutInterval: timeoutInterval)
    }

    private func performHealth(timeoutInterval: TimeInterval?) async throws -> Bool {
        var request = try URLRequest(url: makeURL(path: "/health"))
        request.httpMethod = "GET"
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        ServerAuthorization.apply(token: try await authorizedToken(), to: &request)
        let (_, response) = try await performData(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Fetch server metadata (version, uptime, stats) for the server detail view.
    func serverInfo() async throws -> ServerInfo {
        recordCapabilities(try await get("/server/info", as: ServerInfo.self))
    }

    private func recordCapabilities(_ info: ServerInfo) -> ServerInfo {
        workspaceFileEditing = info.capabilities?.workspaceFileEditing
        skillFileEditing = info.capabilities?.skillFileEditing
        piFileEditing = info.capabilities?.piFileEditing
        fileEditOrigins = info.capabilities?.fileEditOrigins
        return info
    }

    /// Fetch authenticated server metadata while bounding the entire request.
    /// The deadline applies only to this bootstrap call; the retained client's
    /// normal 15-second request and 30-second resource policies remain intact.
    func serverInfo(bootstrapDeadline: BootstrapDeadline) async throws -> ServerInfo {
        let url = try makeURL(path: "/server/info")
        logger.debug("GET /server/info [bootstrap]")
        let (data, response) = try await withAuthorizedRetry {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            return request
        } perform: { request in
            try await self.bootstrapData(for: request, deadline: bootstrapDeadline)
        }
        try checkStatus(response, data: data)
        return recordCapabilities(try JSONDecoder().decode(ServerInfo.self, from: data))
    }

    // MARK: - Transport

    func performData(
        for request: URLRequest,
        reportsAvailability: Bool = true
    ) async throws -> (Data, URLResponse) {
        let rejections = trustDelegate.rejectionCount
        do {
            return try await session.data(for: request)
        } catch {
            let error = namingCertificateRejection(error, since: rejections)
            if reportsAvailability { reportAvailabilityFailure(for: error) }
            throw error
        }
    }

    /// A rejected server certificate reaches the caller as a cancelled request
    /// (the delegate cancels the challenge). Callers ignore cancels, so name it
    /// with the certificate error the connection layer already treats as a
    /// verdict: not retried, and not an availability failure.
    private func namingCertificateRejection(_ error: Error, since rejections: Int) -> Error {
        guard (error as? URLError)?.code == .cancelled, !Task.isCancelled,
              trustDelegate.rejectionCount > rejections else { return error }
        return URLError(
            .serverCertificateUntrusted,
            userInfo: [NSLocalizedDescriptionKey: PinnedServerTrustDelegate.rejectionMessage]
        )
    }

    private func bootstrapData(
        for request: URLRequest,
        deadline: BootstrapDeadline
    ) async throws -> (Data, URLResponse) {
        let rejections = trustDelegate.rejectionCount
        do {
            return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
                group.addTask { [session] in
                    try await Self.dataTask(session: session, request: request)
                }
                group.addTask {
                    try await deadline.waitForExpiry()
                    try Task.checkCancellation()
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw APIError.invalidResponse
                }
                return result
            }
        } catch {
            let error = namingCertificateRejection(error, since: rejections)
            reportAvailabilityFailure(for: error)
            throw error
        }
    }

    private final class BootstrapTaskCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false

        func install(_ task: URLSessionDataTask) {
            lock.lock()
            self.task = task
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel {
                task.cancel()
            }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
        }
    }

    private static func dataTask(
        session: URLSession,
        request: URLRequest
    ) async throws -> (Data, URLResponse) {
        let cancellation = BootstrapTaskCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: APIError.invalidResponse)
                    }
                }
                cancellation.install(task)
                task.resume()
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }

    /// Classified availability is reported without awaiting recovery. The failed
    /// request must unwind so single-flight owners can clear; recovery runs for
    /// future work and must not sit on this call stack.
    private func reportAvailabilityFailure(for error: Error) {
        guard let failure = APIClientAvailabilityFailure(error: error) else { return }
        guard let availabilityObserver else { return }
        Task { await availabilityObserver(failure) }
    }

    // The endpoint verbs: each sends one authorized request and throws `checkStatus`'s
    // error for a non-2xx answer. The `as:` forms then decode the JSON body as `type`.

    func get(_ path: String) async throws -> Data {
        try checked(await request("GET", path: path))
    }

    func get<Response: Decodable>(_ path: String, as type: Response.Type) async throws -> Response {
        try JSONDecoder().decode(type, from: await get(path))
    }

    func get(url: URL) async throws -> Data {
        try checked(await request("GET", url: url))
    }

    func get<Response: Decodable>(url: URL, as type: Response.Type) async throws -> Response {
        try JSONDecoder().decode(type, from: await get(url: url))
    }

    func post<T: Encodable>(_ path: String, body: T, encoder: JSONEncoder? = nil) async throws -> Data {
        try checked(await request("POST", path: path, body: body, encoder: encoder))
    }

    func post<T: Encodable, Response: Decodable>(_ path: String, body: T, as type: Response.Type) async throws -> Response {
        try JSONDecoder().decode(type, from: await post(path, body: body))
    }

    func put<T: Encodable>(_ path: String, body: T) async throws -> Data {
        try checked(await request("PUT", path: path, body: body))
    }

    func put<T: Encodable, Response: Decodable>(_ path: String, body: T, as type: Response.Type) async throws -> Response {
        try JSONDecoder().decode(type, from: await put(path, body: body))
    }

    func put<T: Encodable>(url: URL, body: T) async throws -> Data {
        try checked(await request("PUT", url: url, body: body))
    }

    func put<T: Encodable, Response: Decodable>(url: URL, body: T, as type: Response.Type) async throws -> Response {
        try JSONDecoder().decode(type, from: await put(url: url, body: body))
    }

    func patch<T: Encodable, Response: Decodable>(_ path: String, body: T, as type: Response.Type) async throws -> Response {
        try JSONDecoder().decode(type, from: checked(await request("PATCH", path: path, body: body)))
    }

    func delete(_ path: String) async throws -> Data {
        try checked(await request("DELETE", path: path))
    }

    func delete<Response: Decodable>(_ path: String, as type: Response.Type) async throws -> Response {
        try JSONDecoder().decode(type, from: await delete(path))
    }

    private func checked(_ exchange: (Data, URLResponse)) throws -> Data {
        try checkStatus(exchange.1, data: exchange.0)
        return exchange.0
    }

    func request(_ method: String, path: String, timeoutInterval: TimeInterval? = nil) async throws -> (Data, URLResponse) {
        try await performAuthorized {
            var req = try URLRequest(url: self.makeURL(path: path))
            req.httpMethod = method
            if let timeoutInterval { req.timeoutInterval = timeoutInterval }
            logger.debug("\(method) \(path)")
            return req
        }
    }

    func request(_ method: String, url: URL) async throws -> (Data, URLResponse) {
        try await performAuthorized {
            var req = URLRequest(url: url)
            req.httpMethod = method
            logger.debug("\(method) \(url.path)")
            return req
        }
    }

    func request<T: Encodable>(
        _ method: String,
        url: URL,
        body: T,
        encoder: JSONEncoder? = nil
    ) async throws -> (Data, URLResponse) {
        try await performAuthorized {
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try (encoder ?? JSONEncoder()).encode(body)
            logger.debug("\(method) \(url.path)")
            return req
        }
    }

    func request<T: Encodable>(
        _ method: String,
        path: String,
        body: T,
        encoder: JSONEncoder? = nil,
        timeoutInterval: TimeInterval? = nil,
        reportsAvailability: Bool = true
    ) async throws -> (Data, URLResponse) {
        try await performAuthorized(reportsAvailability: reportsAvailability) {
            var req = try URLRequest(url: self.makeURL(path: path))
            req.httpMethod = method
            if let timeoutInterval { req.timeoutInterval = timeoutInterval }
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try (encoder ?? JSONEncoder()).encode(body)
            logger.debug("\(method) \(path)")
            return req
        }
    }

    func request(_ method: String, path: String, body: Data, contentType: String) async throws -> (Data, URLResponse) {
        try await performAuthorized {
            var req = try URLRequest(url: self.makeURL(path: path))
            req.httpMethod = method
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            logger.debug("\(method) \(path)")
            return req
        }
    }

    private func performBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let rejections = trustDelegate.rejectionCount
        do {
            return try await session.bytes(for: request)
        } catch {
            let error = namingCertificateRejection(error, since: rejections)
            reportAvailabilityFailure(for: error)
            throw error
        }
    }

    // MARK: - Authorization

    /// Resolve the bearer token, refreshing a device-key access token when it is
    /// near expiry. Falls back to the leftover/static token when the session has
    /// not produced a usable replacement. Refresh rejection (revoked/unknown
    /// device) fails closed instead of sending a possibly-expired snapshot.
    private func authorizedToken(
        forceRefresh: Bool = false,
        replacing staleToken: String? = nil
    ) async throws -> String {
        guard let authSession = authSessionBox.get() else { return token }
        if forceRefresh {
            return try await authSession.refreshAccessToken(replacing: staleToken)
        }
        let cached = await authSession.accessToken
        if cached.isEmpty, !token.isEmpty {
            return token
        }
        do {
            return ServerAuthorization.resolvedToken(
                try await authSession.currentAccessToken(),
                fallback: token
            )
        } catch {
            if case DeviceAuthError.refreshRejected = error {
                throw error
            }
            if !token.isEmpty { return token }
            throw error
        }
    }

    /// A per-request bearer resolver for AVFoundation media loading. It refreshes
    /// (single-flight) when the access token is near expiry instead of returning a
    /// 10-minute snapshot, so long playback outlives the token. Refresh rejection
    /// (revoked/unknown device) fails closed. An unavailable device key falls back
    /// to a leftover/static token when one exists, then fails closed if that
    /// leftover is also empty instead of issuing an unauthenticated request.
    func mediaAuthorizationProvider() -> @Sendable () async throws -> String {
        let staticToken = token
        return { [weak self] in
            guard let self else {
                return try Self.requireNonEmptyBearer(staticToken)
            }
            let current = try await self.authorizedToken()
            return try Self.requireNonEmptyBearer(current)
        }
    }

    /// A copy of the API session's configuration, for a session that outlives its resource timeout (a file download).
    nonisolated var sessionConfiguration: URLSessionConfiguration { session.configuration }

    private static func requireNonEmptyBearer(_ token: String) throws -> String {
        guard !token.isEmpty else {
            throw DeviceAuthError.challengeUnavailable
        }
        return ServerAuthorization.headerValue(token: token)
    }

    /// Apply the bearer token, perform the request, and on a 401 with a device-key
    /// session refresh single-flight and retry exactly once. Refresh rejection
    /// (revoked/unknown device) propagates so the caller fails closed.
    func performAuthorized(
        reportsAvailability: Bool = true,
        buildingRequest: () throws -> URLRequest
    ) async throws -> (Data, URLResponse) {
        try await withAuthorizedRetry(buildingRequest) {
            try await self.performData(for: $0, reportsAvailability: reportsAvailability)
        }
    }

    /// `performAuthorized` for a streamed body; a 401's stream is cancelled before the retry.
    func performAuthorizedBytes(
        buildingRequest: () throws -> URLRequest
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await withAuthorizedRetry(
            buildingRequest,
            discarding: { $0.task.cancel() },
            perform: { try await self.performBytes(for: $0) }
        )
    }

    /// The one bearer policy every authorized request follows: apply the token,
    /// perform, and on a 401 with a device-key session `discard` the first answer,
    /// refresh single-flight, and retry exactly once with a freshly built request.
    private func withAuthorizedRetry<Body>(
        _ makeRequest: () throws -> URLRequest,
        discarding discard: (Body) -> Void = { _ in },
        perform: (URLRequest) async throws -> (Body, URLResponse)
    ) async throws -> (Body, URLResponse) {
        var request = try makeRequest()
        var current = try await authorizedToken()
        ServerAuthorization.apply(token: current, to: &request)
        var (body, response) = try await perform(request)
        if authSessionBox.get() != nil, (response as? HTTPURLResponse)?.statusCode == 401 {
            discard(body)
            current = try await authorizedToken(forceRefresh: true, replacing: current)
            var retry = try makeRequest()
            ServerAuthorization.apply(token: current, to: &retry)
            (body, response) = try await perform(retry)
        }
        return (body, response)
    }

    /// An attachment upload's bytes: in memory, or a file that streams from disk.
    enum AttachmentUploadBody {
        case data(Data)
        case file(URL)
    }

    private struct UploadContentResponse: Decodable {
        let attachment: ChatAttachmentRef
    }

    /// `PUT` attachment bytes to `path` and answer the attachment the server stored.
    func putAttachmentContent(
        path: String,
        body: AttachmentUploadBody,
        contentType: String,
        progress: AttachmentUploadTransport.Progress?
    ) async throws -> ChatAttachmentRef {
        let (data, response) = try await performAuthorizedAttachmentUpload(
            path: path,
            body: body,
            contentType: contentType,
            progress: progress
        )
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(UploadContentResponse.self, from: data).attachment
    }

    /// Sends attachment bytes (a file streams from disk, never loaded) through the
    /// same auth-refresh, TLS, and error-reporting path as `performAuthorized`, on
    /// `AttachmentUploadTransport`'s idle timeout.
    private func performAuthorizedAttachmentUpload(
        path: String,
        body: AttachmentUploadBody,
        contentType: String,
        progress: AttachmentUploadTransport.Progress?
    ) async throws -> (Data, URLResponse) {
        try await withAuthorizedRetry {
            var req = try URLRequest(url: self.makeURL(path: path))
            req.httpMethod = "PUT"
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            logger.debug("PUT \(path) [attachment]")
            return req
        } perform: {
            try await self.performUpload(for: $0, body: body, progress: progress)
        }
    }

    private func performUpload(
        for request: URLRequest,
        body: AttachmentUploadBody,
        progress: AttachmentUploadTransport.Progress?
    ) async throws -> (Data, URLResponse) {
        let rejections = trustDelegate.rejectionCount
        let transport = uploadTransport(for: body)
        do {
            switch body {
            case .data(let data):
                return try await transport.upload(request, from: data, trust: trustDelegate, progress: progress)
            case .file(let fileURL):
                return try await transport.upload(request, fromFile: fileURL, trust: trustDelegate, progress: progress)
            }
        } catch {
            let error = namingCertificateRejection(error, since: rejections)
            reportAvailabilityFailure(for: error)
            throw error
        }
    }

    // MARK: - Failure observation

    nonisolated func setResponseFailureObserver(
        _ observer: APIClientResponseFailureObserver?
    ) {
        responseFailureObserverBox.set(observer)
    }

    /// Attach the device-key auth session used for bearer tokens and 401 refresh.
    /// Nonisolated so callers on other actors can wire it without an await.
    nonisolated func attachAuthSession(_ session: DeviceAuthSession?) {
        authSessionBox.set(session)
    }

    func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if let parsed = try? JSONDecoder().decode(ServerError.self, from: data) {
                if let rawCode = parsed.code,
                   !rawCode.isEmpty {
                    let error = APIError.codedServer(
                        status: http.statusCode,
                        message: parsed.error,
                        code: rawCode
                    )
                    // The response-failure observer fail-closes the transport, so it
                    // may only fire for terminal credential rejection (401 after
                    // performAuthorized spent its single refresh retry). Coded
                    // application errors such as 409 revision_conflict CAS failures
                    // and agent launch rejections stay ordinary API errors.
                    if http.statusCode == 401 {
                        responseFailureObserverBox.notify(error)
                    }
                    throw error
                }
                throw APIError.server(status: http.statusCode, message: parsed.error)
            }
            if http.statusCode == 401 {
                let error = APIError.server(status: http.statusCode, message: body)
                responseFailureObserverBox.notify(error)
                throw error
            }
            throw APIError.server(status: http.statusCode, message: body)
        }
    }

    /// The server's error body: `{ "error": …, "code"?: … }`.
    struct ServerError: Decodable {
        let error: String
        let code: String?
    }
}
