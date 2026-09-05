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
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasSuffix(".ts.net") || normalized.hasSuffix(".beta.tailscale.net")
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
