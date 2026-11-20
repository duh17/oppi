import Foundation

/// Which Rexes the Rex screen lists, once each. A Rex can be reached two ways:
/// straight over Tailscale (found on the tailnet or added by name) and through
/// a saved SSH host. Both name the same Rex by its own `host_id`
/// (`server.status`), so a saved host whose Rex has the id of a listed direct
/// Rex is left out: the direct route wins, because it needs no SSH sign-in.
enum RexListDedupe {
    /// A Rex the screen reaches over Tailscale: its address, and the id it gave
    /// over its own connection, once it has read it.
    struct Direct: Equatable {
        let address: String
        let hostID: String?
    }

    /// A saved SSH host: the id its Rex gave (over the host's own stream, or
    /// when the host learned its Rex's Tailscale address), and that address.
    struct Saved: Equatable {
        let id: UUID
        let hostID: String?
        let learnedAddress: String?
        let learnedHostID: String?
    }

    /// The ids the direct Rexes stand for. Before a direct Rex has said its own
    /// id, a saved host that learned the id of the Rex at that same address
    /// answers for it, so the saved host is not listed while the direct
    /// connection opens. Once the direct Rex said its id, only that counts.
    static func directIDs(_ direct: [Direct], saved: [Saved]) -> Set<String> {
        Set(direct.compactMap { rex in
            rex.hostID ?? saved.first { $0.learnedAddress == rex.address && $0.learnedHostID != nil }?.learnedHostID
        })
    }

    /// The saved hosts the screen lists, in saved order: every one whose Rex is
    /// not a listed direct Rex. A host whose Rex has not said who it is yet is
    /// listed.
    static func savedShown(_ saved: [Saved], direct: [Direct]) -> [UUID] {
        let ids = directIDs(direct, saved: saved)
        return saved.filter { host in
            guard let id = host.hostID ?? host.learnedHostID else { return true }
            return !ids.contains(id)
        }.map(\.id)
    }
}
