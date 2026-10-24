import Foundation
import OSLog

private let pairingLogger = Logger(subsystem: AppIdentifiers.subsystem, category: "Pairing")

struct InviteBootstrapResult {
    let effectiveCredentials: ServerCredentials
    let sessions: [Session]
}

/// A pairing the server committed and Oppi saved.
struct InviteEnrollment {
    let name: String
    /// False when a newer pairing attempt or server pick took the selection.
    let selected: Bool
    /// The sessions read while pairing, for the caller to show when selected.
    let sessions: [Session]
}

/// What the person can do after pairing failed.
enum PairingRecovery: Equatable, Sendable {
    /// The pairing code was used, expired, refused, or unsigned, or it may
    /// have been used (its response was lost). Only a new code helps.
    case newCode
    /// The server did not answer before the code was sent, so the same code
    /// still works once the server is reachable.
    case reachability
    /// The address or certificate cannot work from this device. The server's
    /// setup must change first.
    case serverSetup
    /// Nothing reached the server (the trust prompt was declined). The same
    /// code works again.
    case retry
}

/// Why a code cannot be used again, for a screen that words it with its own
/// next step (onboarding). Other screens show `InviteBootstrapError.message`.
enum PairingCodeProblem: Equatable, Sendable {
    case expiredOrUsed
    case tooManyAttempts
    case denied
    /// The approval request expired or the server no longer knows it.
    case approvalEnded
    case lostContactDuringApproval
    case cancelled
    /// The server may have paired this device, but its answer never arrived.
    case responseLost
    /// No signed server identity, so Oppi cannot tell which server this is.
    case unsigned
    /// The server answered pairing with something Oppi cannot use.
    case invalidResponse
    /// Pairing failed without a reason to show.
    case unexplained
}

/// A pairing failure: the message to show and what the person can do next.
struct InviteBootstrapError: LocalizedError, Equatable {
    let message: String
    let recovery: PairingRecovery
    var codeProblem: PairingCodeProblem?

    init(message: String, recovery: PairingRecovery, codeProblem: PairingCodeProblem? = nil) {
        self.message = message
        self.recovery = recovery
        self.codeProblem = codeProblem
    }

    var errorDescription: String? { message }
}

protocol InviteBootstrapAPI: Sendable {
    func startPairDevice(
        pairingToken: String,
        deviceName: String?,
        devicePublicKey: DevicePublicKey
    ) async throws -> PairDeviceStart
    func pollPairingApprovalStatus(
        approvalId: String,
        pendingToken: String
    ) async throws -> PairingApprovalPoll
    func health() async throws -> Bool
    func me() async throws -> User
    func listSessionsFromWorkspaces(recentDays: Int) async throws -> [Session]
    func revokeAuthDevice(id: String) async throws
}

extension APIClient: InviteBootstrapAPI {}

@MainActor
enum InviteBootstrapService {
    static func credentials(from inviteURL: URL) -> ServerCredentials? {
        ServerCredentials.decodeInviteURL(inviteURL)
    }

