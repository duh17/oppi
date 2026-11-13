import Observation

/// State the whole app shares, whatever window shows it: launch, onboarding,
/// What's New, and the one Live Voice call's start. Each window's own state
/// (routes, panes, Quick Session, its server) is its `SceneNavigation`, which
/// holds this as `app`.
@MainActor @Observable
final class AppState {
    /// Launch phase gate. While `.resolving`, the app root shows a blank
    /// canvas until local pairing and cache state are known.
    var launchPhase: AppLaunchPhase = .resolving
    var showOnboarding: Bool = true
    var showWhatsNew: Bool = false

    /// Session whose chat starts Live Voice when it opens (a quick voice
    /// session). Live Voice is one call for the app, so this is too.
    /// Consumed once by that session's ChatViewController, then cleared.
    var pendingLiveVoiceSessionId: String?

    /// Records the server a window chose; the app keeps it as the last active
    /// server (`AppPreferences.LastActiveServer`) for launch and App Intents.
    /// A leaf opening its own server does not count. Tests leave it a no-op.
    @ObservationIgnored var onServerChosen: @MainActor (String) -> Void = { _ in }

    @ObservationIgnored private var lastChosenServerId: String?

    func serverChosen(_ serverId: String) {
        guard serverId != lastChosenServerId else { return }
        lastChosenServerId = serverId
        onServerChosen(serverId)
    }

    /// Reveal the normal app shell for an existing pairing before transport
    /// preparation finishes. Connectivity failures must never masquerade as
    /// missing credentials and route a paired user back through onboarding.
    func revealPairedServerShell() {
        showOnboarding = false
        launchPhase = .ready
    }
}
