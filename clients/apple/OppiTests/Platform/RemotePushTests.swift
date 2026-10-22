import CryptoKit
import DeviceCheck
import Foundation
import Testing
import UserNotifications
@testable import Oppi

@Suite("Remote push", .serialized)
@MainActor
struct RemotePushTests {
    // MARK: - APNs environment

    private func provisioningProfile(apsEnvironment: String?) throws -> Data {
        var entitlements: [String: Any] = ["application-identifier": "TEAM.dev.chenda.Oppi"]
        if let apsEnvironment { entitlements["aps-environment"] = apsEnvironment }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["Name": "iOS Team Provisioning Profile", "Entitlements": entitlements],
            format: .xml,
            options: 0
        )
        // A real profile wraps the plist in a binary CMS signature.
        return Data([0x30, 0x82, 0x3C, 0x3F, 0x00]) + plist + Data([0xA0, 0x82, 0x01, 0x00])
    }

    @Test func profileEnvironmentMapsToTheAPNsHost() throws {
        #expect(APNsEnvironment.fromProvisioningProfile(try provisioningProfile(apsEnvironment: "development")) == .sandbox)
        #expect(APNsEnvironment.fromProvisioningProfile(try provisioningProfile(apsEnvironment: "production")) == .production)
    }

    @Test func profileWithoutPushHasNoEnvironment() throws {
        #expect(APNsEnvironment.fromProvisioningProfile(try provisioningProfile(apsEnvironment: nil)) == nil)
        #expect(APNsEnvironment.fromProvisioningProfile(Data("not a profile".utf8)) == nil)
    }

    // MARK: - Turning push on

    /// A phone that cannot reach APNs never hears back; turning push on must not spin forever.
    @Test func aDeviceTokenAPNsNeverIssuesEndsTheWait() async {
        let push = PushRegistration.shared
        var requests = 0
        push._registerForRemoteNotificationsForTesting = { requests += 1 }
        defer { push._registerForRemoteNotificationsForTesting = nil }

        #expect(await push.currentDeviceToken(timeout: .milliseconds(50)) == nil)
        #expect(requests == 1)
        // A later registration asks APNs again.
        #expect(await push.currentDeviceToken(timeout: .milliseconds(50)) == nil)
        #expect(requests == 2)
    }

    @Test func aCancelledWaitForTheDeviceTokenEndsAtOnce() async {
        let push = PushRegistration.shared
        push._registerForRemoteNotificationsForTesting = {}
        defer { push._registerForRemoteNotificationsForTesting = nil }
        let started = ContinuousClock.now

        let wait = Task { await push.currentDeviceToken(timeout: .seconds(60)) }
        try? await Task.sleep(for: .milliseconds(50))
        wait.cancel()

        #expect(await wait.value == nil)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func aFailedRegistrationSaysWhetherToWaitOrToCheckTheServer() {
        typealias RelayError = PushRelayClient.RelayError
        #expect(PushRegistration.Failure(RelayError.rejected(429, "rate_limited")) == .relayBusy)
        #expect(PushRegistration.Failure(RelayError.rejected(503, "relay_capacity")) == .relayBusy)
        #expect(PushRegistration.Failure(RelayError.rejected(503, nil)) == .refused)
        #expect(PushRegistration.Failure(RelayError.rejected(401, "attestation_invalid")) == .refused)
        #expect(PushRegistration.Failure(RelayError.tooManyPermissions) == .refused)
        #expect(PushRegistration.Failure(APIError.server(status: 409, message: "relay_mismatch")) == .refused)
        #expect(PushRegistration.Failure(URLError(.notConnectedToInternet)) == .refused)
    }

    // MARK: - Foreground and local alerts

    @Test func failedRunsAndAgentMessagesShowInFrontUnlessTheirChatIsOnScreen() {
        for category in [AttentionNotificationPolicy.sessionFailedCategoryId, AttentionNotificationPolicy.agentMessageCategoryId] {
            #expect(AttentionNotificationPolicy.showsInForeground(categoryIdentifier: category, sessionIsOnScreen: false))
            #expect(!AttentionNotificationPolicy.showsInForeground(categoryIdentifier: category, sessionIsOnScreen: true))
        }
        // The server skips a present device for Needs you; the app shows its own ask banner.
        #expect(!AttentionNotificationPolicy.showsInForeground(
            categoryIdentifier: AttentionNotificationPolicy.sessionBlockedCategoryId,
            sessionIsOnScreen: false
        ))
    }

    /// The server pushes a failed run to every device, present or not: a backgrounded app that
    /// still holds its streams must not add a second alert of its own.
    @Test func aStoppedRunPostsNoLocalBanner() async {
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials(fingerprint: "sha256:push-srv"))
        connection.setSplitStreamCapabilitiesForTesting(
            appEventStream: true,
            pushRelay: URL(string: "https://push.example.test")
        )
        PushRegistration.setEnabled(true, serverId: "sha256:push-srv")
        defer { PushRegistration.setEnabled(false, serverId: "sha256:push-srv") }
        var session = makeTestSession(
            id: "s1",
            workspaceId: "w1",
            name: "Fix login",
            status: .busy,
            programStatus: ProgramStatus(state: .working, since: Date(timeIntervalSince1970: 1))
        )
        connection.sessionStore.upsert(session)

        let service = AttentionNotificationService.shared
        let previousState = service._applicationStateForTesting
        defer {
            service._applicationStateForTesting = previousState
            service._deliverForTesting = nil
        }
        service._applicationStateForTesting = .background

        let delivered: DeliveredBanner? = await withCheckedContinuation { continuation in
            let once = DeliveredOnce(continuation)
            service._deliverForTesting = { once.resume(DeliveredBanner($0)) }
            for state in [ProgramStatusState.error, .done] {
                session.status = .ready
                session.programStatus = ProgramStatus(state: state, since: Date(timeIntervalSince1970: 2))
                connection.handleAppEvent(.sessionSummary(
                    sessionId: "s1",
                    workspaceId: "w1",
                    emittedAt: 2,
                    summary: SessionSummary(from: session)
                ))
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                once.resume(nil)
            }
        }
        #expect(delivered == nil)
    }
}

