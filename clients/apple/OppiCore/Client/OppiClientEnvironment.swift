import Foundation

/// Platform-neutral inputs for the shared Apple API and stream clients.
///
/// This value describes which Oppi server the client core should talk to. It does
/// not own pairing UI, keychain storage, certificate trust evaluation, or the Mac
/// local server process; those stay in platform adapters.
struct OppiClientEnvironment: Equatable, Sendable {
    enum ProcessOwnership: String, Equatable, Sendable {
        /// The app connects to a server it does not launch or stop.
        case clientOnly

        /// A platform adapter owns the same-machine server process lifecycle.
        case ownedLocalProcess

        /// A platform adapter attaches to a same-machine process it did not launch.
        case attachedLocalProcess
    }

    let baseURL: URL
    let bearerToken: String
    let pinnedCertificateFingerprint: String?
    let tlsServerName: String?
    let processOwnership: ProcessOwnership

    init(
        baseURL: URL,
        bearerToken: String,
        pinnedCertificateFingerprint: String? = nil,
        tlsServerName: String? = nil,
        processOwnership: ProcessOwnership = .clientOnly
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.pinnedCertificateFingerprint = pinnedCertificateFingerprint
        self.tlsServerName = tlsServerName
        self.processOwnership = processOwnership
    }

    var requiresLocalProcessAdapter: Bool {
        processOwnership != .clientOnly
    }

    var usesPinnedCertificate: Bool {
        pinnedCertificateFingerprint?.isEmpty == false
    }
}
