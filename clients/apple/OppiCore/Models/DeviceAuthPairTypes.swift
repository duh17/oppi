import Foundation

struct PairDeviceRequest: Encodable {
    let pairingToken: String
    let deviceName: String?
    let devicePublicKey: DevicePublicKey
}

struct MigrateDeviceRequest: Encodable {
    let devicePublicKey: DevicePublicKey
    let deviceName: String?
}

struct PairDeviceResponse: Decodable {
    let deviceId: String
    let accessToken: String
    let expiresAt: Int64
    let refreshChallenge: DeviceAuthChallenge?

    init(
        deviceId: String,
        accessToken: String,
        expiresAt: Int64,
        refreshChallenge: DeviceAuthChallenge? = nil
    ) {
        self.deviceId = deviceId
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshChallenge = refreshChallenge
    }

    var deviceCredential: DeviceCredential {
        DeviceCredential(
            deviceId: deviceId,
            accessToken: accessToken,
            expiresAt: expiresAt,
            refreshChallenge: refreshChallenge
        )
    }
}
