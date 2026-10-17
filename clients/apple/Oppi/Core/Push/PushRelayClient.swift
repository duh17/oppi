import CryptoKit
import DeviceCheck
import Foundation
import Security

/// App side of relay API v1 (protocol/push/spec.md §3.1): register this device's APNs token,
/// proving a genuine Oppi build with App Attest where the device supports it, and mint one
/// send permission per paired server. The relay never sees a push key or push content.
struct PushRelayClient: Sendable {
    let relay: URL
    var session: URLSession = .shared
    var appAttest: AppAttestProviding = DeviceAppAttest()

    enum RelayError: Error, Equatable {
        /// The relay no longer holds this registration: register again.
        case gone
        case tooManyPermissions
        case rejected(Int, String?)
        case invalidResponse
    }

    struct Registration: Codable, Equatable, Sendable {
        let relay: String
        let environment: String
        let apnsToken: String
        let registrationId: String
        let registrationSecret: String
        /// Set when App Attest attested this registration; signs later requests.
        let appAttestKeyId: String?
    }

    // MARK: - Calls

    func register(apnsToken: String, environment: APNsEnvironment) async throws -> Registration {
        struct Challenge: Decodable { let challenge: String }
        let challenge: Challenge = try await decode(send("POST", path: "/v1/challenge", body: Data("{}".utf8)))

        var attestation: [String: String]?
        var attestKeyId: String?
        if appAttest.isSupported {
            let clientData = "oppi-relay-registration-v1\n\(challenge.challenge)\n\(apnsToken)\n\(environment.rawValue)"
            let keyId = try await appAttest.generateKey()
            let object = try await appAttest.attestKey(keyId, clientDataHash: Data(SHA256.hash(data: Data(clientData.utf8))))
            attestation = ["keyId": keyId, "object": object.base64EncodedString()]
            attestKeyId = keyId
        }
        // `attestation: null` is the unsupported-device path, which the relay accepts only in
        // sandbox (development builds and Simulator), with lower limits.
        let body = try JSONSerialization.data(withJSONObject: [
            "challenge": challenge.challenge,
            "apnsToken": apnsToken,
            "environment": environment.rawValue,
            "attestation": attestation.map { $0 as Any } ?? NSNull(),
        ])
        struct Response: Decodable { let registrationId: String; let registrationSecret: String }
        let response: Response = try await decode(send("POST", path: "/v1/registrations", body: body))
        return Registration(
            relay: relay.absoluteString,
            environment: environment.rawValue,
            apnsToken: apnsToken,
            registrationId: response.registrationId,
            registrationSecret: response.registrationSecret,
            appAttestKeyId: attestKeyId
        )
    }

    /// `liveActivitySlot` names this server's Live Activity at the relay; without one the
    /// server can push alerts but cannot start or update the card.
    func mintSendToken(
        _ registration: Registration,
        liveActivitySlot: String?
    ) async throws -> (permissionId: String, sendToken: String) {
        struct Response: Decodable { let permissionId: String; let sendToken: String }
        let path = "/v1/registrations/\(registration.registrationId)/permissions"
        let body = try JSONSerialization.data(
            withJSONObject: liveActivitySlot.map { ["liveActivitySlot": $0] } ?? [:]
        )
        let response: Response = try await decode(
            sendAuthenticated("POST", path: path, body: body, registration: registration)
        )
        return (response.permissionId, response.sendToken)
    }

    /// The registration and permission a send token (`osp1.<registrationId>.<permissionId>.<secret>`)
    /// belongs to.
    static func permission(ofSendToken sendToken: String) -> (registrationId: String, permissionId: String)? {
        let parts = sendToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "osp1" else { return nil }
        return (String(parts[1]), String(parts[2]))
    }

    /// The phone's whole Live Activity token state; the relay replaces what it held.
    struct LiveActivityState: Encodable, Equatable, Sendable {
        struct Activity: Encodable, Equatable, Sendable {
            let slot: String
            let token: String
        }

        let startToken: String?
        let activities: [Activity]

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            // The relay requires the key, with null to clear.
            try container.encode(startToken, forKey: .startToken)
            try container.encode(activities, forKey: .activities)
        }

