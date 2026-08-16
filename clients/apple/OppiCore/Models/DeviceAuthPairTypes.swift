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
    let deviceToken: String?

    enum CodingKeys: String, CodingKey {
        case deviceId, accessToken, expiresAt, refreshChallenge, deviceToken
    }

    init(
        deviceId: String,
        accessToken: String,
        expiresAt: Int64,
        refreshChallenge: DeviceAuthChallenge? = nil,
        deviceToken: String? = nil
    ) {
        self.deviceId = deviceId
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshChallenge = refreshChallenge
        self.deviceToken = deviceToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let deviceToken = try container.decodeIfPresent(String.self, forKey: .deviceToken)
        let accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        self.deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
        self.accessToken = accessToken
        self.expiresAt = try container.decodeIfPresent(Int64.self, forKey: .expiresAt) ?? 0
        self.refreshChallenge = try container.decodeIfPresent(DeviceAuthChallenge.self, forKey: .refreshChallenge)
        self.deviceToken = deviceToken
        guard !accessToken.isEmpty || !(deviceToken ?? "").isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .accessToken,
                in: container,
                debugDescription: "Pairing response missing accessToken or deviceToken"
            )
        }
    }

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
