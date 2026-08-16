import Foundation

/// Persisted server-issued HTTPS device credential. The signing key itself is
/// kept separately by DeviceKeyStore and never serialized here.
public struct DeviceCredential: Codable, Sendable, Equatable, Hashable {
    public let deviceId: String
    public let accessToken: String
    public let expiresAt: Int64
    public let refreshChallenge: DeviceAuthChallenge?

    public init(
        deviceId: String,
        accessToken: String,
        expiresAt: Int64,
        refreshChallenge: DeviceAuthChallenge?
    ) {
        self.deviceId = deviceId
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshChallenge = refreshChallenge
    }

    func updatingAccessToken(
        _ token: String,
        expiresAt: Int64,
        refreshChallenge: DeviceAuthChallenge?
    ) -> DeviceCredential {
        DeviceCredential(
            deviceId: deviceId,
            accessToken: token,
            expiresAt: expiresAt,
            refreshChallenge: refreshChallenge
        )
    }

    func freshestMerge(with stored: DeviceCredential) -> DeviceCredential {
        guard stored.deviceId == deviceId else { return self }
        return expiresAt >= stored.expiresAt ? self : stored
    }
}
