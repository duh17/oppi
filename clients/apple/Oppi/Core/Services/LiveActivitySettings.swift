import Foundation

/// Per-server Live Activity opt-in and the server's card slot (Server Settings → Notifications).
///
/// Off by default, like push. With push on for the same server, the server also keeps the
/// card current through the push relay while Oppi is closed; without push the card updates
/// only while Oppi runs.
enum LiveActivitySettings {
    private static func enabledKey(serverId: String) -> String {
        "\(AppIdentifiers.subsystem).liveActivity.enabled.\(serverId)"
    }

    private static let slotsKey = "\(AppIdentifiers.subsystem).liveActivity.slots"

    static func isEnabled(serverId: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey(serverId: serverId))
    }

    static func setEnabled(_ enabled: Bool, serverId: String, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey(serverId: serverId))
        // The relay learns the card by its slot, so an enabled server always has one.
        if enabled { _ = slot(serverId: serverId, defaults: defaults) }
    }

    /// The card's random name for this server, made on first use and kept: 16 random bytes,
    /// base64url (22 characters), the relay's slot format. Apple and the relay see it, so it
    /// is never derived from the server's identity.
    static func slot(serverId: String, defaults: UserDefaults = .standard) -> String {
        var slots = defaults.dictionary(forKey: slotsKey) as? [String: String] ?? [:]
        if let slot = slots[serverId] { return slot }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        let slot = Data(bytes).base64URLEncodedString
        slots[serverId] = slot
        defaults.set(slots, forKey: slotsKey)
        return slot
    }

    /// The server a card belongs to, for a card the relay started while Oppi was closed.
    static func serverId(forSlot slot: String, defaults: UserDefaults = .standard) -> String? {
        let slots = defaults.dictionary(forKey: slotsKey) as? [String: String] ?? [:]
        return slots.first { $0.value == slot }?.key
    }

    /// The slot of each server whose card is on, by server ID.
    static func enabledServers(defaults: UserDefaults = .standard) -> [String: String] {
        let slots = defaults.dictionary(forKey: slotsKey) as? [String: String] ?? [:]
        return slots.filter { isEnabled(serverId: $0.key, defaults: defaults) }
    }
}
