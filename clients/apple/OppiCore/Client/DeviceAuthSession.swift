import Foundation

/// Server-issued refresh challenge. `nonce` is single-use; `audience` is the
/// fixed refresh context the signature covers.
public struct DeviceAuthChallenge: Codable, Sendable, Equatable, Hashable {
    public let nonce: String
    public let audience: String
    public let expiresAt: Int

    public init(nonce: String, audience: String, expiresAt: Int) {
        self.nonce = nonce
        self.audience = audience
        self.expiresAt = expiresAt
    }
}

/// Result of a successful refresh. The replacement access token plus an
/// optional next challenge the client should cache for the following refresh.
public struct DeviceAuthRefreshResult: Sendable, Equatable {
    public let accessToken: String
    public let expiresAt: Int
    public let refreshChallenge: DeviceAuthChallenge?

    public init(accessToken: String, expiresAt: Int, refreshChallenge: DeviceAuthChallenge?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshChallenge = refreshChallenge
    }
}

/// Typed failures from the device-auth HTTP surface.
public enum DeviceAuthError: Error, Sendable, Equatable {
    case challengeUnavailable
    case refreshRejected(code: String)
    case malformedResponse

    /// Nonce failures that a retry with a fresh challenge can recover from
    /// (lost response, server restart clearing in-memory nonces, expiry).
    static let retryableCodes: Set<String> = ["unknown_nonce", "nonce_reused", "nonce_expired"]
}

/// Transport for device-auth REST calls. Implementations must POST bodies and
/// never place credentials in URLs or query strings.
public protocol DeviceAuthTransport: Sendable {
    func requestChallenge(deviceId: String) async throws -> DeviceAuthChallenge
    func refresh(
        deviceId: String,
        nonce: String,
        signature: String
    ) async throws -> DeviceAuthRefreshResult
}

/// Owns a device's access-token lifecycle: single-flight refresh, challenge
/// signing, clock-skew-aware expiry, and one retry on a stale nonce.
///
/// Credentials are held in-memory and passed via request bodies only.
public actor DeviceAuthSession {
    public static let refreshAudience = "oppi:refresh:v1"

    private let deviceId: String
    private let key: DeviceKey
    private let transport: any DeviceAuthTransport
    private let clock: @Sendable () -> Date
    private let skew: TimeInterval

    public private(set) var accessToken: String
    public private(set) var expiresAt: Date
    private var refreshChallenge: DeviceAuthChallenge?

    private var inFlightRefresh: Task<String, Error>?
    /// Invoked after a successful refresh so the connection layer can persist
    /// the replacement credential. Never called with secret-free failures.
    private let onRefresh: (@Sendable (DeviceAuthRefreshResult) -> Void)?

    /// Task-local re-entrancy marker. Set while the in-flight refresh task runs
    /// so a transport that mistakenly re-enters `refreshAccessToken()` (for
    /// example by asking the attached session for its own bearer) fails fast
    /// instead of awaiting its own result — a guaranteed deadlock.
    @TaskLocal private static var isRefreshing = false

    public init(
        deviceId: String,
        key: DeviceKey,
        accessToken: String,
        expiresAt: Date,
        refreshChallenge: DeviceAuthChallenge? = nil,
        transport: any DeviceAuthTransport,
        clock: @escaping @Sendable () -> Date = { Date() },
        skew: TimeInterval = 30,
        onRefresh: (@Sendable (DeviceAuthRefreshResult) -> Void)? = nil
    ) {
        self.deviceId = deviceId
        self.key = key
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshChallenge = refreshChallenge
        self.transport = transport
        self.clock = clock
        self.skew = skew
        self.onRefresh = onRefresh
    }

    /// Prefer a freshly resolved device-key token. An empty resolution must not
    /// wipe a still-valid leftover or static bearer.
    public static func resolvedToken(_ resolved: String?, fallback: String) -> String {
        if let resolved, !resolved.isEmpty { return resolved }
        return fallback
    }

    /// Return a usable access token, refreshing single-flight when near expiry
    /// or when the cached token is empty.
    public func currentAccessToken() async throws -> String {
        if !accessToken.isEmpty, clock().addingTimeInterval(skew) < expiresAt {
            return accessToken
        }
        return try await refreshAccessToken()
    }

    /// Refresh the access token, coalescing concurrent callers into one exchange.
    public func refreshAccessToken() async throws -> String {
        if let inFlightRefresh {
            // Re-entrancy guard: awaiting our own in-flight task would deadlock.
            if Self.isRefreshing {
                throw DeviceAuthError.refreshRejected(code: "reentrant_refresh")
            }
            return try await inFlightRefresh.value
        }

        let task = Task<String, Error> {
            try await Self.$isRefreshing.withValue(true) {
                try await self.performRefresh()
            }
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> String {
        // Prefer a cached challenge; otherwise fetch one. The server expresses
        // challenge expiry in epoch milliseconds, the client clock in seconds.
        var challenge: DeviceAuthChallenge
        if let cached = refreshChallenge,
           Double(cached.expiresAt) > clock().timeIntervalSince1970 * 1_000 {
            challenge = cached
        } else if let fetched = try? await transport.requestChallenge(deviceId: deviceId) {
            challenge = fetched
        } else {
            throw DeviceAuthError.challengeUnavailable
        }

        let result: DeviceAuthRefreshResult
        do {
            result = try await transport.refresh(
                deviceId: deviceId,
                nonce: challenge.nonce,
                signature: try Self.sign(challenge: challenge, key: key)
            )
        } catch let error as DeviceAuthError {
            guard case .refreshRejected(let code) = error,
                  DeviceAuthError.retryableCodes.contains(code) else {
                throw error
            }
            // Stale/consumed/expired nonce: clear the cached challenge and retry once.
            refreshChallenge = nil
            let fresh = try await transport.requestChallenge(deviceId: deviceId)
            result = try await transport.refresh(
                deviceId: deviceId,
                nonce: fresh.nonce,
                signature: try Self.sign(challenge: fresh, key: key)
            )
        }

        accessToken = result.accessToken
        expiresAt = Date(timeIntervalSince1970: TimeInterval(result.expiresAt / 1_000))
        refreshChallenge = result.refreshChallenge
        onRefresh?(result)
        return result.accessToken
    }

    /// Initializer from a persisted `DeviceCredential`.
    public init(
        credential: DeviceCredential,
        key: DeviceKey,
        transport: any DeviceAuthTransport,
        accessToken: String? = nil,
        expiresAtMs: Int64? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        skew: TimeInterval = 30,
        onRefresh: (@Sendable (DeviceAuthRefreshResult) -> Void)? = nil
    ) {
        self.init(
            deviceId: credential.deviceId,
            key: key,
            accessToken: accessToken ?? credential.accessToken,
            expiresAt: Date(timeIntervalSince1970: TimeInterval((expiresAtMs ?? credential.expiresAt) / 1000)),
            refreshChallenge: credential.refreshChallenge,
            transport: transport,
            clock: clock,
            skew: skew,
            onRefresh: onRefresh
        )
    }

    /// Sign the challenge input `audience.nonce` (SHA-256 via CryptoKit), returning
    /// the raw 64-byte signature as unpadded base64url.
    static func sign(challenge: DeviceAuthChallenge, key: DeviceKey) throws -> String {
        let input = Data("\(challenge.audience).\(challenge.nonce)".utf8)
        return DeviceKeyBase64.encode(try key.sign(input))
    }
}
