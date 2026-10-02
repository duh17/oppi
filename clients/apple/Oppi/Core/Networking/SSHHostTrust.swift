import CryptoKit
import Foundation
import Security

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
    private let keychain: SSHKeychain

    init(keychain: SSHKeychain = SSHKeychain()) {
        self.keychain = keychain
    }

    func savedKey(host: String, port: UInt16) throws -> SSHHostKey? {
        guard let data = try keychain.load(account: account(host: host, port: port)) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else { throw SSHKeychainError.status(errSecDecode) }
        return SSHHostKey(openSSH: value)
    }

    func verdict(host: String, port: UInt16, presented: SSHHostKey) throws -> SSHHostKeyVerdict {
        SSHHostKeyVerdict.evaluate(saved: try savedKey(host: host, port: port), presented: presented)
    }

    func trust(_ key: SSHHostKey, host: String, port: UInt16) throws {
        try keychain.save(Data(key.openSSH.utf8), account: account(host: host, port: port))
    }

    func forget(host: String, port: UInt16) throws {
        try keychain.delete(account: account(host: host, port: port))
    }

    private func account(host: String, port: UInt16) -> String {
        "host:" + Self.entryKey(host: host, port: port)
    }

    /// DNS names are case-insensitive and may carry the root dot.
    static func entryKey(host: String, port: UInt16) -> String {
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        return "\(name):\(port)"
    }
}
