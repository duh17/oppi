import CryptoKit
import Foundation

/// An SSH server host key in OpenSSH public-key form (`ssh-ed25519 AAAA…`).
struct SSHHostKey: Equatable, Sendable {
    let openSSH: String

    var algorithm: String {
        String(openSSH.split(separator: " ", maxSplits: 1).first ?? "")
    }

    /// `SHA256:<base64, no padding>`, matching `ssh-keygen -lf`.
    var fingerprint: String {
        let parts = openSSH.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            return openSSH
        }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }
}

enum SSHHostKeyVerdict: Equatable, Sendable {
    case trusted
    case unknown
    case mismatch(saved: SSHHostKey)

    static func evaluate(saved: SSHHostKey?, presented: SSHHostKey) -> Self {
        guard let saved else { return .unknown }
        return saved == presented ? .trusted : .mismatch(saved: saved)
    }
}

/// Host keys the user trusted, keyed by the directly dialed SSH host and port.
struct SSHKnownHosts {
    static let storageKey = "\(AppIdentifiers.subsystem).ssh.knownHosts"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func savedKey(host: String, port: UInt16) -> SSHHostKey? {
        entries[Self.entryKey(host: host, port: port)].map(SSHHostKey.init(openSSH:))
    }

    func verdict(host: String, port: UInt16, presented: SSHHostKey) -> SSHHostKeyVerdict {
        SSHHostKeyVerdict.evaluate(saved: savedKey(host: host, port: port), presented: presented)
    }

    func trust(_ key: SSHHostKey, host: String, port: UInt16) {
        var entries = entries
        entries[Self.entryKey(host: host, port: port)] = key.openSSH
        defaults.set(entries, forKey: Self.storageKey)
    }

    func forget(host: String, port: UInt16) {
        var entries = entries
        entries.removeValue(forKey: Self.entryKey(host: host, port: port))
        defaults.set(entries, forKey: Self.storageKey)
    }

    private var entries: [String: String] {
        defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }

    /// DNS names are case-insensitive and may carry the root dot.
    static func entryKey(host: String, port: UInt16) -> String {
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        return "\(name):\(port)"
    }
}
