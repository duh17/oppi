import Foundation

/// Pairing and credential updates for the shared record in
/// `OppiCore/Client/PairedServer.swift`. The Share extension only reads.
extension PairedServer {
    var credentials: ServerCredentials {
        ServerCredentials(host: host, port: port, token: token, name: name, scheme: scheme,
                          serverFingerprint: id, tlsCertFingerprint: tlsCertFingerprint,
                          deviceCredential: deviceCredential)
    }

    init?(from credentials: ServerCredentials, sortOrder: Int = 0) {
        guard let fingerprint = credentials.normalizedServerFingerprint, !fingerprint.isEmpty else { return nil }
        self.id = fingerprint
        self.name = credentials.name
        self.host = credentials.host
        self.port = credentials.port
        self.scheme = credentials.scheme
        self.token = credentials.token
        self.tlsCertFingerprint = credentials.tlsCertFingerprint
        self.deviceCredential = credentials.deviceCredential
        self.addedAt = Date()
        self.sortOrder = sortOrder
        self.badgeIcon = nil
    }
    mutating func updateCredentials(
        from credentials: ServerCredentials,
        replacingStoredDeviceCredential: Bool = false
    ) {
        self.name = credentials.name
        self.host = credentials.host
        self.port = credentials.port
        self.scheme = credentials.scheme
        self.tlsCertFingerprint = credentials.tlsCertFingerprint
        if let incoming = credentials.deviceCredential {
            let merged = incoming.freshestMerge(with: deviceCredential ?? incoming)
            self.deviceCredential = merged
            self.token = merged.accessToken.isEmpty ? credentials.token : ""
        } else if replacingStoredDeviceCredential {
            // A user-initiated pair issued a fresh dt_ (or other static token).
            // Do not pin the record to a stored at_ that the new pair cannot use.
            self.token = credentials.token
            self.deviceCredential = nil
        } else if let stored = deviceCredential, !stored.accessToken.isEmpty {
            // Leftover dt_ must not wipe a replacement already held in memory.
            self.deviceCredential = stored
            self.token = ""
        } else {
            self.token = credentials.token
            self.deviceCredential = nil
        }
    }
}