    static func validateAndBootstrap(
        credentials: ServerCredentials,
        existingCredentials: ServerCredentials?,
        confirmTrust: @MainActor (String) async -> Bool,
        apiFactory: @MainActor (URL, String, String?) -> any InviteBootstrapAPI = { baseURL, token, tlsCertFingerprint in
            APIClient(baseURL: baseURL, token: token, tlsCertFingerprint: tlsCertFingerprint)
        },
        deviceName: String? = PairingDeviceName.current(),
        deviceKeyProvider: @MainActor () throws -> any DeviceKey = {
            try DeviceKeyProvider.shared.loadOrCreate()
        },
        /// The approval wait's expiry while another device must approve, then `nil`
        /// once the server enrolled this device: the wait and its Cancel end there.
        onWaitingForApproval: (@MainActor (Int64?) -> Void)? = nil,
        /// The wait between approval polls; tests skip the real two-second interval.
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> InviteBootstrapResult {
        // A server is saved under its signed identity. Without one Oppi cannot
        // tell which server it pairs or warn when a known one changed, so an
        // unsigned payload (QR, link, or paste) is refused before anything is sent.
        guard let inviteFingerprint = credentials.normalizedServerFingerprint else {
            throw unsignedFailure
        }
        guard credentials.resolvedScheme == .https, let baseURL = credentials.baseURL else {
            throw InviteBootstrapError(
                message: "HTTPS is required. Ask the server owner for an HTTPS/Tailscale invite.",
                recovery: .serverSetup
            )
        }
        if credentials.normalizedTLSCertFingerprint != nil,
           !ServerTLSTrustPolicy.allowsPinnedLeaf(forHost: credentials.host) {
            throw InviteBootstrapError(
                message: "\(credentials.host) uses a self-signed certificate, which iOS does not allow on Tailscale names. "
                    + "On the server, run `oppi config set tls.mode tailscale`, restart, and create a new invite.",
                recovery: .serverSetup
            )
        }
        let existingFingerprint = existingCredentials?.normalizedServerFingerprint
        let reason = existingFingerprint != nil && existingFingerprint != inviteFingerprint
            ? "Server identity changed for \(displayTarget(credentials)). Confirm trust reset."
            : "Trust \(displayTarget(credentials)) (\(shortFingerprint(inviteFingerprint)))"
        guard await confirmTrust(reason) else {
            throw InviteBootstrapError(message: "Trust confirmation cancelled", recovery: .retry)
        }

        let api: any InviteBootstrapAPI
        if let pairingToken = credentials.pairingToken, !pairingToken.isEmpty {
            let bootstrapAPI = apiFactory(baseURL, credentials.token, credentials.normalizedTLSCertFingerprint)
            try await requireReachable(bootstrapAPI, host: displayTarget(credentials))
            let pairResult: PairDeviceResponse
            var didRequireApproval = false
            do {
                let start = try await bootstrapAPI.startPairDevice(
                    pairingToken: pairingToken,
                    deviceName: PairingDeviceName.resolved(deviceName),
                    devicePublicKey: try deviceKeyProvider().publicKey
                )
                if case .approvalRequired(let required) = start {
                    didRequireApproval = true
                    onWaitingForApproval?(required.expiresAt)
                }
                pairResult = try await PairingEnrollment.complete(
                    start: start,
                    poll: { approvalId, pendingToken in
                        try await bootstrapAPI.pollPairingApprovalStatus(
                            approvalId: approvalId,
                            pendingToken: pendingToken
                        )
                    },
                    onWaiting: { expiresAt in
                        onWaitingForApproval?(expiresAt)
                    },
                    sleep: sleep
                )
                if Task.isCancelled {
                    if let deviceCredential = pairResult.deviceCredential {
                        revokeAbandonedEnrollment(
                            deviceId: deviceCredential.deviceId,
                            using: apiFactory(
                                baseURL,
                                deviceCredential.accessToken,
                                credentials.normalizedTLSCertFingerprint
                            )
                        )
                    }
                    throw PairingEnrollment.Failure.cancelled
                }
                if didRequireApproval { onWaitingForApproval?(nil) }
            } catch {
                throw pairingMutationFailure(
                    for: error,
                    host: displayTarget(credentials),
                    didRequireApproval: didRequireApproval
                )
            }
            guard let deviceCredential = pairResult.deviceCredential else {
                throw invalidResponseFailure
            }
            let effective = credentials.withDeviceCredential(deviceCredential)
            let pairedAPI = apiFactory(baseURL, deviceCredential.accessToken, credentials.normalizedTLSCertFingerprint)
            let sessions: [Session]
            do {
                sessions = try await bootstrapSessions(using: pairedAPI)
            } catch let error as InviteBootstrapError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The server took the code, so another attempt needs a new one.
                throw InviteBootstrapError(
                    message: pairingFailure(for: error, host: displayTarget(credentials)).message,
                    recovery: .newCode
                )
            }
            return InviteBootstrapResult(effectiveCredentials: effective, sessions: sessions)
        }

        api = apiFactory(baseURL, credentials.effectiveAccessToken, credentials.normalizedTLSCertFingerprint)
        let sessions = try await bootstrapSessions(using: api)
        return InviteBootstrapResult(effectiveCredentials: credentials, sessions: sessions)
    }

    static let unsignedFailure = InviteBootstrapError(
        message: "This pairing code is not signed by an Oppi server, so Oppi cannot verify it. Run `oppi pair` on the server for a new one.",
        recovery: .newCode,
        codeProblem: .unsigned
    )

    static let invalidResponseFailure = InviteBootstrapError(
        message: PairingEnrollment.Failure.invalidResponseMessage,
        recovery: .newCode,
        codeProblem: .invalidResponse
    )

