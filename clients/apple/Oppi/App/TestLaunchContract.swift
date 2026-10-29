#if DEBUG
import Foundation
import UIKit

/// The one launch contract UI and E2E tests use to start from known state
/// (`dev/testing/README.md`, "UI and E2E launch state"). The test harness only
/// passes launch arguments; the app clears its own state, so a harness never
/// writes defaults into a simulator slot and a stale slot cannot leak into a run.
///
/// - `-dev.chenda.Oppi.test.resetToken <token>`: when the token differs from the
///   last one this app applied, clear the app's persistent defaults and its
///   draft stores, and pin What's New as seen for this build. The same token on
///   a later launch (a relaunch of the same test app) keeps everything.
/// - `-dev.chenda.Oppi.test.animations NO`: UIKit animations off for the launch.
///
/// These keys are repeated in `QAVerificationSupport/OppiTestLaunch.swift`.
enum TestLaunchContract {
    static let resetTokenKey = "\(AppIdentifiers.subsystem).test.resetToken"
    static let animationsKey = "\(AppIdentifiers.subsystem).test.animations"
    static let appliedTokenKey = "\(AppIdentifiers.subsystem).test.appliedResetToken"

    /// First thing at launch, before any store reads defaults or any scene mounts.
    @MainActor
    static func applyAtLaunch(defaults: UserDefaults = .standard) {
        applyReset(
            token: defaults.string(forKey: resetTokenKey),
            tokenStore: defaults,
            cleared: [
                (defaults, AppIdentifiers.subsystem),
                (SharedConstants.sharedDefaults, SharedConstants.appGroupIdentifier),
            ],
            directories: [
                ComposerDraftStore.intentSessionPromptFileURL().deletingLastPathComponent(),
                WorkspaceFileDraftStore.shared.directory,
            ]
        )
        if defaults.object(forKey: animationsKey) != nil, !defaults.bool(forKey: animationsKey) {
            UIView.setAnimationsEnabled(false)
        }
    }

    /// Clears each `cleared` persistent domain through its own `UserDefaults`
    /// (the app group's suite is its own store, not a domain of `.standard`) and
    /// every directory once per `token`, then records the token in `tokenStore`.
    /// A nil token is a normal launch and changes nothing.
    static func applyReset(
        token: String?,
        tokenStore: UserDefaults,
        cleared: [(defaults: UserDefaults, domain: String)],
        directories: [URL],
        fileManager: FileManager = .default
    ) {
        guard let token, !token.isEmpty, tokenStore.string(forKey: appliedTokenKey) != token else { return }
        for (defaults, domain) in cleared {
            defaults.removePersistentDomain(forName: domain)
        }
        for directory in directories {
            try? fileManager.removeItem(at: directory)
        }
        WhatsNewManager.markSeen(in: tokenStore)
        tokenStore.set(token, forKey: appliedTokenKey)
    }
}
#endif
