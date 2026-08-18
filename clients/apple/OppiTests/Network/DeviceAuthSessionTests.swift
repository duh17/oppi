import CryptoKit
import Foundation
import Testing
@testable import Oppi

private actor FakeDeviceAuthTransport: DeviceAuthTransport {
    var challengeCount = 0
    var refreshCalls: [(nonce: String, signature: String)] = []

    private let challenges: [DeviceAuthChallenge]
    private let refreshResult: DeviceAuthRefreshResult
    private var refreshError: DeviceAuthError?

    init(
        challenges: [DeviceAuthChallenge],
        refreshResult: DeviceAuthRefreshResult,
        refreshError: DeviceAuthError? = nil
    ) {
        self.challenges = challenges
        self.refreshResult = refreshResult
        self.refreshError = refreshError
    }

    func requestChallenge(deviceId _: String) async throws -> DeviceAuthChallenge {
        let index = min(challengeCount, challenges.count - 1)
        challengeCount += 1
        return challenges[index]
    }

    func refresh(
        deviceId _: String,
        nonce: String,
        signature: String
    ) async throws -> DeviceAuthRefreshResult {
        refreshCalls.append((nonce: nonce, signature: signature))
        if let error = refreshError {
            refreshError = nil
            throw error
        }
        return refreshResult
    }
}

private func decodeBase64URL(_ value: String) -> Data {
    var normalized = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while normalized.count % 4 != 0 { normalized += "=" }
    return Data(base64Encoded: normalized)!
}

private func p256PublicKey(_ jwk: DevicePublicKey) throws -> P256.Signing.PublicKey {
    let raw = Data([0x04]) + decodeBase64URL(jwk.x) + decodeBase64URL(jwk.y)
    return try P256.Signing.PublicKey(x963Representation: raw)
}

@Suite("DeviceAuthSession")
struct DeviceAuthSessionTests {
    @Test func returnsCurrentTokenBeforeExpiry() async throws {
        let key = InMemoryP256DeviceKey()
        let transport = FakeDeviceAuthTransport(
            challenges: [DeviceAuthChallenge(nonce: "n1", audience: "oppi:refresh:v1", expiresAt: 2_000_000)],
            refreshResult: DeviceAuthRefreshResult(accessToken: "at_new", expiresAt: 2_000_000, refreshChallenge: nil)
        )
        let now = Date(timeIntervalSince1970: 1_000_000)
        let session = DeviceAuthSession(
            deviceId: "dev_1",
            key: key,
            accessToken: "at_valid",
            expiresAt: now.addingTimeInterval(600),
            transport: transport,
            clock: { now }
        )

        let token = try await session.currentAccessToken()
        #expect(token == "at_valid")
        #expect(await transport.challengeCount == 0)
        #expect(await transport.refreshCalls.isEmpty)
    }

    @Test func emptyAccessTokenRefreshesInsteadOfReturningEmpty() async throws {
        let key = InMemoryP256DeviceKey()
        let transport = FakeDeviceAuthTransport(
            challenges: [DeviceAuthChallenge(nonce: "n1", audience: "oppi:refresh:v1", expiresAt: 2_000_000)],
            refreshResult: DeviceAuthRefreshResult(accessToken: "at_refreshed", expiresAt: 2_000_000, refreshChallenge: nil)
        )
        let now = Date(timeIntervalSince1970: 1_000_000)
        let session = DeviceAuthSession(
            deviceId: "dev_1",
            key: key,
            accessToken: "",
            expiresAt: now.addingTimeInterval(600),
            transport: transport,
            clock: { now }
        )

        let token = try await session.currentAccessToken()
        #expect(token == "at_refreshed")
        #expect(await transport.challengeCount == 1)
        #expect(await transport.refreshCalls.count == 1)
    }

