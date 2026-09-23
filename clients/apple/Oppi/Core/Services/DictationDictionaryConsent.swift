import Foundation

/// An explicit device-local grant, scoped to the paired server AND its configured ASR provider.
/// A provider switch never inherits an older grant.
enum DictationDictionaryConsent {
    static func isEnabled(serverId: String, provider: String) -> Bool {
        UserDefaults.standard.bool(forKey: key(serverId: serverId, provider: provider))
    }

    static func setEnabled(_ enabled: Bool, serverId: String, provider: String) {
        UserDefaults.standard.set(enabled, forKey: key(serverId: serverId, provider: provider))
    }

    private static func key(serverId: String, provider: String) -> String {
        "voice.dictionary.send.\(serverId).\(provider)"
    }
}