    /// Reaches the server before the single-use code goes out, so a network
    /// or certificate failure leaves the code usable and says so.
    private static func requireReachable(_ api: any InviteBootstrapAPI, host: String) async throws {
        let healthy: Bool
        do {
            healthy = try await api.health()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = pairingFailure(for: error, host: host)
            // Nothing was sent, so no failure here spends the code.
            throw InviteBootstrapError(
                message: failure.message,
                recovery: failure.recovery == .newCode ? .retry : failure.recovery
            )
        }
        guard healthy else {
            throw InviteBootstrapError(
                message: "\(host) answered, but not as an Oppi server. Check the address and port.",
                recovery: .serverSetup
            )
        }
    }

    /// Cancel landed as the server enrolled this device, so the phone keeps no
    /// credential. Revoke the device with its own just-issued bearer so it does
    /// not stay in Paired Devices. Best effort: runs outside the cancelled task,
    /// and a failure is only logged. A Cancel while the poll request is in
    /// flight never sees the credential and still leaves the device enrolled.
    static func revokeAbandonedEnrollment(deviceId: String, using api: any InviteBootstrapAPI) {
        Task {
            do {
                try await api.revokeAuthDevice(id: deviceId)
                pairingLogger.notice("Revoked the device enrolled as pairing was cancelled")
            } catch {
                pairingLogger.error(
                    "Revoking the device enrolled as pairing was cancelled failed: \(String(describing: type(of: error)), privacy: .public)"
                )
            }
        }
    }

    private static func bootstrapSessions(using api: any InviteBootstrapAPI) async throws -> [Session] {
        guard try await api.health() else {
            throw InviteBootstrapError(message: "Server is not healthy", recovery: .newCode)
        }
        _ = try await api.me()
        return try await api.listSessionsFromWorkspaces(recentDays: 3)
    }

    /// A failure while the server held the code: after `requireReachable`, so
    /// a lost response may mean the server already took it.
    private static func pairingMutationFailure(
        for error: Error,
        host: String,
        didRequireApproval: Bool = false
    ) -> InviteBootstrapError {
        if didRequireApproval {
            let failure = PairingEnrollment.Failure.classify(error)
            return InviteBootstrapError(
                message: failure.errorDescription
                    ?? PairingEnrollment.Failure.disconnected.errorDescription
                    ?? "Lost contact while waiting for approval. Request a fresh invite and try again.",
                recovery: .newCode,
                codeProblem: codeProblem(for: failure)
            )
        }
        if APIClientAvailabilityFailure(error: error) != nil {
            return InviteBootstrapError(
                message: "Pairing may have completed, but its response was lost. Open Oppi to check, or request a fresh invite before trying again.",
                recovery: .newCode,
                codeProblem: .responseLost
            )
        }
        return pairingFailure(for: error, host: host)
    }

    private static func codeProblem(for failure: PairingEnrollment.Failure) -> PairingCodeProblem? {
        switch failure {
        case .denied: .denied
        case .expired, .unknownApproval: .approvalEnded
        case .disconnected: .lostContactDuringApproval
        case .cancelled: .cancelled
        case .server(let message):
            message == PairingEnrollment.Failure.invalidResponseMessage ? .invalidResponse : nil
        }
    }

    static func pairingFailureMessage(for error: Error, host: String) -> String {
        pairingFailure(for: error, host: host).message
    }

    static func pairingFailure(for error: Error, host: String) -> InviteBootstrapError {
        if let failure = error as? InviteBootstrapError {
            return failure
        }
        if let failure = error as? PairingEnrollment.Failure {
            return InviteBootstrapError(
                message: failure.errorDescription ?? "Pairing failed. Request a fresh invite and try again.",
                recovery: .newCode,
                codeProblem: failure.errorDescription == nil ? .unexplained : codeProblem(for: failure)
            )
        }
        if let apiError = error as? APIError {
            switch apiError {
            case .invalidResponse:
                return invalidResponseFailure
            case .server(401, let message) where message.localizedCaseInsensitiveContains("invalid or expired pairing token"):
                return InviteBootstrapError(
                    message: "Invite link expired or was already used. Request a fresh invite.",
                    recovery: .newCode,
                    codeProblem: .expiredOrUsed
                )
            case .server(429, _):
                return InviteBootstrapError(
                    message: "Too many invalid pairing attempts. Wait a moment, request a fresh invite, and try again.",
                    recovery: .newCode,
                    codeProblem: .tooManyAttempts
                )
            case .server(let status, let message), .codedServer(let status, let message, _):
                return InviteBootstrapError(
                    message: "Pairing failed with server error (\(status)): \(message)",
                    recovery: .newCode
                )
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed, .cannotLoadFromNetwork:
                return InviteBootstrapError(
                    message: "Could not reach \(host). Check the address, VPN, or network and try again.",
                    recovery: .reachability
                )
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .serverCertificateUntrusted, .clientCertificateRejected, .clientCertificateRequired:
                return InviteBootstrapError(
                    message: "Secure connection to \(host) failed. Verify the invite host and certificate, then try again.",
                    recovery: .serverSetup
                )
            default: break
            }
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return InviteBootstrapError(
                message: "Pairing failed. Request a fresh invite and try again.",
                recovery: .newCode,
                codeProblem: .unexplained
            )
        }
        return InviteBootstrapError(message: "Pairing failed: \(message)", recovery: .newCode)
    }

