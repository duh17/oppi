import Foundation

enum PairedDeviceRoster {
    struct Row: Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let isThisDevice: Bool
        let canRevoke: Bool
        let lastUsedAt: Int64?
        let createdAt: Int64
        let pairingMethod: String?
        let pairingSource: String?
        let caption: String
    }

    static func rows(from devices: [AuthDevice], currentDeviceId: String?, now: Date = Date()) -> [Row] {
        let currentId = normalizedDeviceId(currentDeviceId)
        return devices
            .filter { $0.revokedAt == nil }
            .map { device in
                let trimmed = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let isThisDevice = device.id == currentId
                return Row(
                    id: device.id,
                    title: trimmed.isEmpty ? "Device" : trimmed,
                    isThisDevice: isThisDevice,
                    canRevoke: !isThisDevice,
                    lastUsedAt: device.lastUsedAt,
                    createdAt: device.createdAt,
                    pairingMethod: nonempty(device.pairingMethod),
                    pairingSource: nonempty(device.pairingSource),
                    caption: caption(
                        isThisDevice: isThisDevice,
                        pairingMethod: nonempty(device.pairingMethod),
                        pairingSource: nonempty(device.pairingSource),
                        createdAt: device.createdAt,
                        now: now
                    )
                )
            }
            .sorted(by: Self.isSortedBefore)
    }

    static func caption(
        isThisDevice: Bool,
        pairingMethod: String?,
        pairingSource: String?,
        createdAt: Int64,
        now _: Date = Date()
    ) -> String {
        var parts: [String] = []
        if isThisDevice {
            parts.append("This device")
        }
        if let pairingMethod {
            parts.append(PairingApprovalPromptFormatting.method(pairingMethod))
        }
        if let pairingSource {
            parts.append(pairingSource)
        }
        parts.append(enrolledPhrase(createdAt: createdAt))
        return parts.joined(separator: " · ")
    }

    private static func enrolledPhrase(createdAt: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(createdAt) / 1_000)
        return "Enrolled \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private static func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedDeviceId(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isSortedBefore(_ lhs: Row, _ rhs: Row) -> Bool {
        if lhs.isThisDevice != rhs.isThisDevice {
            return lhs.isThisDevice
        }
        let leftUsed = lhs.lastUsedAt ?? Int64.min
        let rightUsed = rhs.lastUsedAt ?? Int64.min
        if leftUsed != rightUsed {
            return leftUsed > rightUsed
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id < rhs.id
    }
}

enum ServerDetailPairedDevicesState: Equatable {
    case loading
    case loaded(rows: [PairedDeviceRoster.Row], error: String?)
    case failed(String)

    static func resolve(
        devices: [AuthDevice]?,
        currentDeviceId: String?,
        isLoading: Bool,
        error: String?
    ) -> Self {
        if let devices {
            return .loaded(
                rows: PairedDeviceRoster.rows(from: devices, currentDeviceId: currentDeviceId),
                error: error
            )
        }
        if isLoading {
            return .loading
        }
        return .failed(error ?? "Paired devices are unavailable")
    }
}
