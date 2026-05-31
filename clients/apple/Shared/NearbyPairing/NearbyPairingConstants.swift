import Foundation

enum NearbyPairingConstants {
    static let serviceType = "oppi-pair"

    enum DiscoveryKey {
        static let hostLabel = "host"
        static let version = "ver"
    }
}

struct NearbyPairingDiscoveryMetadata: Sendable, Equatable {
    let hostLabel: String?
    let version: String?

    init(discoveryInfo: [String: String]?) {
        hostLabel = Self.sanitizedValue(
            discoveryInfo?[NearbyPairingConstants.DiscoveryKey.hostLabel]
        )
        version = Self.sanitizedValue(
            discoveryInfo?[NearbyPairingConstants.DiscoveryKey.version]
        )
    }

    var displayName: String? {
        hostLabel
    }

    private static func sanitizedValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Bundle {
    var nearbyPairingVersionString: String? {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
