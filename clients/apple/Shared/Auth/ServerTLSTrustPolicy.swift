import Foundation

/// Shared HTTPS and leaf-pin decision used by the main app and Share extension.
/// Transport adapters stay separate; this is the one trust-policy owner.
enum ServerTLSTrustPolicy {
    enum LeafDecision: Equatable {
        case pinMatch
        case reject
        case publicCAFallback
    }

    static func requiresHTTPS(scheme: String?) -> Bool {
        scheme?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "https"
    }

    static func normalizeFingerprint(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func allowsPublicCATrustFallback(
        forHost host: String,
        pinnedLeafFingerprint: String? = nil
    ) -> Bool {
        guard normalizeFingerprint(pinnedLeafFingerprint) == nil else { return false }
        return isTailscaleHostname(host) || isPublicDNSHostname(host)
    }

    /// Bonjour/LAN shortcut for no-pin pairs. Public-domain hosts stay on the paired endpoint.
    static func allowsUnpinnedLANShortcut(forHost host: String) -> Bool {
        isTailscaleHostname(host)
    }

    static func isTailscaleHostname(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasSuffix(".ts.net") || normalized.hasSuffix(".beta.tailscale.net")
    }

    static func isPublicDNSHostname(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return false }
        if isIPLiteral(normalized) { return false }
        if normalized == "localhost" || normalized.hasSuffix(".localhost") { return false }
        if normalized.hasSuffix(".local") { return false }
        return normalized.contains(".")
    }

    static func isIPLiteral(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if trimmed.contains(":") { return true }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part) else { return false }
            return (0...255).contains(value) && String(value) == part
        }
    }

    static func decision(
        pinnedLeafFingerprint: String?,
        presentedFingerprint: String,
        host: String
    ) -> LeafDecision {
        let pinned = normalizeFingerprint(pinnedLeafFingerprint)
        if let pinned {
            return presentedFingerprint == pinned ? .pinMatch : .reject
        }
        if allowsPublicCATrustFallback(forHost: host) {
            return .publicCAFallback
        }
        return .reject
    }
}
