import Foundation

struct PairDeviceRequest: Encodable {
    let pairingToken: String
    let deviceName: String?
    let devicePublicKey: DevicePublicKey
}

struct TailscalePairingInvite: Decodable, Equatable, Sendable {
    let name: String
    let pairingToken: String
    let fingerprint: String
    let tlsCertFingerprint: String?
    let host: String
    let port: Int
    let scheme: String
    let inviteURL: String
}

struct PairDeviceResponse: Decodable {
    let deviceId: String
    let accessToken: String
    let expiresAt: Int64
    let refreshChallenge: DeviceAuthChallenge?

    var deviceCredential: DeviceCredential? {
        guard !accessToken.isEmpty, !deviceId.isEmpty else { return nil }
        return DeviceCredential(
            deviceId: deviceId,
            accessToken: accessToken,
            expiresAt: expiresAt,
            refreshChallenge: refreshChallenge
        )
    }
}
