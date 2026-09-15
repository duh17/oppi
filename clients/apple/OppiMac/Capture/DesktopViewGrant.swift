import Foundation

/// In-memory `view` grant. Not persisted. Not `observeForModel`. Not `control`.
struct DesktopViewGrant: Equatable, Sendable {
    static let capabilityView = "view"
    static let ttl: TimeInterval = 15 * 60

    let grantId: UUID
    let capability: String
    let deviceId: String?
    let deviceName: String?
    let expiresAt: Date
    let createdAt: Date
}

enum DesktopViewGrantClaimFailure: Error, Equatable, Sendable {
    case unavailable
    case notBound
}

/// OppiMac-owned expiring view grant. One active grant. Fetch never creates one.
final class DesktopViewGrantGate: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: @Sendable () -> Date
    private var grant: DesktopViewGrant?

    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    @discardableResult
    func grantView() -> DesktopViewGrant {
        lock.lock()
        defer { lock.unlock() }
        if let grant, clock() < grant.expiresAt {
            return grant
        }
        let now = clock()
        let next = DesktopViewGrant(
            grantId: UUID(),
            capability: DesktopViewGrant.capabilityView,
            deviceId: nil,
            deviceName: nil,
            expiresAt: now.addingTimeInterval(DesktopViewGrant.ttl),
            createdAt: now
        )
        grant = next
        return next
    }

    func revoke() {
        lock.lock()
        grant = nil
        lock.unlock()
    }

    func current() -> DesktopViewGrant? {
        lock.lock()
        defer { lock.unlock() }
        return activeGrantLocked()
    }

    func claim(deviceId: String, deviceName: String?) -> Result<DesktopViewGrant, DesktopViewGrantClaimFailure> {
        lock.lock()
        defer { lock.unlock() }
        guard let active = activeGrantLocked() else {
            return .failure(.unavailable)
        }
        if let bound = active.deviceId {
            if bound == deviceId {
                let named = DesktopViewGrant(
                    grantId: active.grantId,
                    capability: active.capability,
                    deviceId: bound,
                    deviceName: deviceName ?? active.deviceName,
                    expiresAt: active.expiresAt,
                    createdAt: active.createdAt
                )
                grant = named
                return .success(named)
            }
            return .failure(.notBound)
        }
        let bound = DesktopViewGrant(
            grantId: active.grantId,
            capability: active.capability,
            deviceId: deviceId,
            deviceName: deviceName,
            expiresAt: active.expiresAt,
            createdAt: active.createdAt
        )
        grant = bound
        return .success(bound)
    }

    private func activeGrantLocked() -> DesktopViewGrant? {
        guard let grant else { return nil }
        if clock() >= grant.expiresAt {
            self.grant = nil
            return nil
        }
        return grant
    }
}

enum DesktopViewGrantHTTP {
    static let deviceID = "X-Oppi-Device-ID"
    static let deviceName = "X-Oppi-Device-Name"
    static let missingDeviceIDBody = "missing device id\n"
    static let unavailableBody = "view grant unavailable\n"
    static let notBoundBody = "view session not granted\n"

    static func remainingPhrase(expiresAt: Date, now: Date) -> String {
        let seconds = expiresAt.timeIntervalSince(now)
        if seconds <= 0 { return "expired" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes == 1 { return "1 min remaining" }
        return "\(minutes) min remaining"
    }

    static func deviceID(from headers: [String: String]) -> String? {
        guard let raw = headers[deviceID.lowercased()] else { return nil }
        return headerDeviceID(raw)
    }

    static func deviceName(from headers: [String: String]) -> String? {
        guard let raw = headers[deviceName.lowercased()] else { return nil }
        return headerDeviceName(raw)
    }

    static func headerDeviceID(_ raw: String) -> String? {
        let collapsed = raw
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.isEmpty || collapsed.count > 128 { return nil }
        return collapsed
    }

    static func headerDeviceName(_ name: String) -> String? {
        let collapsed = name
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.isEmpty { return nil }
        if collapsed.unicodeScalars.contains(where: { $0.value > 255 }) { return nil }
        if collapsed.count <= 120 { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: 120)
        return String(collapsed[..<end])
    }
}

enum DesktopViewGrantJSON {
    static func body(for grant: DesktopViewGrant) -> Data? {
        guard let deviceId = grant.deviceId else { return nil }
        let payload: [String: String] = [
            "grantId": grant.grantId.uuidString,
            "capability": grant.capability,
            "deviceId": deviceId,
            "expiresAt": DesktopStillShareHTTP.date(grant.expiresAt),
            "caption": DesktopCaptureCopy.viewSessionCaption,
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [])
    }
}