        private enum CodingKeys: String, CodingKey { case startToken, activities }
    }

    func putLiveActivity(_ state: LiveActivityState, registration: Registration) async throws {
        let path = "/v1/registrations/\(registration.registrationId)/live-activity"
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        _ = try await sendAuthenticated("PUT", path: path, body: encoder.encode(state), registration: registration)
    }

    func deletePermission(_ permissionId: String, registration: Registration) async throws {
        let path = "/v1/registrations/\(registration.registrationId)/permissions/\(permissionId)"
        _ = try await sendAuthenticated("DELETE", path: path, body: Data(), registration: registration)
    }

    func deleteRegistration(_ registration: Registration) async throws {
        let path = "/v1/registrations/\(registration.registrationId)"
        _ = try await sendAuthenticated("DELETE", path: path, body: Data(), registration: registration)
    }

    // MARK: - Transport

    private func sendAuthenticated(
        _ method: String,
        path: String,
        body: Data,
        registration: Registration
    ) async throws -> Data {
        var headers = ["Authorization": "Bearer \(registration.registrationSecret)"]
        if let keyId = registration.appAttestKeyId {
            let bodyHash = Data(SHA256.hash(data: body)).base64URLEncodedString
            let clientData = "oppi-relay-request-v1\n\(method)\n\(path)\n\(bodyHash)"
            let assertion = try await appAttest.generateAssertion(
                keyId,
                clientDataHash: Data(SHA256.hash(data: Data(clientData.utf8)))
            )
            headers["X-Oppi-Assertion"] = assertion.base64EncodedString()
        }
        return try await send(method, path: path, body: body, headers: headers)
    }

    private func send(_ method: String, path: String, body: Data, headers: [String: String] = [:]) async throws -> Data {
        guard let url = URL(string: path, relativeTo: relay) else { throw RelayError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        if !body.isEmpty {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw RelayError.invalidResponse }
        switch status {
        case 200..<300: return data
        case 410: throw RelayError.gone
        case 409: throw RelayError.tooManyPermissions
        default:
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw RelayError.rejected(status, code)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw RelayError.invalidResponse }
    }
}

/// App Attest, behind a seam so tests and the simulator (unsupported) take the same path.
protocol AppAttestProviding: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

struct DeviceAppAttest: AppAttestProviding {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
    }
}

/// The send token this phone gave each paired server, in this app's keychain, so the next
/// connection re-sends it instead of minting another permission.
enum PushSendTokenStore {
    struct Entry: Codable, Equatable, Sendable {
        let sendToken: String
        /// The server's id for this phone's pairing. A server releases the token of a device it
        /// revokes, so a new pairing never reuses it.
        let deviceId: String
    }

    private static let service = "\(SharedConstants.keychainService).push-send-token"

    private static func query(serverId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: SharedConstants.keychainAccessGroup,
            kSecAttrAccount as String: serverId,
        ]
    }

    static func load(serverId: String) -> Entry? {
        var lookup = query(serverId: serverId)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    static func save(_ entry: Entry, serverId: String) throws {
        let key = query(serverId: serverId)
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(entry),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw PushStoreError.keychain(update) }
        let status = SecItemAdd(key.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else { throw PushStoreError.keychain(status) }
    }

    static func delete(serverId: String) {
        SecItemDelete(query(serverId: serverId) as CFDictionary)
    }
}

/// The relay registration for each relay and APNs environment, in this app's keychain.
enum PushRelayRegistrationStore {
    private static let service = "\(SharedConstants.keychainService).push-relay"

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: SharedConstants.keychainAccessGroup,
            kSecAttrAccount as String: account,
        ]
    }

    static func account(relay: URL, environment: APNsEnvironment) -> String {
        "\(environment.rawValue) \(relay.absoluteString)"
    }

    static func load(relay: URL, environment: APNsEnvironment) -> PushRelayClient.Registration? {
        var lookup = query(account: account(relay: relay, environment: environment))
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(PushRelayClient.Registration.self, from: data)
    }

    static func save(_ registration: PushRelayClient.Registration, relay: URL, environment: APNsEnvironment) throws {
        let key = query(account: account(relay: relay, environment: environment))
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(registration),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw PushStoreError.keychain(update) }
        let status = SecItemAdd(key.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else { throw PushStoreError.keychain(status) }
    }

    static func delete(relay: URL, environment: APNsEnvironment) {
        SecItemDelete(query(account: account(relay: relay, environment: environment)) as CFDictionary)
    }

    /// Every stored registration, for calls that go to each relay this phone uses.
    static func all() -> [PushRelayClient.Registration] {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: SharedConstants.keychainAccessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let items = result as? [Data] else { return [] }
        return items.compactMap { try? JSONDecoder().decode(PushRelayClient.Registration.self, from: $0) }
    }
}