    @Test func singleFlightRefreshCoalescesConcurrentCallers() async throws {
        let key = InMemoryP256DeviceKey()
        let transport = FakeDeviceAuthTransport(
            challenges: [DeviceAuthChallenge(nonce: "n1", audience: "oppi:refresh:v1", expiresAt: 2_000_000)],
            refreshResult: DeviceAuthRefreshResult(accessToken: "at_refreshed", expiresAt: 2_000_000, refreshChallenge: nil)
        )
        let now = Date(timeIntervalSince1970: 1_000_000)
        let session = DeviceAuthSession(
            deviceId: "dev_1",
            key: key,
            accessToken: "at_expired",
            expiresAt: now.addingTimeInterval(-1),
            transport: transport,
            clock: { now }
        )

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask { try await session.currentAccessToken() }
            }
            var collected: [String] = []
            for try await token in group { collected.append(token) }
            return collected
        }

        #expect(tokens.allSatisfy { $0 == "at_refreshed" })
        #expect(await transport.challengeCount == 1)
        #expect(await transport.refreshCalls.count == 1)
    }

    @Test func retriesOnceOnStaleNonce() async throws {
        let key = InMemoryP256DeviceKey()
        let transport = FakeDeviceAuthTransport(
            challenges: [
                DeviceAuthChallenge(nonce: "stale", audience: "oppi:refresh:v1", expiresAt: 2_000_000),
                DeviceAuthChallenge(nonce: "fresh", audience: "oppi:refresh:v1", expiresAt: 2_000_000),
            ],
            refreshResult: DeviceAuthRefreshResult(accessToken: "at_refreshed", expiresAt: 2_000_000, refreshChallenge: nil),
            refreshError: .refreshRejected(code: "nonce_reused")
        )
        let now = Date(timeIntervalSince1970: 1_000_000)
        let session = DeviceAuthSession(
            deviceId: "dev_1",
            key: key,
            accessToken: "at_expired",
            expiresAt: now.addingTimeInterval(-1),
            transport: transport,
            clock: { now }
        )

        let token = try await session.currentAccessToken()
        #expect(token == "at_refreshed")
        #expect(await transport.challengeCount == 2)
        #expect(await transport.refreshCalls.count == 2)
    }

    @Test func signsChallengeOverAudienceDotNonce() async throws {
        let key = InMemoryP256DeviceKey()
        let transport = FakeDeviceAuthTransport(
            challenges: [DeviceAuthChallenge(nonce: "n1", audience: "oppi:refresh:v1", expiresAt: 2_000_000)],
            refreshResult: DeviceAuthRefreshResult(accessToken: "at_refreshed", expiresAt: 2_000_000, refreshChallenge: nil)
        )
        let now = Date(timeIntervalSince1970: 1_000_000)
        let session = DeviceAuthSession(
            deviceId: "dev_1",
            key: key,
            accessToken: "at_expired",
            expiresAt: now.addingTimeInterval(-1),
            transport: transport,
            clock: { now }
        )

        _ = try await session.currentAccessToken()

        let call = await transport.refreshCalls.first
        #expect(call != nil)
        let nonce = try #require(call?.nonce)
        let signature = try #require(call?.signature)

        // The signature must not embed the access token.
        #expect(!signature.contains("at_refreshed"))
        #expect(!nonce.contains("at_refreshed"))

        // Reconstruct the public key and verify the raw 64-byte signature.
        let publicKey = try p256PublicKey(key.publicKey)
        let input = Data("oppi:refresh:v1.\(nonce)".utf8)
        let sigBytes = decodeBase64URL(signature)
        #expect(sigBytes.count == 64)
        let signatureObject = try P256.Signing.ECDSASignature(rawRepresentation: sigBytes)
        #expect(publicKey.isValidSignature(signatureObject, for: input))
    }

    @Test func doesNotRefreshWhenTransportRejectsPermanently() async throws {
        let key = InMemoryP256DeviceKey()
        let transport = FakeDeviceAuthTransport(
            challenges: [DeviceAuthChallenge(nonce: "n1", audience: "oppi:refresh:v1", expiresAt: 2_000_000)],
            refreshResult: DeviceAuthRefreshResult(accessToken: "at_refreshed", expiresAt: 2_000_000, refreshChallenge: nil),
            refreshError: .refreshRejected(code: "revoked")
        )
        let now = Date(timeIntervalSince1970: 1_000_000)
        let session = DeviceAuthSession(
            deviceId: "dev_1",
            key: key,
            accessToken: "at_expired",
            expiresAt: now.addingTimeInterval(-1),
            transport: transport,
            clock: { now }
        )

        do {
            _ = try await session.currentAccessToken()
            Issue.record("expected refresh to fail")
        } catch let error as DeviceAuthError {
            #expect(error == .refreshRejected(code: "revoked"))
        }
        // No retry for non-retryable failures.
        #expect(await transport.challengeCount == 1)
        #expect(await transport.refreshCalls.count == 1)
    }

    @Test func leftoverIsUsableWithoutExpiryAndRejectsKnownExpired() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(DeviceAuthSession.leftoverIsUsable(token: "dt_leftover", expiresAtMs: nil, now: now))
        #expect(!DeviceAuthSession.leftoverIsUsable(token: "", expiresAtMs: nil, now: now))
        let expiredMs = Int64((now.timeIntervalSince1970 - 120) * 1000)
        #expect(!DeviceAuthSession.leftoverIsUsable(
            token: "at_expired",
            expiresAtMs: expiredMs,
            now: now
        ))
        let futureMs = Int64((now.timeIntervalSince1970 + 600) * 1000)
        #expect(DeviceAuthSession.leftoverIsUsable(
            token: "at_fresh",
            expiresAtMs: futureMs,
            now: now
        ))
    }

    @Test func replacingStaleTokenReusesNewerEpochWithoutNetwork() async throws {
        let key = InMemoryP256DeviceKey()
        let transport = FakeDeviceAuthTransport(
            challenges: [DeviceAuthChallenge(nonce: "n1", audience: "oppi:refresh:v1", expiresAt: 2_000_000)],
            refreshResult: DeviceAuthRefreshResult(accessToken: "at_should_not_mint", expiresAt: 2_000_000, refreshChallenge: nil)
        )
        let now = Date(timeIntervalSince1970: 1_000_000)
        let session = DeviceAuthSession(
            deviceId: "dev_1",
            key: key,
            accessToken: "at_current",
            expiresAt: now.addingTimeInterval(600),
            transport: transport,
            clock: { now }
        )

        let token = try await session.refreshAccessToken(replacing: "at_evicted")
        #expect(token == "at_current")
        #expect(await transport.challengeCount == 0)
        #expect(await transport.refreshCalls.isEmpty)
    }
}
