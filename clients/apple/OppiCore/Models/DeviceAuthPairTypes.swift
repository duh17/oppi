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

struct PairingApprovalRequired: Decodable, Equatable, Sendable {
    let status: String
    let approvalId: String
    let pendingToken: String
    let expiresAt: Int64
}

struct PairingApprovalPendingStatus: Decodable, Equatable, Sendable {
    let status: String
    let expiresAt: Int64
}

enum PairDeviceStart: Sendable {
    case enrolled(PairDeviceResponse)
    case approvalRequired(PairingApprovalRequired)
}

enum PairingApprovalPoll: Sendable {
    case enrolled(PairDeviceResponse)
    case pending(expiresAt: Int64)
}

struct PendingPairingApproval: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let deviceName: String
    let method: String
    let source: String?
    let requestedAt: Int64
    let expiresAt: Int64
    let keyThumbprint: String
}

struct PairingApprovalListResponse: Decodable, Equatable, Sendable {
    let approvals: [PendingPairingApproval]
}

enum PairingApprovalSettlement: String, Decodable, Equatable, Sendable {
    case approved, denied, expired
}

enum PairingApprovalSigning {
    static func message(approvalId: String, keyThumbprint: String) -> String {
        "oppi:pair-approve:v1.\(approvalId).\(keyThumbprint)"
    }

    static func signatureBase64URL(
        key: any DeviceKey,
        approvalId: String,
        keyThumbprint: String
    ) throws -> String {
        let data = try key.sign(Data(message(approvalId: approvalId, keyThumbprint: keyThumbprint).utf8))
        return data.base64URLEncodedString
    }
}
