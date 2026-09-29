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
}

struct AuthDeviceListResponse: Decodable, Equatable, Sendable {
    let devices: [AuthDevice]
}
