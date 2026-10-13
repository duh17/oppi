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
/// 3. mints a send permission for this server at the relay;
/// 4. sends the server this device's X25519 push public key for that server and the send
///    token, signed by the device's pairing key;
/// 5. checks the server's Ed25519 key against the fingerprint pinned at pairing and stores
///    it with the private key for the Notification Service Extension.
///
/// The relay sees the APNs token, never a push key or push content.
@MainActor
final class PushRegistration {
    static let shared = PushRegistration()

    /// Push keys rotate at the first registration after this age.
    static let keyRotationInterval: TimeInterval = 30 * 86_400

    private var deviceToken: String?
    private var tokenWaiters: [CheckedContinuation<String?, Never>] = []

    #if DEBUG
    /// Replaces the registration a server's push capability starts.
    var _onRegisterForTesting: ((String?) -> Void)?
    #endif

    private init() {}

    // MARK: - Opt-in

    private static func optInKey(serverId: String) -> String {
        "\(AppIdentifiers.subsystem).push.enabled.\(serverId)"
    }

    private static func permissionKey(serverId: String) -> String {
        "\(AppIdentifiers.subsystem).push.permission.\(serverId)"
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
                retryWithNewRelayRegistration: true
            )
            logger.info("Push registered with server \(server, privacy: .public) (\(environment.rawValue, privacy: .public))")
            return true
        } catch {
            logger.error("Push registration failed for server \(server, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func register(
        api: APIClient,
        serverId: String,
        deviceId: String,
        relay: URL,
        environment: APNsEnvironment,
        apnsToken: String,
        retryWithNewRelayRegistration: Bool
    ) async throws {
        let client = PushRelayClient(relay: relay)
        var relayRegistration = PushRelayRegistrationStore.load(relay: relay, environment: environment)
        if let existing = relayRegistration, existing.apnsToken != apnsToken {
            // A new APNs token needs a new relay registration; the old one is useless.
            try? await client.deleteRegistration(existing)
            relayRegistration = nil
        }
        let registration: PushRelayClient.Registration
        if let relayRegistration {
            registration = relayRegistration
        } else {
            registration = try await client.register(apnsToken: apnsToken, environment: environment)
            try PushRelayRegistrationStore.save(registration, relay: relay, environment: environment)
        }

        let minted: (permissionId: String, sendToken: String)
        do {
            minted = try await client.mintSendToken(registration)
        } catch PushRelayClient.RelayError.gone, PushRelayClient.RelayError.tooManyPermissions
            where retryWithNewRelayRegistration {
            // The relay forgot this device (APNs retired the token) or leaked permissions
            // filled it: start over with a fresh registration, once.
            try? await client.deleteRegistration(registration)
            PushRelayRegistrationStore.delete(relay: relay, environment: environment)
            try await register(
                api: api, serverId: serverId, deviceId: deviceId, relay: relay,
                environment: environment, apnsToken: apnsToken, retryWithNewRelayRegistration: false
            )
            return
        }

        let key = try currentOrNewKey(serverId: serverId)
        let publicKey = key.privateKey.publicKey.rawRepresentation
        let keyId = PushEnvelope.keyId(forPublicKey: publicKey).base64URLEncodedString
        let issuedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let message = PushRegistrationSignature.message(
            deviceId: deviceId,
            serverFingerprint: serverId,
            keyId: keyId,
            publicKey: publicKey,
            sendToken: minted.sendToken,
            relay: relay.absoluteString,
            issuedAt: issuedAt
        )
        let signature = try DeviceKeyProvider.shared.loadOrCreate().sign(message)
        let response = try await api.putPushRegistration(PushRegistrationRequest(
            keyId: keyId,
            publicKey: publicKey.base64URLEncodedString,
            sendToken: minted.sendToken,
            relay: relay.absoluteString,
            issuedAt: issuedAt,
            signature: signature.base64URLEncodedString
        ))

        // Pin: only the server whose identity this phone paired with may sign its pushes.
        guard let serverPublicKey = Data(base64URLEncoded: response.serverPublicKey),
              serverPublicKey.sha256Fingerprint == serverId,
              response.keyId == keyId else {
            try? await api.deletePushRegistration()
            throw PushRegistrationError.serverKeyMismatch
        }
        try PushSharedStore.saveKey(PushSharedStore.KeyRecord(
            privateKey: key.privateKey.rawRepresentation,
            serverId: serverId,
            serverPublicKey: serverPublicKey,
            createdAt: key.createdAt
        ))
        pruneKeys(serverId: serverId, keeping: 2)
        UserDefaults.standard.set(minted.permissionId, forKey: Self.permissionKey(serverId: serverId))
    }

    /// Turn push off for a server: the server forgets this device's key and token, the relay
    /// the permission, and this phone the keys.
    func disable(serverId: String, api: APIClient?, relay: URL?) async {
        Self.setEnabled(false, serverId: serverId)
        try? await api?.deletePushRegistration()
        if let relay, let environment = APNsEnvironment.current,
           let registration = PushRelayRegistrationStore.load(relay: relay, environment: environment),
           let permissionId = UserDefaults.standard.string(forKey: Self.permissionKey(serverId: serverId)) {
            try? await PushRelayClient(relay: relay).deletePermission(permissionId, registration: registration)
        }
        UserDefaults.standard.removeObject(forKey: Self.permissionKey(serverId: serverId))
        pruneKeys(serverId: serverId, keeping: 0)
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
    /// token proves this build can receive pushes.
    private func currentDeviceToken() async -> String? {
        if let deviceToken { return deviceToken }
        return await withCheckedContinuation { continuation in
            tokenWaiters.append(continuation)
            if tokenWaiters.count == 1 {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    private func resumeTokenWaiters(with token: String?) {
        let waiters = tokenWaiters
        tokenWaiters.removeAll()
        for waiter in waiters {
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
}

struct PushRegistrationResponse: Decodable, Equatable, Sendable {
    let serverPublicKey: String
    let keyId: String
}