    private static func displayTarget(_ credentials: ServerCredentials) -> String {
        credentials.host.isEmpty ? credentials.name : credentials.host
    }

    private static func shortFingerprint(_ fingerprint: String) -> String {
        fingerprint.count > 24 ? String(fingerprint.prefix(24)) + "…" : fingerprint
    }

    /// Turns an already-minted invite URL into a selected paired server.
    /// Tailscale same-user pairing and SSH pairing both stop here. Sends one
    /// `/pair`. Does not log the invite.
    @MainActor
    static func enroll(
        inviteURL: String,
        serverStore: ServerStore,
        coordinator: ConnectionCoordinator,
        onWaitingForApproval: (@MainActor (Int64?) -> Void)? = nil,
        confirmTrust: @MainActor (String) async -> Bool
    ) async throws -> InviteEnrollment {
        guard let credentials = ServerCredentials.decodeInviteURLString(inviteURL) else {
            throw InviteBootstrapError(
                message: "The pairing invite was not usable. Request a fresh one and try again.",
                recovery: .newCode
            )
        }
        return try await enroll(
            credentials: credentials,
            serverStore: serverStore,
            coordinator: coordinator,
            onWaitingForApproval: onWaitingForApproval,
            confirmTrust: confirmTrust
        )
    }

    /// The one pair-then-save path: QR, pasted links, `oppi://` invite links,
    /// Tailscale, and SSH all pair here, so each one warns when a known
    /// server's identity changed. The seams exist for tests.
    @MainActor
    static func enroll(
        credentials: ServerCredentials,
        serverStore: ServerStore,
        coordinator: ConnectionCoordinator,
        onWaitingForApproval: (@MainActor (Int64?) -> Void)? = nil,
        confirmTrust: @MainActor (String) async -> Bool,
        apiFactory: @MainActor (URL, String, String?) -> any InviteBootstrapAPI = { baseURL, token, tlsCertFingerprint in
            APIClient(baseURL: baseURL, token: token, tlsCertFingerprint: tlsCertFingerprint)
        },
        deviceKeyProvider: @MainActor () throws -> any DeviceKey = {
            try DeviceKeyProvider.shared.loadOrCreate()
        },
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> InviteEnrollment {
        try await save(credentials: credentials, serverStore: serverStore, coordinator: coordinator) { existing in
            try await validateAndBootstrap(
                credentials: credentials,
                existingCredentials: existing,
                confirmTrust: confirmTrust,
                apiFactory: apiFactory,
                deviceKeyProvider: deviceKeyProvider,
                onWaitingForApproval: onWaitingForApproval,
                sleep: sleep
            )
        }
    }

    /// Pairs through `bootstrap`, given the saved credentials for this server
    /// (by fingerprint, else host and port), then saves the result. Cancelling
    /// the task before the save keeps the pairing out of the store.
    @MainActor
    fileprivate static func save(
        credentials: ServerCredentials,
        serverStore: ServerStore,
        coordinator: ConnectionCoordinator,
        bootstrap: @MainActor (_ existing: ServerCredentials?) async throws -> InviteBootstrapResult
    ) async throws -> InviteEnrollment {
        let existing = credentials.normalizedServerFingerprint.flatMap {
            serverStore.server(for: $0)?.credentials
        } ?? serverStore.server(forHost: credentials.host, port: credentials.port)?.credentials
        let attempt = coordinator.beginPairingAttempt()
        let result = try await bootstrap(existing)
        if Task.isCancelled { throw PairingEnrollment.Failure.cancelled }
        guard let pairedServer = PairedServer(
            from: result.effectiveCredentials,
            sortOrder: serverStore.servers.count
        ) else {
            throw InviteBootstrapError(message: "Missing server fingerprint", recovery: .newCode)
        }
        // Committed: the server enrolled this device and the wait (with its
        // Cancel) has ended. A newer attempt only takes the selection.
        let outcome = await coordinator.addEnrolledServer(pairedServer, attempt: attempt)
        guard outcome != .failed else {
            throw InviteBootstrapError(message: "Connection blocked by server transport policy", recovery: .serverSetup)
        }
        return InviteEnrollment(
            name: pairedServer.name,
            selected: outcome == .selected,
            sessions: result.sessions
        )
    }
}

#if DEBUG
/// Apple E2E must pair with a real P-256 DeviceAuthSession. The harness script
/// `at_` is for XCTest lab API only and cannot refresh inside the app.
@MainActor
enum E2EAppAuthBootstrap {
    /// Launch-invite pairing for E2E: reuses a matching pairing, else pairs
    /// without the trust prompt, then saves like every other path.
    static func enroll(
        credentials: ServerCredentials,
        serverStore: ServerStore,
        coordinator: ConnectionCoordinator
    ) async throws -> InviteEnrollment {
        try await InviteBootstrapService.save(
            credentials: credentials,
            serverStore: serverStore,
            coordinator: coordinator
        ) { existing in
            if shouldReuseExistingPairing(existing: existing, invite: credentials), let existing {
                return InviteBootstrapResult(effectiveCredentials: existing, sessions: [])
            }
            return try await pairInvite(credentials: credentials)
        }
    }

