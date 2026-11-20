import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "APIClient")

// MARK: - Pairing and paired devices

extension APIClient {
    /// Exchange a one-time pairing token for a device-key credential.
    /// The server registers `devicePublicKey` and returns a short-lived access
    /// token, not a long-lived bearer. A 202 means another device must approve.
    func pairDevice(
        pairingToken: String,
        deviceName: String? = nil,
        devicePublicKey: DevicePublicKey
    ) async throws -> PairDeviceResponse {
        switch try await startPairDevice(
            pairingToken: pairingToken,
            deviceName: deviceName,
            devicePublicKey: devicePublicKey
        ) {
        case .enrolled(let response):
            return response
        case .approvalRequired:
            throw APIError.server(status: 202, message: "approval_required")
        }
    }

    func startPairDevice(
        pairingToken: String,
        deviceName: String? = nil,
        devicePublicKey: DevicePublicKey
    ) async throws -> PairDeviceStart {
        let body = PairDeviceRequest(
            pairingToken: pairingToken,
            deviceName: deviceName,
            devicePublicKey: devicePublicKey
        )
        let (data, response) = try await requestNoAuth("POST", path: "/pair", body: body)
        return try decodePairDeviceStart(data: data, response: response)
    }

    func pollPairingApprovalStatus(
        approvalId: String,
        pendingToken: String
    ) async throws -> PairingApprovalPoll {
        struct Body: Encodable {
            let approvalId: String
            let pendingToken: String
        }
        let (data, response) = try await requestNoAuth(
            "POST",
            path: "/pair/approval-status",
            body: Body(approvalId: approvalId, pendingToken: pendingToken)
        )
        return try decodePairingApprovalPoll(data: data, response: response)
    }

    func listPairingApprovals() async throws -> [PendingPairingApproval] {
        try await get("/auth/pairing-approvals", as: PairingApprovalListResponse.self).approvals
    }

    func approvePairingApproval(id: String, signature: String) async throws {
        struct Body: Encodable {
            let signature: String
        }
        let encodedId = try percentEncodePathSegment(id)
        _ = try await post(
            "/auth/pairing-approvals/\(encodedId)/approve",
            body: Body(signature: signature)
        )
    }

    func denyPairingApproval(id: String) async throws {
        let encodedId = try percentEncodePathSegment(id)
        _ = try await post(
            "/auth/pairing-approvals/\(encodedId)/deny",
            body: EmptyBody()
        )
    }

    private func decodePairDeviceStart(data: Data, response: URLResponse) throws -> PairDeviceStart {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            return .enrolled(try JSONDecoder().decode(PairDeviceResponse.self, from: data))
        case 202:
            let required = try JSONDecoder().decode(PairingApprovalRequired.self, from: data)
            guard required.status == "approval_required",
                  !required.approvalId.isEmpty,
                  !required.pendingToken.isEmpty else {
                throw APIError.invalidResponse
            }
            return .approvalRequired(required)
        default:
            try checkStatus(response, data: data)
            throw APIError.invalidResponse
        }
    }

    private func decodePairingApprovalPoll(data: Data, response: URLResponse) throws -> PairingApprovalPoll {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            return .enrolled(try JSONDecoder().decode(PairDeviceResponse.self, from: data))
        case 202:
            let pending = try JSONDecoder().decode(PairingApprovalPendingStatus.self, from: data)
            guard pending.status == "pending" else {
                throw APIError.invalidResponse
            }
            return .pending(expiresAt: pending.expiresAt)
        default:
            try checkStatus(response, data: data)
            throw APIError.invalidResponse
        }
    }

    /// Mint a same-Tailscale-user pairing invite. Auth is the TCP whois check
    /// on the server; do not send owner `sk_`.
    func issueTailscalePairingInvite() async throws -> TailscalePairingInvite {
        let (data, response) = try await requestNoAuth(
            "POST",
            path: "/pair/tailscale",
            body: EmptyBody()
        )
        try checkStatus(response, data: data)
        return try JSONDecoder().decode(TailscalePairingInvite.self, from: data)
    }

    private func requestNoAuth<T: Encodable>(_ method: String, path: String, body: T) async throws -> (Data, URLResponse) {
        var req = try URLRequest(url: makeURL(path: path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        logger.debug("\(method) \(path) [no-auth]")
        return try await performData(for: req)
    }

    /// Get authenticated user info.
    func me() async throws -> User {
        try await get("/me", as: User.self)
    }

    /// List paired devices for this server. Includes revoked rows.
    func listAuthDevices() async throws -> [AuthDevice] {
        try await get("/auth/devices", as: AuthDeviceListResponse.self).devices
    }

    /// Revoke a paired device. Its access tokens are invalidated immediately.
    func revokeAuthDevice(id: String) async throws {
        _ = try await delete("/auth/devices/\(id)")
    }
}

// MARK: - DeviceAuthTransport

/// `APIClient` is the challenge/refresh transport for its server. These calls are
/// unauthenticated (they carry their own proof) and never embed credentials in URLs.
extension APIClient: DeviceAuthTransport {
    /// Build a challenge/refresh request body. These endpoints carry their own
    /// device-key proof and are unauthenticated on the network listener, so they
    /// must NEVER consult the attached auth session: doing so re-enters
    /// `DeviceAuthSession.refreshAccessToken()` from inside its own in-flight
    /// refresh and deadlocks. Use only the statically captured bearer.
    private func deviceAuthRequest<T: Encodable>(_ method: String, path: String, body: T) async throws -> (Data, URLResponse) {
        var req = try URLRequest(url: makeURL(path: path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        if !token.isEmpty {
            ServerAuthorization.apply(token: token, to: &req)
        }
        return try await performData(for: req)
    }

    func requestChallenge(deviceId: String) async throws -> DeviceAuthChallenge {
        struct Body: Encodable { let deviceId: String }
        let (data, response) = try await deviceAuthRequest(
            "POST",
            path: "/auth/challenge",
            body: Body(deviceId: deviceId)
        )
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DeviceAuthError.challengeUnavailable
        }
        guard let challenge = try? JSONDecoder().decode(DeviceAuthChallenge.self, from: data) else {
            throw DeviceAuthError.malformedResponse
        }
        return challenge
    }

    func refresh(
        deviceId: String,
        nonce: String,
        signature: String
    ) async throws -> DeviceAuthRefreshResult {
        struct Body: Encodable {
            let deviceId: String
            let nonce: String
            let signature: String
        }
        struct RefreshResponse: Decodable {
            let accessToken: String
            let expiresAt: Int
            let refreshChallenge: DeviceAuthChallenge?
        }
        let (data, response) = try await deviceAuthRequest(
            "POST",
            path: "/auth/refresh",
            body: Body(
                deviceId: deviceId,
                nonce: nonce,
                signature: signature
            )
        )
        guard let http = response as? HTTPURLResponse else {
            throw DeviceAuthError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(ServerError.self, from: data).error) ?? "refresh_failed"
            throw DeviceAuthError.refreshRejected(code: code)
        }
        guard let decoded = try? JSONDecoder().decode(RefreshResponse.self, from: data) else {
            throw DeviceAuthError.malformedResponse
        }
        return DeviceAuthRefreshResult(
            accessToken: decoded.accessToken,
            expiresAt: decoded.expiresAt,
            refreshChallenge: decoded.refreshChallenge
        )
    }
}