/// The delivered request's fields; `UNNotificationRequest` is not Sendable.
private struct DeliveredBanner: Sendable, Equatable {
    let identifier: String
    let category: String
    let title: String
    let subtitle: String
    let interruptionLevel: UNNotificationInterruptionLevel
    let sessionId: String?

    init(_ request: UNNotificationRequest) {
        identifier = request.identifier
        category = request.content.categoryIdentifier
        title = request.content.title
        subtitle = request.content.subtitle
        interruptionLevel = request.content.interruptionLevel
        sessionId = request.content.userInfo["sessionId"] as? String
    }
}

/// Resumes a continuation once; later calls are ignored.
@MainActor
private final class DeliveredOnce {
    private var continuation: CheckedContinuation<DeliveredBanner?, Never>?

    init(_ continuation: CheckedContinuation<DeliveredBanner?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: DeliveredBanner?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

@Suite("Push send permission", .serialized)
@MainActor
struct PushSendPermissionTests {
    /// A relay and two Oppi servers behind one URL protocol: the relay mints permissions on any
    /// registration it has not forgotten, each server keeps the last send token it was given.
    fileprivate final class Backend: @unchecked Sendable {
        private let lock = NSLock()
        private var _mints: [String] = []
        private var _registrations = 0
        private var _sentTokens: [String] = []
        private var _sentEvents: [[String]] = []
        private var _deletedPermissions: [String] = []
        private var _deletedRegistrations: [String] = []
        private var _goneRegistrations: Set<String> = []
        private var _goneSendTokens: Set<String> = []
        private var _everySendTokenGone = false
        let serverPublicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        /// The server at `http://other-server`.
        let otherServerPublicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation

        var mints: [String] { lock.withLock { _mints } }
        /// `POST /v1/registrations` calls.
        var registrations: Int { lock.withLock { _registrations } }
        var sentTokens: [String] { lock.withLock { _sentTokens } }
        var sentEvents: [[String]] { lock.withLock { _sentEvents } }
        var deletedPermissions: [String] { lock.withLock { _deletedPermissions } }
        var deletedRegistrations: [String] { lock.withLock { _deletedRegistrations } }

        /// The relay deleted these registrations (`410` to calls on them).
        func forgetRegistration(_ id: String) { lock.withLock { _ = _goneRegistrations.insert(id) } }
        /// The servers answer `410 send_token_gone` to these tokens, or to every token.
        func refuseSendToken(_ token: String) { lock.withLock { _ = _goneSendTokens.insert(token) } }
        func refuseEverySendToken() { lock.withLock { _everySendTokenGone = true } }

        func handle(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let parts = path.split(separator: "/")
            var status = 200
            var body: [String: Any] = [:]
            if parts.count >= 3, parts[1] == "registrations", lock.withLock({ _goneRegistrations.contains(String(parts[2])) }) {
                status = 410
                body = ["error": "gone"]
            } else if request.httpMethod == "POST", parts.count == 4, parts[1] == "registrations", parts[3] == "permissions" {
                let registrationId = String(parts[2])
                let permissionId = lock.withLock {
                    _mints.append(registrationId)
                    return "p_\(_mints.count)"
                }
                status = 201
                body = ["permissionId": permissionId, "sendToken": "osp1.\(registrationId).\(permissionId).secret"]
            } else if request.httpMethod == "POST", path == "/v1/challenge" {
                body = ["challenge": "challenge"]
            } else if request.httpMethod == "POST", path == "/v1/registrations" {
                lock.withLock { _registrations += 1 }
                status = 201
                body = ["registrationId": "r_NEW", "registrationSecret": "secret"]
            } else if request.httpMethod == "PUT", parts.count == 4, parts[3] == "live-activity" {
                // The relay forgot every registration but the new one.
                status = parts[2] == "r_NEW" ? 204 : 410
            } else if request.httpMethod == "DELETE", parts.count == 5, parts[3] == "permissions" {
                lock.withLock { _deletedPermissions.append(String(parts[4])) }
                status = 204
            } else if request.httpMethod == "DELETE", parts.count == 3, parts[1] == "registrations" {
                lock.withLock { _deletedRegistrations.append(String(parts[2])) }
                status = 204
            } else if request.httpMethod == "PUT", path.hasSuffix("/me/push-registration") {
                let json = try JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any]
                let token = json?["sendToken"] as? String ?? ""
                let events = json?["events"] as? [String] ?? []
                let refused = lock.withLock {
                    _sentTokens.append(token)
                    _sentEvents.append(events)
                    return _everySendTokenGone || _goneSendTokens.contains(token)
                }
                let serverKey = request.url?.host == "other-server" ? otherServerPublicKey : serverPublicKey
                if refused {
                    status = 410
                    body = ["error": "send_token_gone"]
                } else {
                    body = ["serverPublicKey": serverKey.base64URLEncodedString, "keyId": json?["keyId"] as? String ?? ""]
                }
            } else {
                status = 404
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (try JSONSerialization.data(withJSONObject: body), response)
        }

        private static func body(of request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(contentsOf: buffer.prefix(read))
            }
            return data
        }
    }

    fileprivate final class BackendProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var backend: Backend?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                guard let backend = Self.backend else { throw URLError(.badServerResponse) }
                let (data, response) = try backend.handle(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}
    }

