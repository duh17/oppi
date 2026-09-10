import Foundation

struct PairDeviceRequest: Encodable {
    let pairingToken: String
    let deviceName: String?
    let devicePublicKey: DevicePublicKey
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
