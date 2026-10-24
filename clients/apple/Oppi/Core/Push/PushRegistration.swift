import CryptoKit
import OSLog
import UIKit

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Push")

/// Opt-in, end-to-end-encrypted push for each paired server (protocol/push/spec.md).
///
/// The server advertises `capabilities.pushNotifications.relay` unless its operator set
/// `push.mode` to `off`, and the user turns on push for that server here (off by default). Then, once per connection, this:
///
/// 1. gets this device's APNs token and notification permission;
/// 2. registers the token with the relay, with App Attest when the device supports it;
/// 3. mints a send permission for this server at the relay, or reuses the one this phone
///    already gave the server (`PushSendTokenStore`);
/// 4. sends the server this device's X25519 push public key for that server and the send
///    token, signed by the device's pairing key;
/// 5. checks the server's Ed25519 key against the fingerprint pinned at pairing and stores
///    it with the private key for the Notification Service Extension.
///
/// The server also learns whether this phone shows its Live Activity (`LiveActivitySettings`),
/// so it knows whether to drive the card while Oppi is closed. Whether it can is the phone's
/// call alone: the phone keeps the send token and names its permission in the Live Activity
/// state it gives the relay (`LiveActivityRelaySync`), which lets no other permission drive a
/// card. Turning the card on or off re-sends the same token with the new setting; it mints
/// nothing.
///
/// The relay sees the APNs token, never a push key or push content.
@MainActor
final class PushRegistration {
    static let shared = PushRegistration()

    /// Push keys rotate at the first registration after this age.
    static let keyRotationInterval: TimeInterval = 30 * 86_400

    /// How long a registration waits for APNs to issue this device's token. A phone that
    /// cannot reach APNs never hears back.
    static let deviceTokenTimeout: Duration = .seconds(30)

    private var deviceToken: String?
    /// The relay registration being made, by `PushRelayRegistrationStore.account`.
    private var relayRegistrationTasks: [String: Task<PushRelayClient.Registration, any Error>] = [:]
    /// Registrations running, by `PushRelayRegistrationStore.account`: each may still mint on
    /// that relay's registration, so turning push off elsewhere must not delete it.
    private var registrationsInFlight: [String: Int] = [:]
    private var tokenWaiters: [UUID: CheckedContinuation<String?, Never>] = [:]

    #if DEBUG
    /// Replaces the registration a server's push capability starts.
    var _onRegisterForTesting: ((String?) -> Void)?
    /// Replaces `UIApplication.registerForRemoteNotifications()`.
    var _registerForRemoteNotificationsForTesting: (() -> Void)?
    #endif

    private init() {}

    // MARK: - Opt-in

    private static func optInKey(serverId: String) -> String {
        "\(AppIdentifiers.subsystem).push.enabled.\(serverId)"
    }