    private let backend = Backend()
    private let relay = URL(string: "https://relay-\(UUID().uuidString.lowercased()).example")!
    private let configuration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackendProtocol.self]
        return configuration
    }()

    private var serverId: String { backend.serverPublicKey.sha256Fingerprint }
    private var otherServerId: String { backend.otherServerPublicKey.sha256Fingerprint }
    private static let otherServer = URL(string: "http://other-server")!
    /// The App Attest key kept to retry, for this test only.
    private let pendingAttestKey = PendingKeyBox()

    private func storeRelayRegistration(
        _ registrationId: String,
        apnsToken: String = String(repeating: "a", count: 64),
        appAttestKeyId: String? = nil
    ) throws {
        try PushRelayRegistrationStore.save(PushRelayClient.Registration(
            relay: relay.absoluteString,
            environment: APNsEnvironment.sandbox.rawValue,
            apnsToken: apnsToken,
            registrationId: registrationId,
            registrationSecret: "secret",
            appAttestKeyId: appAttestKeyId
        ), relay: relay, environment: .sandbox)
    }

    /// App Attest after a reinstall: keys from before it are gone, a new one works.
    private struct ReinstalledAppAttest: AppAttestProviding {
        static let newKey = "k_new"
        var isSupported: Bool { true }
        func generateKey() async throws -> String { Self.newKey }
        func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("attestation".utf8) }
        func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
            guard keyId == Self.newKey else { throw DCError(.invalidKey) }
            return Data("assertion".utf8)
        }
    }

    fileprivate final class PendingKeyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var keyId: String?

        var store: PendingAppAttestKey {
            PendingAppAttestKey(
                load: { self.lock.withLock { self.keyId } },
                save: { keyId in self.lock.withLock { self.keyId = keyId } }
            )
        }
    }

    private func relayClient(appAttest: AppAttestProviding = ReinstalledAppAttest()) -> PushRelayClient {
        PushRelayClient(
            relay: relay,
            session: URLSession(configuration: configuration),
            appAttest: appAttest,
            pendingAttestKey: pendingAttestKey.store
        )
    }

    /// One connection's registration with a server, as `register()` runs it: the one at
    /// localhost, or `otherServer`.
    private func connect(
        deviceId: String = "d_phone",
        server: URL = URL(string: "http://localhost:7749")!,
        appAttest: AppAttestProviding = ReinstalledAppAttest()
    ) async throws {
        let api = APIClient(
            environment: OppiClientEnvironment(baseURL: server, bearerToken: "sk_test"),
            configuration: configuration
        )
        try await PushRegistration.shared.register(
            api: api,
            serverId: server == Self.otherServer ? otherServerId : serverId,
            deviceId: deviceId,
            relay: relay,
            environment: .sandbox,
            apnsToken: String(repeating: "a", count: 64),
            client: relayClient(appAttest: appAttest)
        )
    }

    private func disable(_ serverId: String) async {
        let configuration = configuration
        await PushRegistration.shared.disable(serverId: serverId, api: nil, relay: nil) {
            PushRelayClient(relay: $0, session: URLSession(configuration: configuration))
        }
    }

    private func withBackend(_ body: () async throws -> Void) async throws {
        BackendProtocol.backend = backend
        defer {
            BackendProtocol.backend = nil
            PushRelayRegistrationStore.delete(relay: relay, environment: .sandbox)
            for server in [serverId, otherServerId] {
                PushSendTokenStore.delete(serverId: server)
                for record in PushSharedStore.allKeys() where record.serverId == server {
                    if let keyId = try? record.keyId { PushSharedStore.deleteKey(keyId: keyId) }
                }
            }
        }
        try await body()
    }

    @Test func reconnectingReusesTheServersPermission() async throws {
        try await withBackend {
            try storeRelayRegistration("r_A")
            try await connect()
            try await connect()

            #expect(backend.mints == ["r_A"])
            #expect(backend.sentTokens.count == 2)
            #expect(Set(backend.sentTokens) == ["osp1.r_A.p_1.secret"])
        }
    }

    /// The server sends only these (spec section 5), so each must be one the extension opens.
    @Test func registrationListsEveryAlertTheExtensionOpens() async throws {
        try await withBackend {
            try storeRelayRegistration("r_A")
            try await connect()

            #expect(backend.sentEvents == [["blocked", "error", "notify", "pairing_approval", "device_enrolled"]])
        }
    }

    @Test func aNewRelayRegistrationGetsOneNewPermission() async throws {
        try await withBackend {
            try storeRelayRegistration("r_A")
            try await connect()
            try storeRelayRegistration("r_B")
            try await connect()
            try await connect()

            #expect(backend.mints == ["r_A", "r_B"])
            #expect(backend.sentTokens == ["osp1.r_A.p_1.secret", "osp1.r_B.p_2.secret", "osp1.r_B.p_2.secret"])
        }
    }

    @Test func aRegistrationTheRelayForgotGetsReplacedAtTheNextConnection() async throws {
        try await withBackend {
            try storeRelayRegistration("r_A")
            try await connect()
            // The Live Activity upload finds that the relay forgot the registration.
            let defaultsName = "PushSendPermissionTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: defaultsName)!
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let relay = relay
            let configuration = configuration
            let sync = LiveActivityRelaySync(
                registrations: { [PushRelayRegistrationStore.load(relay: relay, environment: .sandbox)].compactMap { $0 } },
                cards: { [.init(slot: "slot", registrationId: "r_A", permissionId: "p_1")] },
                put: { state, registration in
                    try await PushRelayClient(relay: relay, session: URLSession(configuration: configuration))
                        .putLiveActivity(state, registration: registration)
                },
                sleep: { _ in },
                defaults: defaults
            )
            await sync.publish().value
            try await connect()

            #expect(backend.mints == ["r_A", "r_NEW"])
            #expect(backend.sentTokens == ["osp1.r_A.p_1.secret", "osp1.r_NEW.p_2.secret"])
        }
    }

    // A reinstall keeps the keychain's relay registration but not its App Attest key.

    @Test func aNewServerAfterAReinstallGetsARegistrationWithANewKey() async throws {
        try await withBackend {
            try storeRelayRegistration("r_A", appAttestKeyId: "k_lost")
            try await connect()

            #expect(backend.mints == ["r_NEW"])
            #expect(backend.sentTokens == ["osp1.r_NEW.p_1.secret"])
            let stored = PushRelayRegistrationStore.load(relay: relay, environment: .sandbox)
            #expect(stored?.registrationId == "r_NEW")
            #expect(stored?.appAttestKeyId == ReinstalledAppAttest.newKey)
        }
    }

    @Test func aNewAPNsTokenAfterAReinstallStillRegisters() async throws {
        try await withBackend {
            try storeRelayRegistration("r_A", apnsToken: String(repeating: "b", count: 64), appAttestKeyId: "k_lost")
            try await connect()

            #expect(backend.mints == ["r_NEW"])
            #expect(backend.sentTokens == ["osp1.r_NEW.p_1.secret"])
        }
    }

    @Test func aLiveActivityUploadAfterAReinstallGetsTheRegistrationReplaced() async throws {
        try await withBackend {
            // The server's send token survived too, so connecting needs no relay call.
            try storeRelayRegistration("r_A", appAttestKeyId: "k_lost")
            try PushSendTokenStore.save(.init(sendToken: "osp1.r_A.p_0.secret", deviceId: "d_phone"), serverId: serverId)
            let defaultsName = "PushSendPermissionTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: defaultsName)!
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let relay = relay
            let client = relayClient()
            let sync = LiveActivityRelaySync(
                registrations: { [PushRelayRegistrationStore.load(relay: relay, environment: .sandbox)].compactMap { $0 } },
                cards: { [.init(slot: "slot", registrationId: "r_A", permissionId: "p_0")] },
                put: { state, registration in try await client.putLiveActivity(state, registration: registration) },
                sleep: { _ in },
                defaults: defaults
            )
            await sync.publish().value
            try await connect()

            #expect(backend.mints == ["r_NEW"])
            #expect(backend.sentTokens == ["osp1.r_NEW.p_1.secret"])
        }
    }

    /// Removing a server that is offline: neither it nor its relay is known this launch.
    @Test func turningPushOffWithoutTheServersRelayStillReleasesItsPermission() async throws {
        try await withBackend {
            try storeRelayRegistration("r_A")
            try await connect()
            try await connect(server: Self.otherServer)
            await disable(serverId)

            #expect(backend.deletedPermissions == ["p_1"])
            #expect(backend.deletedRegistrations.isEmpty)
            #expect(PushSharedStore.allKeys().allSatisfy { $0.serverId != serverId })
        }
    }

    /// Push off everywhere: the relay keeps nothing for this phone, and turning push on again
    /// registers anew.
    @Test func turningPushOffOnTheLastServerDeletesTheRelayRegistration() async throws {
        try await withBackend {
            try storeRelayRegistration("r_A")
            try await connect()
            try await connect(server: Self.otherServer)
            await disable(otherServerId)
            #expect(PushRelayRegistrationStore.load(relay: relay, environment: .sandbox)?.registrationId == "r_A")
            await disable(serverId)

            #expect(backend.deletedRegistrations == ["r_A"])
            #expect(backend.deletedPermissions == ["p_2"])
            #expect(PushRelayRegistrationStore.load(relay: relay, environment: .sandbox) == nil)

            // Turning push on again: an attested registration and a new token for the server.
            try await connect()
            #expect(backend.registrations == 1)
            #expect(PushRelayRegistrationStore.load(relay: relay, environment: .sandbox)?.appAttestKeyId
                == ReinstalledAppAttest.newKey)
            #expect(backend.mints.last == "r_NEW")
            #expect(backend.sentTokens.last == "osp1.r_NEW.p_3.secret")
            #expect(PushSendTokenStore.load(serverId: serverId)?.sendToken == "osp1.r_NEW.p_3.secret")
        }
    }

    /// Several servers reconnecting together, each with no relay registration yet: a second
    /// registration for the same APNs token would take the first one's permission with it.
    @Test func serversRegisteringAtOnceShareOneRelayRegistration() async throws {
        try await withBackend {
            async let first: Void = connect()
            async let second: Void = connect(server: Self.otherServer)
            _ = try await (first, second)

            #expect(backend.registrations == 1)
            #expect(backend.mints == ["r_NEW", "r_NEW"])
            #expect(Set(backend.sentTokens) == ["osp1.r_NEW.p_1.secret", "osp1.r_NEW.p_2.secret"])
            #expect(PushRelayRegistrationStore.load(relay: relay, environment: .sandbox)?.registrationId == "r_NEW")
        }
    }

    /// The relay deleted the registration (APNs retired the token) while the phone kept the
    /// same APNs token; the server learned it from the relay's `410`.
    @Test func aSendTokenTheRelayDroppedWithItsRegistrationGetsANewRegistration() async throws {
        try await withBackend {
            try storeRelayRegistration("r_A")
            try PushSendTokenStore.save(.init(sendToken: "osp1.r_A.p_0.secret", deviceId: "d_phone"), serverId: serverId)
            backend.forgetRegistration("r_A")
            backend.refuseSendToken("osp1.r_A.p_0.secret")
            try await connect()

            #expect(backend.registrations == 1)
            #expect(backend.sentTokens == ["osp1.r_A.p_0.secret", "osp1.r_NEW.p_1.secret"])
            #expect(PushSendTokenStore.load(serverId: serverId)?.sendToken == "osp1.r_NEW.p_1.secret")
        }
    }

    /// Only the permission is gone: the registration, and every other server's permission on
    /// it, stays.
    @Test func aSendTokenTheRelayDroppedAloneIsReplacedOnTheSameRegistration() async throws {
        try await withBackend {
            try storeRelayRegistration("r_A")
            try PushSendTokenStore.save(.init(sendToken: "osp1.r_A.p_0.secret", deviceId: "d_phone"), serverId: serverId)
            backend.refuseSendToken("osp1.r_A.p_0.secret")
            try await connect()

            #expect(backend.registrations == 0)
            #expect(backend.sentTokens == ["osp1.r_A.p_0.secret", "osp1.r_A.p_1.secret"])
        }
    }

    @Test func aServerThatRefusesEveryTokenGetsOneMoreTry() async throws {
        try await withBackend {
            try storeRelayRegistration("r_A")
            backend.refuseEverySendToken()
            await #expect(throws: APIError.self) { try await connect() }

            #expect(backend.sentTokens.count == 2)
            #expect(backend.registrations == 0)
        }
    }

    /// App Attest that could not reach Apple the first time.
    private final class UnreachableOnceAppAttest: AppAttestProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _generated: [String] = []
        private var _attested: [String] = []
        var generated: [String] { lock.withLock { _generated } }
        var attested: [String] { lock.withLock { _attested } }

        var isSupported: Bool { true }
        func generateKey() async throws -> String {
            lock.withLock {
                _generated.append("k_\(_generated.count + 1)")
                return _generated.last!
            }
        }
        func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
            let first = lock.withLock {
                _attested.append(keyId)
                return _attested.count == 1
            }
            if first { throw DCError(.serverUnavailable) }
            return Data("attestation".utf8)
        }
        func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { Data("assertion".utf8) }
    }

    /// Apple asks for a retry with the same key: each new key counts against the device.
    @Test func anAttestationThatCouldNotReachAppleIsRetriedWithTheSameKey() async throws {
        try await withBackend {
            let appAttest = UnreachableOnceAppAttest()
            await #expect(throws: DCError.self) { try await connect(appAttest: appAttest) }
            try await connect(appAttest: appAttest)

            #expect(appAttest.generated == ["k_1"])
            #expect(appAttest.attested == ["k_1", "k_1"])
            #expect(PushRelayRegistrationStore.load(relay: relay, environment: .sandbox)?.appAttestKeyId == "k_1")
            // The next registration attests a new key.
            #expect(pendingAttestKey.store.load() == nil)
        }
    }

    /// The Live Activities consent names it while the server is offline.
    @Test func theRelayThisPhoneRegisteredWithIsKnownWithoutTheServer() async throws {
        try await withBackend {
            try storeRelayRegistration("r_A")
            try await connect()
            #expect(PushRegistration.savedRelay(serverId: serverId) == relay)
            await disable(serverId)
            #expect(PushRegistration.savedRelay(serverId: serverId) == nil)
        }
    }

    @Test func aNewPairingGetsANewPermission() async throws {
        try await withBackend {
            try storeRelayRegistration("r_A")
            try await connect(deviceId: "d_first")
            // The server revoked the first pairing and released its token.
            try await connect(deviceId: "d_second")

            #expect(backend.mints == ["r_A", "r_A"])
            #expect(backend.deletedPermissions == ["p_1"])
            #expect(backend.sentTokens == ["osp1.r_A.p_1.secret", "osp1.r_A.p_2.secret"])
        }
    }
}
