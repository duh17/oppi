import CryptoKit
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

    // MARK: - Local done banner

    private func working(_ id: String = "s1", parent: String? = nil) -> Session {
        var session = makeTestSession(
            id: id,
            workspaceId: "w1",
            name: "Fix login",
            status: .busy,
            programStatus: ProgramStatus(state: .working, since: Date(timeIntervalSince1970: 1))
        )
        session.parentSessionId = parent
        return session
    }

    private func finished(_ session: Session, as state: ProgramStatusState = .done) -> Session {
        var done = session
        done.status = .ready
        done.programStatus = ProgramStatus(state: state, since: Date(timeIntervalSince1970: 2))
        return done
    }

    @Test func aTopLevelRunStoppingGetsOneBodyPerOutcome() {
        let session = working()
        #expect(AttentionNotificationPolicy.stoppedBody(previous: session, current: finished(session), sessions: []) == "Finished.")
        #expect(AttentionNotificationPolicy.stoppedBody(previous: session, current: finished(session, as: .error), sessions: []) == "Stopped with an error.")
        #expect(AttentionNotificationPolicy.stoppedBody(previous: session, current: finished(session, as: .idle), sessions: []) == "Stopped before finishing.")
        #expect(AttentionNotificationPolicy.stoppedBody(previous: finished(session), current: finished(session), sessions: []) == nil)
        // Not a run stopping: done to idle, or a first-seen status.
        #expect(AttentionNotificationPolicy.stoppedBody(previous: finished(session), current: finished(session, as: .idle), sessions: []) == nil)
        #expect(AttentionNotificationPolicy.stoppedBody(previous: nil, current: finished(session), sessions: []) == nil)

        let child = working("child", parent: "s1")
        #expect(AttentionNotificationPolicy.stoppedBody(previous: child, current: finished(child, as: .error), sessions: []) == nil)
    }

    @Test func aLeadIsNotDoneWhileAChildStillWorks() {
        let lead = working()
        let child = working("child", parent: "s1")
        #expect(AttentionNotificationPolicy.stoppedBody(previous: lead, current: finished(lead), sessions: [child]) == nil)
        #expect(AttentionNotificationPolicy.stoppedBody(previous: lead, current: finished(lead), sessions: [finished(child)]) != nil)
        // Another lead's working child does not hold this one.
        let otherChild = working("other-child", parent: "s2")
        #expect(AttentionNotificationPolicy.stoppedBody(previous: lead, current: finished(lead), sessions: [otherChild]) != nil)
    }

    /// Delivers the request a `working -> done` app-event summary schedules, or nil.
    private func doneBanner(serverPushes: Bool, optedIn: Bool = true) async -> DeliveredBanner? {
        let connection = ServerConnection()
        _ = connection.configure(credentials: makeTestCredentials(fingerprint: "sha256:push-srv"))
        connection.setSplitStreamCapabilitiesForTesting(
            appEventStream: true,
            pushRelay: serverPushes ? URL(string: "https://push.example.test") : nil
        )
        PushRegistration.setEnabled(optedIn, serverId: "sha256:push-srv")
        defer { PushRegistration.setEnabled(false, serverId: "sha256:push-srv") }
        let session = working()
        connection.sessionStore.upsert(session)

        let service = AttentionNotificationService.shared
        let previousState = service._applicationStateForTesting
        defer {
            service._applicationStateForTesting = previousState
            service._deliverForTesting = nil
            service._appLockEnabledForTesting = nil
        }
        service._applicationStateForTesting = .background
        service._appLockEnabledForTesting = false

        return await withCheckedContinuation { continuation in
            let once = DeliveredOnce(continuation)
            service._deliverForTesting = { once.resume(DeliveredBanner($0)) }
            connection.handleAppEvent(.sessionSummary(
                sessionId: "s1",
                workspaceId: "w1",
                emittedAt: 2,
                summary: SessionSummary(from: finished(session))
            ))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                once.resume(nil)
            }
        }
    }

    @Test func backgroundedAppPostsTheDoneBannerItsPushingServerSkipped() async throws {
        let request = try #require(await doneBanner(serverPushes: true))

        #expect(request.identifier == "done-s1")
        #expect(request.category == AttentionNotificationPolicy.sessionDoneCategoryId)
        #expect(request.title == String(localized: "Session Done"))
        #expect(request.subtitle == "Fix login")
        #expect(request.interruptionLevel == .passive)
        #expect(request.sessionId == "s1")
    }

    @Test func serverWithoutPushKeepsDoneInApp() async {
        #expect(await doneBanner(serverPushes: false) == nil)
    }

    /// Without the opt-in the server never pushes to this device, so it has nothing to skip.
    @Test func pushingServerKeepsDoneInAppUntilTheUserOptsIn() async {
        #expect(await doneBanner(serverPushes: true, optedIn: false) == nil)
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
    /// A relay and an Oppi server behind one URL protocol: the relay mints permissions on any
    /// registration, the server keeps the last send token it was given.
    fileprivate final class Backend: @unchecked Sendable {
        private let lock = NSLock()
        private var _mints: [String] = []
        private var _sentTokens: [String] = []
        private var _deletedPermissions: [String] = []
        let serverPublicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation

        var mints: [String] { lock.withLock { _mints } }
        var sentTokens: [String] { lock.withLock { _sentTokens } }
        var deletedPermissions: [String] { lock.withLock { _deletedPermissions } }

        func handle(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path ?? ""
            let parts = path.split(separator: "/")
            var status = 200
            var body: [String: Any] = [:]
            if request.httpMethod == "POST", parts.count == 4, parts[1] == "registrations", parts[3] == "permissions" {
                let registrationId = String(parts[2])
                let permissionId = lock.withLock {
                    _mints.append(registrationId)
                    return "p_\(_mints.count)"
                }
                status = 201
                body = ["permissionId": permissionId, "sendToken": "osp1.\(registrationId).\(permissionId).secret"]
            } else if request.httpMethod == "DELETE", parts.count == 5, parts[3] == "permissions" {
                lock.withLock { _deletedPermissions.append(String(parts[4])) }
                status = 204
            } else if request.httpMethod == "PUT", path.hasSuffix("/me/push-registration") {
                let json = try JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any]
                let token = json?["sendToken"] as? String ?? ""
                lock.withLock { _sentTokens.append(token) }
                body = ["serverPublicKey": serverPublicKey.base64URLEncodedString, "keyId": json?["keyId"] as? String ?? ""]
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

    private func storeRelayRegistration(_ registrationId: String) throws {
        try PushRelayRegistrationStore.save(PushRelayClient.Registration(
            relay: relay.absoluteString,
            environment: APNsEnvironment.sandbox.rawValue,
            apnsToken: String(repeating: "a", count: 64),
            registrationId: registrationId,
            registrationSecret: "secret",
            appAttestKeyId: nil
        ), relay: relay, environment: .sandbox)
    }

    /// One connection's registration with the server, as `register()` runs it.
    private func connect(deviceId: String = "d_phone") async throws {
        let api = APIClient(
            environment: OppiClientEnvironment(baseURL: URL(string: "http://localhost:7749")!, bearerToken: "sk_test"),
            configuration: configuration
        )
        try await PushRegistration.shared.register(
            api: api,
            serverId: serverId,
            deviceId: deviceId,
            relay: relay,
            environment: .sandbox,
            apnsToken: String(repeating: "a", count: 64),
            client: PushRelayClient(relay: relay, session: URLSession(configuration: configuration)),
            retryWithNewRelayRegistration: true
        )
    }

    private func withBackend(_ body: () async throws -> Void) async throws {
        BackendProtocol.backend = backend
        defer {
            BackendProtocol.backend = nil
            PushRelayRegistrationStore.delete(relay: relay, environment: .sandbox)
            PushSendTokenStore.delete(serverId: serverId)
            for record in PushSharedStore.allKeys() where record.serverId == serverId {
                if let keyId = try? record.keyId { PushSharedStore.deleteKey(keyId: keyId) }
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
