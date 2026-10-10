import Foundation

/// APNs environment of this build's signed `aps-environment` entitlement.
///
/// A device token only works on the APNs host that issued it, so the app sends this
/// with every token and the server routes each push to the matching host.
enum APNsEnvironment: String, Sendable, Equatable {
    case sandbox
    case production

    /// The running build's environment, or nil when its profile cannot be read.
    ///
    /// Development and ad hoc builds embed the provisioning profile that signed them, so
    /// read its `aps-environment`. App Store and TestFlight builds carry no embedded
    /// profile (Apple TN3125) and always use production APNs. Simulator builds embed no
    /// profile either; their remote notifications use the sandbox.
    static let current: Self? = {
        #if targetEnvironment(simulator)
        return .sandbox
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
            return .production
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return fromProvisioningProfile(data)
        #endif
    }()

    /// `Entitlements.aps-environment` from an `embedded.mobileprovision`: a CMS envelope
    /// around an XML property list.
    static func fromProvisioningProfile(_ data: Data) -> Self? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.upperBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data[start.lowerBound..<end.upperBound],
                  format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let value = entitlements["aps-environment"] as? String else {
            return nil
        }
        switch value {
        case "development": return .sandbox
        case "production": return .production
        default: return nil
        }
    }
}