    /// The user turned on push for this server. Off by default.
    static func isEnabled(serverId: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: optInKey(serverId: serverId))
    }

    static func setEnabled(_ enabled: Bool, serverId: String, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: optInKey(serverId: serverId))
    }

    // MARK: - Registration

    /// The connection loaded a server that pushes through `relay`. Registers only when the user
    /// opted in for this server.
    func serverAdvertisesPush(api: APIClient, serverId: String?, deviceId: String?, relay: URL) {
        guard let serverId, Self.isEnabled(serverId: serverId) else { return }
        #if DEBUG
        if let onRegister = _onRegisterForTesting {
            onRegister(serverId)
            return
        }
        // Screenshot previews must not raise the system permission alert.
        if ScreenshotPreviewConfig.isEnabled { return }
        #endif
        guard let deviceId else { return }
        Task { await register(api: api, serverId: serverId, deviceId: deviceId, relay: relay) }
    }

    /// Why a registration failed, in the terms the person can act on.
    enum Failure: Equatable, Sendable {
        /// Notifications are not allowed for Oppi.
        case notificationsOff
        /// The relay is at a limit (`429`, or `503 relay_capacity` at its daily capacity): try
        /// again later.
        case relayBusy
        /// Anything else: the server or the relay refused, or could not be reached.
        case refused

        init(_ error: any Error) {
            switch error as? PushRelayClient.RelayError {
            case .rejected(429, _), .rejected(503, "relay_capacity"): self = .relayBusy
            default: self = .refused
            }
        }
    }

    /// Turns push on for a server, after the person agreed to the relay disclosure: marks the
    /// opt-in, registers, and on a failure leaves nothing behind (the send token, and a relay
    /// registration no other server uses; `disable` turns the opt-in off too). Nil once the
    /// server has this device's push key and send token. Registering asks iOS for notification
    /// permission when it has not been asked.
    ///
    /// The discovery card's Turn On runs this. Server Settings' switch runs the same three
    /// steps in `ServerNotificationsSection.turnPushOn`; switch it to this when Server Settings
    /// moves to UIKit.
    func enable(api: APIClient, serverId: String, deviceId: String, relay: URL) async -> Failure? {
        Self.setEnabled(true, serverId: serverId)
        let failure = await register(api: api, serverId: serverId, deviceId: deviceId, relay: relay)
        if failure != nil {
            await disable(serverId: serverId, api: api, relay: relay)
        }
        return failure
    }

    /// Nil once the server has this device's push key and send token.
    @discardableResult
    func register(api: APIClient, serverId: String, deviceId: String, relay: URL) async -> Failure? {
        let server = serverId.prefix(16)
        guard let environment = APNsEnvironment.current else {
            logger.error("Push registration skipped for server \(server, privacy: .public): no aps-environment")
            return .refused
        }
        guard let token = await currentDeviceToken() else { return .refused }
        // A denied permission keeps the token off the relay: it could only deliver alerts iOS
        // would not show.
        guard await AttentionNotificationService.shared.notificationsAuthorized() else { return .notificationsOff }
        Self.publishRedactionSnapshot()
        do {
            try await register(
                api: api,
                serverId: serverId,
                deviceId: deviceId,
                relay: relay,
                environment: environment,
                apnsToken: token,
                client: PushRelayClient(relay: relay)
            )
            logger.info("Push registered with server \(server, privacy: .public) (\(environment.rawValue, privacy: .public))")
            // Push works for this server, however it was turned on: the discovery card is done.
            PushDiscovery.close(serverId: serverId)
            return nil
        } catch {
            logger.error("Push registration failed for server \(server, privacy: .public): \(String(describing: error), privacy: .public)")
            return Failure(error)
        }
    }

    /// The relay this phone registered with for `serverId`, from the send token it gave the
    /// server; known while the server is offline.
    static func savedRelay(serverId: String) -> URL? {
        guard let sendToken = PushSendTokenStore.load(serverId: serverId)?.sendToken,
              let registrationId = PushRelayClient.permission(ofSendToken: sendToken)?.registrationId,
              let registration = PushRelayRegistrationStore.all().first(where: { $0.registrationId == registrationId })
        else { return nil }
        return URL(string: registration.relay)
    }

    func register(
        api: APIClient,
        serverId: String,
        deviceId: String,
        relay: URL,
        environment: APNsEnvironment,
        apnsToken: String,
        client: PushRelayClient
    ) async throws {
        do {
            try await register(
                api: api, serverId: serverId, deviceId: deviceId, relay: relay,
                environment: environment, apnsToken: apnsToken, client: client,
                replacing: nil, mayReplaceRelayRegistration: true, mayRecoverGoneSendToken: true
            )
        } catch PushRegistrationError.turnedOff {
            // The `disable` that turned push off counted this registration as running and
            // kept the relay registration for it. It has stopped now, so turn push off again:
            // that deletes the relay registration when no other server uses it.
            await disable(serverId: serverId, api: api, relay: relay, relayClient: { _ in client })
            throw PushRegistrationError.turnedOff
        }
    }

    /// `replacing`: a relay registration the relay refused. Each `may…` recovery runs at most
    /// once per registration.
    private func register(
        api: APIClient,
        serverId: String,
        deviceId: String,
        relay: URL,
        environment: APNsEnvironment,
        apnsToken: String,
        client: PushRelayClient,
        replacing refused: PushRelayClient.Registration?,
        mayReplaceRelayRegistration: Bool,
        mayRecoverGoneSendToken: Bool
    ) async throws {
        let account = PushRelayRegistrationStore.account(relay: relay, environment: environment)
        registrationsInFlight[account, default: 0] += 1
        defer {
            let remaining = (registrationsInFlight[account] ?? 1) - 1
            registrationsInFlight[account] = remaining > 0 ? remaining : nil
        }
        let registration = try await relayRegistration(
            relay: relay, environment: environment, apnsToken: apnsToken, client: client, replacing: refused
        )

        // Each connection re-sends the permission this phone already gave the server: minting
        // on every connection would leak one permission each time, and a full registration
        // takes every server's alerts down with it (below). A token is reused only on the
        // registration that holds it, for the pairing it went to: a revoked or re-paired
        // device's server released its token.
        let stored = PushSendTokenStore.load(serverId: serverId)
        let storedPermission = stored.flatMap { PushRelayClient.permission(ofSendToken: $0.sendToken) }
        let sendToken: String
        if let stored, stored.deviceId == deviceId,
           storedPermission?.registrationId == registration.registrationId {
            sendToken = stored.sendToken
        } else {
            do {
                if let storedPermission, storedPermission.registrationId == registration.registrationId {
                    // An earlier pairing's permission on this registration: its server may not
                    // have released it.
                    try? await client.deletePermission(storedPermission.permissionId, registration: registration)
                }
                sendToken = try await client.mintSendToken(registration).sendToken
            } catch let error as PushRelayClient.RelayError
                where mayReplaceRelayRegistration && [.gone, .tooManyPermissions, .keyLost].contains(error) {
                // The relay forgot this device (APNs retired the token), permissions leaked
                // before this phone reused them filled it, or its App Attest key is gone (the
                // app was reinstalled): start over with a fresh registration, once. Every
                // server mints again on its next connection.
                try await register(
                    api: api, serverId: serverId, deviceId: deviceId, relay: relay,
                    environment: environment, apnsToken: apnsToken, client: client,
                    replacing: registration, mayReplaceRelayRegistration: false,
                    mayRecoverGoneSendToken: mayRecoverGoneSendToken
                )
                return
            }
            // Push turned off while this registration ran (a reconnect's, say): `disable`
            // found no token to release, so this one goes too.
            guard Self.isEnabled(serverId: serverId) else {
                if let minted = PushRelayClient.permission(ofSendToken: sendToken) {
                    try? await client.deletePermission(minted.permissionId, registration: registration)
                }
                throw PushRegistrationError.turnedOff
            }
            // Kept before the server hears it, so a failed call below reuses it next time
            // instead of leaking it.
            try PushSendTokenStore.save(
                PushSendTokenStore.Entry(sendToken: sendToken, deviceId: deviceId),
                serverId: serverId
            )
        }
        guard Self.isEnabled(serverId: serverId) else { throw PushRegistrationError.turnedOff }
        do {
            try await sendToServer(api: api, serverId: serverId, deviceId: deviceId, relay: relay, sendToken: sendToken)
        } catch let error as APIError where mayRecoverGoneSendToken && Self.isSendTokenGone(error) {
            // The relay refused this token when the server last pushed with it (410): its
            // permission is gone, or the whole registration. Mint again, once: the mint
            // replaces a registration the relay no longer holds (above), and only then, since
            // a new registration for this APNs token takes every other server's permission
            // with it.
            logger.error("Push send token gone at the relay for server \(serverId.prefix(16), privacy: .public); minting again")
            PushSendTokenStore.delete(serverId: serverId)
            try await register(
                api: api, serverId: serverId, deviceId: deviceId, relay: relay,
                environment: environment, apnsToken: apnsToken, client: client,
                replacing: nil, mayReplaceRelayRegistration: mayReplaceRelayRegistration,
                mayRecoverGoneSendToken: false
            )
        }
    }

    /// `PUT /me/push-registration` answers `410 send_token_gone` for a send token the relay
    /// has refused (spec §5).
    private static func isSendTokenGone(_ error: APIError) -> Bool {
        if case .server(410, "send_token_gone") = error { return true }
        return false
    }

    /// The stored registration at `relay` for `apnsToken`, or a new one. One registration at a
    /// time per relay and environment: the relay keeps one per APNs token, so a second made
    /// beside it would delete the first one's permissions. A caller waits for the one in
    /// flight, then reads the store again; when that one failed, so do its waiters, rather
    /// than each attesting a key of its own against a relay that just refused.
    ///
    /// `refused`, the registration the relay just refused, is replaced only while it is still
    /// the stored one; a caller that waited uses the registration that replaced it.
    private func relayRegistration(
        relay: URL,
        environment: APNsEnvironment,
        apnsToken: String,
        client: PushRelayClient,
        replacing refused: PushRelayClient.Registration?
    ) async throws -> PushRelayClient.Registration {
        let account = PushRelayRegistrationStore.account(relay: relay, environment: environment)
        while let inFlight = relayRegistrationTasks[account] {
            _ = try await inFlight.value
        }
        let stored = PushRelayRegistrationStore.load(relay: relay, environment: environment)
        if let stored, stored.apnsToken == apnsToken, stored.registrationId != refused?.registrationId {
            return stored
        }
        // A registration for an old APNs token, or the refused one, goes first, with its
        // permissions.
        let stale = stored ?? refused
        let task = Task { () throws -> PushRelayClient.Registration in
            // Before any waiter resumes: a waiter that found this task still listed would
            // await it again without suspending, forever.
            defer { relayRegistrationTasks[account] = nil }
            if let stale {
                do {
                    try await client.deleteRegistration(stale)
                } catch PushRelayClient.RelayError.keyLost {
                    // Nothing can sign its delete any more. It stays at the relay until APNs
                    // retires its token, or the new registration for that token replaces it;
                    // this phone must not keep it.
                    logger.error("Push relay registration lost its App Attest key; registering again")
                }
                PushRelayRegistrationStore.delete(stale)
            }
            let registration = try await client.register(apnsToken: apnsToken, environment: environment)
            try PushRelayRegistrationStore.save(registration, relay: relay, environment: environment)
            return registration
        }
        // Listed before the task's body runs on this actor, so its `defer` clears it.
        relayRegistrationTasks[account] = task
        return try await task.value
    }

    /// Give the server this phone's push key for it, `sendToken`, and whether this phone shows
    /// its Live Activity; then tell the relay, which learns the permission that may drive the
    /// card.
    private func sendToServer(
        api: APIClient,
        serverId: String,
        deviceId: String,
        relay: URL,
        sendToken: String
    ) async throws {
        let liveActivity = LiveActivitySettings.isEnabled(serverId: serverId)
        let key = try currentOrNewKey(serverId: serverId)
        let publicKey = key.privateKey.publicKey.rawRepresentation
        let keyId = PushEnvelope.keyId(forPublicKey: publicKey).base64URLEncodedString
        let issuedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let message = PushRegistrationSignature.message(
            deviceId: deviceId,
            serverFingerprint: serverId,
            keyId: keyId,
            publicKey: publicKey,
            sendToken: sendToken,
            relay: relay.absoluteString,
            issuedAt: issuedAt
        )
        let signature = try DeviceKeyProvider.shared.loadOrCreate().sign(message)
        let response = try await api.putPushRegistration(PushRegistrationRequest(
            keyId: keyId,
            publicKey: publicKey.base64URLEncodedString,
            sendToken: sendToken,
            relay: relay.absoluteString,
            issuedAt: issuedAt,
            signature: signature.base64URLEncodedString,
            liveActivity: liveActivity,
            events: PushPlaintext.Event.allCases.map(\.rawValue)
        ))
        guard Self.isEnabled(serverId: serverId) else {
            // Turned off while the server heard this, maybe after `disable` told it to forget:
            // it forgets again, and this phone keeps no key for it.
            try? await api.deletePushRegistration()
            PushSendTokenStore.delete(serverId: serverId)
            throw PushRegistrationError.turnedOff
        }

        // Pin: only the server whose identity this phone paired with may sign its pushes.
        guard let serverPublicKey = Data(base64URLEncoded: response.serverPublicKey),
              serverPublicKey.sha256Fingerprint == serverId,
              response.keyId == keyId else {
            // The server releases the permission as it forgets the registration.
            try? await api.deletePushRegistration()
            PushSendTokenStore.delete(serverId: serverId)
            throw PushRegistrationError.serverKeyMismatch
        }
        try PushSharedStore.saveKey(PushSharedStore.KeyRecord(
            privateKey: key.privateKey.rawRepresentation,
            serverId: serverId,
            serverPublicKey: serverPublicKey,
            createdAt: key.createdAt
        ))
        pruneKeys(serverId: serverId, keeping: 2)
        // The relay learns this permission for the card, or that a new registration has one.
        LiveActivityRelaySync.shared.publish()
    }

    /// Turn push off for a server: the server forgets this device's key and token, the relay
    /// the permission, and this phone the keys and token, so the relay lists the server's
    /// card no more. When no other server's token is on the same relay registration and none
    /// is registering, the relay forgets the registration too (push token, App Attest key,
    /// Live Activity tokens), and so does this phone; turning push on again registers anew.
    /// A failed turn-on calls this too, so it leaves nothing at the relay.
    ///
    /// `relay` is the server's relay when its connection knows it; without it (an offline
    /// server, or one whose capabilities have not loaded) the permission's registration ID
    /// finds the stored registration, so the relay still stops taking the server's pushes,
    /// which this phone could no longer open.
    func disable(
        serverId: String,
        api: APIClient?,
        relay: URL?,
        relayClient: (URL) -> PushRelayClient = { PushRelayClient(relay: $0) }
    ) async {
        Self.setEnabled(false, serverId: serverId)
        let permission = PushSendTokenStore.load(serverId: serverId)
            .flatMap { PushRelayClient.permission(ofSendToken: $0.sendToken) }
        // First, so the relay stops listing the card even if the calls below fail.
        PushSendTokenStore.delete(serverId: serverId)
        LiveActivityRelaySync.shared.publish()
        try? await api?.deletePushRegistration()
        // The registration the server's token is on. Without a token (a turn-on whose mint
        // failed), the one stored for its relay, which that turn-on may have made.
        let registration: PushRelayClient.Registration? = if let permission {
            Self.relayRegistration(holding: permission.registrationId, relay: relay)
        } else if let relay, let environment = APNsEnvironment.current {
            PushRelayRegistrationStore.load(relay: relay, environment: environment)
        } else {
            nil
        }
        if let registration, let registrationRelay = URL(string: registration.relay) {
            let client = relayClient(registrationRelay)
            if isUnused(registration, relay: registrationRelay) {
                // Forgotten first, so a registration that starts during the delete makes a
                // new one instead of minting on this one. Best effort: one the relay keeps is
                // replaced when this phone registers again, and deleted when APNs retires its
                // token.
                PushRelayRegistrationStore.delete(registration)
                do {
                    try await client.deleteRegistration(registration)
                } catch {
                    logger.error("Push relay registration not deleted: \(String(describing: error), privacy: .public)")
                }
            } else if let permission {
                try? await client.deletePermission(permission.permissionId, registration: registration)
            }
        }
        pruneKeys(serverId: serverId, keeping: 0)
    }

    /// No server holds a send token on `registration`, and none is registering at its relay.
    private func isUnused(_ registration: PushRelayClient.Registration, relay: URL) -> Bool {
        guard let environment = APNsEnvironment(rawValue: registration.environment),
              registrationsInFlight[PushRelayRegistrationStore.account(relay: relay, environment: environment)] == nil
        else { return false }
        return !PushSendTokenStore.all().contains {
            PushRelayClient.permission(ofSendToken: $0.sendToken)?.registrationId == registration.registrationId
        }
    }

    private static func relayRegistration(holding registrationId: String, relay: URL?) -> PushRelayClient.Registration? {
        if let relay, let environment = APNsEnvironment.current,
           let registration = PushRelayRegistrationStore.load(relay: relay, environment: environment),
           registration.registrationId == registrationId {
            return registration
        }
        return PushRelayRegistrationStore.all().first { $0.registrationId == registrationId }
    }

    // MARK: - Keys

    private struct PendingKey {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let createdAt: Date
    }

    /// The newest key for this server unless it is due for rotation.
    private func currentOrNewKey(serverId: String) throws -> PendingKey {
        if let newest = PushSharedStore.allKeys().first(where: { $0.serverId == serverId }),
           Date().timeIntervalSince(newest.createdAt) < Self.keyRotationInterval,
           let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: newest.privateKey) {
            return PendingKey(privateKey: privateKey, createdAt: newest.createdAt)
        }
        return PendingKey(privateKey: Curve25519.KeyAgreement.PrivateKey(), createdAt: Date())
    }

    /// Keep the newest keys for a server: the previous one still opens pushes sealed before
    /// the server learned the new key.
    private func pruneKeys(serverId: String, keeping count: Int) {
        for record in PushSharedStore.allKeys().filter({ $0.serverId == serverId }).dropFirst(count) {
            if let keyId = try? record.keyId { PushSharedStore.deleteKey(keyId: keyId) }
        }
    }

    // MARK: - Redaction snapshot

    /// Give the extension the current App Lock and scoped-lock state. Called on registration
    /// and whenever either changes.
    /// App Lock counts as on whenever its timeout is set, even while the device has no
    /// passcode: the extension errs toward hiding.
    static func publishRedactionSnapshot(
        appLockEnabled: Bool = AppLockSettings.timeout().isEnabled,
        flags: Set<ScopedLockScope> = ScopedLockService.shared.flags
    ) {
        let scopes = Set(flags.map { scope -> PushRedactionSnapshot.Scope in
            switch scope {
            case .server(let serverId):
                PushRedactionSnapshot.Scope(serverId: serverId, workspaceId: nil, sessionId: nil)
            case .workspace(let serverId, let workspaceId):
                PushRedactionSnapshot.Scope(serverId: serverId, workspaceId: workspaceId, sessionId: nil)
            case .session(let serverId, let sessionId):
                PushRedactionSnapshot.Scope(serverId: serverId, workspaceId: nil, sessionId: sessionId)
            }
        })
        do {
            try PushSharedStore.saveRedactionSnapshot(
                PushRedactionSnapshot(appLockEnabled: appLockEnabled, lockedScopes: scopes)
            )
        } catch {
            // The extension then redacts everything.
            logger.error("Push redaction snapshot not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - APNs token

    /// Called from AppDelegate when APNs issues the device token.
    func didRegisterForRemoteNotifications(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        resumeTokenWaiters(with: token)
    }

    /// Called from AppDelegate when APNs registration fails, including on a build
    /// signed without the Push Notifications entitlement.
    func didFailToRegisterForRemoteNotifications(error: Error) {
        logger.error("Failed to register for remote notifications: \(error.localizedDescription, privacy: .public)")
        resumeTokenWaiters(with: nil)
    }

    /// APNs registration needs no notification permission; asking for it waits until a
    /// token proves this build can receive pushes. Nil when APNs refuses, when it has not
    /// answered within `timeout`, or when the caller is cancelled; a later call asks again.
    func currentDeviceToken(timeout: Duration = deviceTokenTimeout) async -> String? {
        if let deviceToken { return deviceToken }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                tokenWaiters[id] = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.resumeTokenWaiter(id, with: nil)
                }
                if tokenWaiters.count == 1 {
                    requestDeviceToken()
                }
            }
        } onCancel: {
            // The hop to the main actor runs after the body has stored the continuation, or
            // has seen the cancellation and resumed it itself.
            Task { @MainActor [weak self] in self?.resumeTokenWaiter(id, with: nil) }
        }
    }

    private func requestDeviceToken() {
        #if DEBUG
        if let register = _registerForRemoteNotificationsForTesting {
            register()
            return
        }
        #endif
        UIApplication.shared.registerForRemoteNotifications()
    }

    private func resumeTokenWaiter(_ id: UUID, with token: String?) {
        tokenWaiters.removeValue(forKey: id)?.resume(returning: token)
    }

    private func resumeTokenWaiters(with token: String?) {
        let waiters = tokenWaiters
        tokenWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(returning: token)
        }
    }
}

enum PushRegistrationError: Error {
    /// The server answered with an identity key other than the one pinned at pairing.
    case serverKeyMismatch
    /// Push was turned off for the server while the registration ran.
    case turnedOff
}

/// Body of `PUT /me/push-registration` (spec §5).
struct PushRegistrationRequest: Encodable, Equatable, Sendable {
    let keyId: String
    let publicKey: String
    let sendToken: String
    let relay: String
    let issuedAt: Int64
    let signature: String
    /// This server may drive the Live Activity while Oppi is closed. Outside the signature:
    /// the relay holds the real tokens and refuses without them.
    let liveActivity: Bool
    /// The plaintext events this app can open; the server sends no other. Outside the signature:
    /// leaving one out only withholds alerts.
    let events: [String]
}

struct PushRegistrationResponse: Decodable, Equatable, Sendable {
    let serverPublicKey: String
    let keyId: String
}
