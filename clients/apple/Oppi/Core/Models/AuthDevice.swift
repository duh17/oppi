import Foundation

/// One paired-device row from `GET /auth/devices`.
struct AuthDevice: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let scope: String
    let createdAt: Int64
    let lastUsedAt: Int64?
    let revokedAt: Int64?
    let keyEnrolled: Bool?
    let pairingMethod: String?
    let pairingSource: String?
    let approvedByDeviceId: String?

    init(
        id: String,
        name: String,
        scope: String,
        createdAt: Int64,
        lastUsedAt: Int64?,
        revokedAt: Int64?,
        keyEnrolled: Bool?,
        pairingMethod: String? = nil,
        pairingSource: String? = nil,
        approvedByDeviceId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.scope = scope
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.revokedAt = revokedAt
        self.keyEnrolled = keyEnrolled
        self.pairingMethod = pairingMethod
        self.pairingSource = pairingSource
        self.approvedByDeviceId = approvedByDeviceId
    }
}

struct AuthDeviceListResponse: Decodable, Equatable, Sendable {
    let devices: [AuthDevice]
}
