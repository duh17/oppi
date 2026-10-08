import Foundation

enum NearbyPairingConstants {
    static let serviceType = "oppi-pair"

    enum DiscoveryKey {
        static let hostLabel = "host"
        static let version = "ver"
    }
}

extension Bundle {
    var nearbyPairingVersionString: String? {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
