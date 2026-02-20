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
    /// Remote/local notification flow for permission prompts.
    static let pushNotificationsEnabled = false

    /// Dynamic Island / Lock Screen session activity surface.
    static let liveActivitiesEnabled = false

    /// Composer microphone button + custom speech-to-text flow.
    static let composerDictationEnabled = false
}

/// Rendering implementation gates for timeline hot paths.
///
/// Policy: keep chat timeline interactions UIKit-first for predictable sizing,
/// lower allocation churn, and less SwiftUI diffing overhead under streaming.
///
/// SwiftUI implementations are retained as opt-in fallbacks for debugging and
/// future parity checks while native UIKit replacements converge.
enum HotPathRenderGates {
    /// Enable legacy SwiftUI hosted expanded tool content (todo/read-media) in
    /// timeline rows. Disabled by default to enforce UIKit-first hot paths.
    ///
    /// Debug override:
    /// `OPPI_ENABLE_SWIFTUI_HOTPATH_FALLBACKS=1`
    static var enableSwiftUIHotPathFallbacks: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["OPPI_ENABLE_SWIFTUI_HOTPATH_FALLBACKS"] == "1"
#else
        false
#endif
    }
}