    static func shouldPreserveServer(_ server: PairedServer, matching invite: ServerCredentials) -> Bool {
        shouldReuseExistingPairing(existing: server.credentials, invite: invite)
    }

    static func shouldReuseExistingPairing(
        existing: ServerCredentials?,
        invite: ServerCredentials
    ) -> Bool {
        guard let existing,
              existing.deviceCredential != nil,
              let existingFingerprint = existing.normalizedServerFingerprint,
              let inviteFingerprint = invite.normalizedServerFingerprint,
              existingFingerprint == inviteFingerprint,
              existing.host == invite.host,
              existing.port == invite.port else {
            return false
        }
        return true
    }

    static func pairInvite(
        credentials: ServerCredentials,
        deviceKeyProvider: () throws -> any DeviceKey = {
            try DeviceKeyProvider.shared.loadOrCreate()
        },
        apiFactory: (URL, String, String?) -> any InviteBootstrapAPI = { baseURL, token, tlsCertFingerprint in
            APIClient(baseURL: baseURL, token: token, tlsCertFingerprint: tlsCertFingerprint)
        }
    ) async throws -> InviteBootstrapResult {
        // The same signed-identity rule as `validateAndBootstrap`, before anything is sent.
        guard credentials.normalizedServerFingerprint != nil else {
            throw InviteBootstrapService.unsignedFailure
        }
        guard let pairingToken = credentials.pairingToken, !pairingToken.isEmpty else {
            throw InviteBootstrapError(message: "E2E invite is missing a pairing token", recovery: .newCode)
        }
        guard let baseURL = credentials.baseURL else {
            throw InviteBootstrapError(message: "Invalid E2E invite URL", recovery: .serverSetup)
        }
        let pairingAPI = apiFactory(baseURL, "", credentials.normalizedTLSCertFingerprint)
        let pairResult: PairDeviceResponse
        do {
            let start = try await pairingAPI.startPairDevice(
                pairingToken: pairingToken,
                deviceName: PairingDeviceName.current(),
                devicePublicKey: try deviceKeyProvider().publicKey
            )
            pairResult = try await PairingEnrollment.complete(
                start: start,
                poll: { approvalId, pendingToken in
                    try await pairingAPI.pollPairingApprovalStatus(
                        approvalId: approvalId,
                        pendingToken: pendingToken
                    )
                }
            )
            if Task.isCancelled {
                if let deviceCredential = pairResult.deviceCredential {
                    InviteBootstrapService.revokeAbandonedEnrollment(
                        deviceId: deviceCredential.deviceId,
                        using: apiFactory(
                            baseURL,
                            deviceCredential.accessToken,
                            credentials.normalizedTLSCertFingerprint
                        )
                    )
                }
                throw PairingEnrollment.Failure.cancelled
            }
        } catch {
            throw InviteBootstrapService.pairingFailure(for: error, host: credentials.host)
        }
        guard let deviceCredential = pairResult.deviceCredential else {
            throw InviteBootstrapService.invalidResponseFailure
        }
        let effective = credentials.withDeviceCredential(deviceCredential)
        let authed = apiFactory(
            baseURL,
            deviceCredential.accessToken,
            credentials.normalizedTLSCertFingerprint
        )
        let sessions = try await authed.listSessionsFromWorkspaces(recentDays: 3)
        return InviteBootstrapResult(effectiveCredentials: effective, sessions: sessions)
    }
}
#endif
