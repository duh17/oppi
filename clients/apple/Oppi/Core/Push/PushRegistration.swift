import CryptoKit
import OSLog
import UIKit

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Push")

/// Opt-in, end-to-end-encrypted push for each paired server (protocol/push/spec.md).
///
/// Push needs both ends to opt in: the server operator sets `push.mode` to `relay`, so the
/// server advertises `capabilities.pushNotifications.relay`, and the user turns on push for
/// that server here (off by default). Then, once per connection, this:
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

    @discardableResult
    func register(api: APIClient, serverId: String, deviceId: String, relay: URL) async -> Bool {
        let server = serverId.prefix(16)
        guard let environment = APNsEnvironment.current else {
            logger.error("Push registration skipped for server \(server, privacy: .public): no aps-environment")
            return false
        }
        // A denied permission keeps the token off the relay: it could only deliver alerts iOS
        // would not show.
        guard let token = await currentDeviceToken(),
              await AttentionNotificationService.shared.notificationsAuthorized() else { return false }
        Self.publishRedactionSnapshot()
        do {
            try await register(
                api: api,
                serverId: serverId,
                deviceId: deviceId,
                relay: relay,
                environment: environment,
                apnsToken: token,
                client: PushRelayClient(relay: relay),
                retryWithNewRelayRegistration: true
            )
            logger.info("Push registered with server \(server, privacy: .public) (\(environment.rawValue, privacy: .public))")
            return true
        } catch {
            logger.error("Push registration failed for server \(server, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func register(
        api: APIClient,
        serverId: String,
        deviceId: String,
        relay: URL,
        environment: APNsEnvironment,
        apnsToken: String,
        client: PushRelayClient,
        retryWithNewRelayRegistration: Bool
    ) async throws {
        var relayRegistration = PushRelayRegistrationStore.load(relay: relay, environment: environment)
        if let existing = relayRegistration, existing.apnsToken != apnsToken {
            // A new APNs token needs a new relay registration. The old one goes first, with
            // its permissions.
            do {
                try await client.deleteRegistration(existing)
            } catch PushRelayClient.RelayError.keyLost {
                // Nothing can sign its delete any more. It stays at the relay until APNs
                // retires its token; this phone must not keep it.
                logger.error("Push relay registration lost its App Attest key; registering again")
            }
            PushRelayRegistrationStore.delete(relay: relay, environment: environment)
            relayRegistration = nil
        }
        let registration: PushRelayClient.Registration
        if let relayRegistration {
            registration = relayRegistration
        } else {
            registration = try await client.register(apnsToken: apnsToken, environment: environment)
            try PushRelayRegistrationStore.save(registration, relay: relay, environment: environment)
        }

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
                where retryWithNewRelayRegistration && [.gone, .tooManyPermissions, .keyLost].contains(error) {
                // The relay forgot this device (APNs retired the token), permissions leaked
                // before this phone reused them filled it, or its App Attest key is gone (the
                // app was reinstalled): start over with a fresh registration, once. Every
                // server mints again on its next connection. A registration without its key
                // cannot be deleted; the new one for the same APNs token replaces it.
                if error != .keyLost {
                    try await client.deleteRegistration(registration)
                }
                PushRelayRegistrationStore.delete(relay: relay, environment: environment)
                try await register(
                    api: api, serverId: serverId, deviceId: deviceId, relay: relay,
                    environment: environment, apnsToken: apnsToken, client: client,
                    retryWithNewRelayRegistration: false
                )
                return
            }
            // Kept before the server hears it, so a failed call below reuses it next time
            // instead of leaking it.
            try PushSendTokenStore.save(
                PushSendTokenStore.Entry(sendToken: sendToken, deviceId: deviceId),
                serverId: serverId
            )
        }
        try await sendToServer(api: api, serverId: serverId, deviceId: deviceId, relay: relay, sendToken: sendToken)
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
    /// card no more.
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
        if let permission,
           let registration = Self.relayRegistration(holding: permission.registrationId, relay: relay),
           let registrationRelay = URL(string: registration.relay) {
            try? await relayClient(registrationRelay).deletePermission(permission.permissionId, registration: registration)
        }
        pruneKeys(serverId: serverId, keeping: 0)
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
