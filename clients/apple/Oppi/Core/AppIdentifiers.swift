import Foundation

/// Centralized app identifiers. Fork-friendly: change `bundleIdPrefix` in
/// `project.yml` and these derive automatically from the bundle identifier.
///
/// All logging subsystems, storage keys, notification names, and service
/// identifiers reference this enum so forks only need to update one place
/// (the Xcode project / XcodeGen config).
enum AppIdentifiers {
    /// Primary subsystem identifier for os_log, Keychain, and storage keys.
    /// Matches the main app's bundle identifier at runtime.
    static let subsystem: String = Bundle.main.bundleIdentifier ?? "dev.chenda.Oppi"
}

/// Shipping toggles for first release hardening.
///
/// Keep these centralized so we can re-enable features intentionally
/// once reliability is proven.
enum ReleaseFeatures {
    /// Local, in-process notifications for attention requests received while
    /// the app has launched. This does not register with APNs or upload a
    /// device token to paired servers.
    static let localAttentionNotificationsEnabled = true

    /// Remote APNs push registration and server fallback notifications.
    /// Keep disabled until payload privacy, entitlements, and provisioning are
    /// reviewed together.
    static let remotePushNotificationsEnabled = false

    /// Live Activity codepath availability (runtime opt-in handled by
    /// `AppPreferences.LiveActivity`).
    static let liveActivitiesEnabled = false

    /// Composer microphone button + on-device speech-to-text via SpeechAnalyzer.
    static let voiceInputEnabled = true
}
