import UIKit

/// Resolves the name this device sends to `POST /pair`.
///
/// Since iOS 16, `UIDevice.current.name` returns only the model ("iPhone") unless the app holds
/// Apple's restricted `user-assigned-device-name` entitlement, which needs Apple approval and a
/// provisioning change. Without it, two phones would both appear as "iPhone" in the paired-device
/// roster, so a generic name gets a short suffix from `identifierForVendor` ("iPhone (A3F9)").
/// That id is per device and vendor: it survives reinstall while another app from the same vendor
/// stays installed, and differs between devices.
enum PairingDeviceName {
    static let maxLength = 64
    private static let suffixLength = 4

    /// Trims, drops blank names, and caps length. When `model` and `vendorId` are supplied and the
    /// name is just the generic model name, appends a short vendor-id suffix so rows stay distinct.
    static func resolved(_ raw: String?, model: String? = nil, vendorId: UUID? = nil) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        var name = String(trimmed.prefix(maxLength))
        if let model, let vendorId, name.caseInsensitiveCompare(model) == .orderedSame {
            let suffix = vendorId.uuidString.prefix(suffixLength)
            name = "\(String(name.prefix(maxLength - suffixLength - 3))) (\(suffix))"
        }
        return name
    }

    @MainActor
    static func current() -> String? {
        let device = UIDevice.current
        return resolved(device.name, model: device.model, vendorId: device.identifierForVendor)
    }
}
