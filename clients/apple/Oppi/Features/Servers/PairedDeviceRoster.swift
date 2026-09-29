import Foundation

enum PairedDeviceRoster {
    struct Row: Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let isThisDevice: Bool
        let canRevoke: Bool
        let lastUsedAt: Int64?
        let createdAt: Int64
    }

    static func rows(from devices: [AuthDevice], currentDeviceId: String?) -> [Row] {
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
                    createdAt: device.createdAt
                )
            }
            .sorted(by: Self.isSortedBefore)
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
