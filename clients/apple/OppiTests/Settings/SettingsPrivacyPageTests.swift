import Foundation
import Testing
import UIKit
@testable import Oppi

/// Settings > Privacy & Security: the changes that guard themselves. Changing or
/// turning off an active App Lock, and turning Confirm New Servers off while App
/// Lock is on, ask for device authentication first; a refusal leaves the setting
/// where it was.
@Suite("Settings Privacy page", .serialized)
@MainActor
struct SettingsPrivacyPageTests {
    @MainActor
    private final class Prompts {
        var reasons: [String] = []
        var outcome: DeviceOwnerAuthentication.Outcome = .success
    }

    private struct Harness {
        let page: SettingsPrivacyViewController
        let appLock: AppLockService
        let prompts: Prompts
        let window: UIWindow
        let originalConfirm: Bool
    }

    private func makeHarness(timeout: AppLockTimeout, available: Bool = true) throws -> Harness {
        let defaults = try #require(UserDefaults(suiteName: "SettingsPrivacyPageTests-\(UUID().uuidString)"))
        AppLockSettings.setTimeout(timeout, in: defaults)
        let prompts = Prompts()
        let appLock = AppLockService(
            defaults: defaults,
            availability: { available ? .available : .noPasscode },
            method: { .faceID },
            authenticator: { reason in
                prompts.reasons.append(reason)
                return prompts.outcome
            },
            didTurnOn: {},
            isProtectedDataAvailable: { true }
        )
        let page = SettingsPrivacyViewController(root: makeTestAppRoot(), appLock: appLock)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        window.rootViewController = page
        window.makeKeyAndVisible()
        return Harness(page: page, appLock: appLock, prompts: prompts, window: window, originalConfirm: BiometricService.shared.isEnabled)
    }

    private func finish(_ harness: Harness) {
        BiometricService.shared.isEnabled = harness.originalConfirm
        harness.window.isHidden = true
        harness.window.rootViewController = nil
    }

    @Test("Turning App Lock on asks nothing; changing it afterwards asks first")
    func appLockChangesAskOnceItIsOn() async throws {
        let h = try makeHarness(timeout: .off)
        defer { finish(h) }

        await h.page.changeAppLock(to: .fiveMinutes).value
        #expect(h.appLock.timeout == .fiveMinutes)
        #expect(h.prompts.reasons.isEmpty)

        await h.page.changeAppLock(to: .immediately).value
        #expect(h.appLock.timeout == .immediately)
        #expect(h.prompts.reasons == ["Change App Lock"])
    }

    @Test("A cancelled prompt keeps the App Lock timeout, so turning it off needs the person")
    func cancelledPromptKeepsAppLock() async throws {
        let h = try makeHarness(timeout: .fiveMinutes)
        defer { finish(h) }
        h.prompts.outcome = .cancelled

        await h.page.changeAppLock(to: .off).value

        #expect(h.appLock.timeout == .fiveMinutes)
        #expect(h.prompts.reasons == ["Change App Lock"])
    }

    @Test("Confirm New Servers turns off at once with App Lock off, and asks first with it on")
    func confirmNewServersAsksOnlyWhenAppLockIsOn() async throws {
        let h = try makeHarness(timeout: .off)
        defer { finish(h) }
        BiometricService.shared.isEnabled = true

        await h.page.changeConfirmNewServers(to: false).value
        #expect(!BiometricService.shared.isEnabled)
        #expect(h.prompts.reasons.isEmpty)

        // Turning it on never asks, even with App Lock on.
        h.appLock.setTimeout(.oneMinute)
        await h.page.changeConfirmNewServers(to: true).value
        #expect(BiometricService.shared.isEnabled)
        #expect(h.prompts.reasons.isEmpty)

        h.prompts.outcome = .failed
        await h.page.changeConfirmNewServers(to: false).value
        #expect(BiometricService.shared.isEnabled, "a failed prompt must keep Confirm New Servers on")
        #expect(h.prompts.reasons == ["Turn off Confirm New Servers"])

        h.prompts.outcome = .success
        await h.page.changeConfirmNewServers(to: false).value
        #expect(!BiometricService.shared.isEnabled)
    }

    @Test("Without a device passcode the App Lock row reads Off, cannot open, and says why")
    func appLockIsUnavailableWithoutAPasscode() async throws {
        let h = try makeHarness(timeout: .fiveMinutes, available: false)
        defer { finish(h) }
        #expect(await waitForMainActorCondition { Self.appLockButton(in: h.page) != nil })
        let button = try #require(Self.appLockButton(in: h.page))
        #expect(button.accessibilityIdentifier == "settings.appLock")
        #expect(!button.isEnabled)
        #expect(button.accessibilityValue == "Off")
        #expect(SettingsPrivacyCopy.appLockFooter(
            timeout: .fiveMinutes, isAvailable: false, method: .faceID, deviceName: "iPhone"
        ) == "Set a passcode on this iPhone to use App Lock.")
    }

    @Test("The footers name the method that unlocks, and say when diagnostics or confirmation are off")
    func footersFollowTheSettingAndTheMethod() {
        let passcode = SettingsPrivacyCopy.appLockFooter(timeout: .oneMinute, isAvailable: true, method: .passcode, deviceName: "iPad")
        #expect(passcode.hasPrefix("Oppi asks for your iPad passcode after 1 minute away, never while it is open."))
        #expect(!passcode.contains("also unlocks"))
        let faceID = SettingsPrivacyCopy.appLockFooter(timeout: .immediately, isAvailable: true, method: .faceID, deviceName: "iPhone")
        #expect(faceID.contains("every time you return"))
        #expect(faceID.contains("Your iPhone passcode also unlocks it."))
        #expect(SettingsPrivacyCopy.confirmNewServersFooter(isOn: false, method: .faceID, deviceName: "iPhone")
            == "New and changed servers are trusted without device authentication.")
        #expect(SettingsPrivacyCopy.confirmNewServersFooter(isOn: true, method: .passcode, deviceName: "iPhone")
            .hasPrefix("Asks for your iPhone passcode before Oppi trusts a new server"))
    }

    private static func appLockButton(in page: SettingsPrivacyViewController) -> UIButton? {
        page.view.layoutIfNeeded()
        return page.dataSource?.indexPath(for: .appLock)
            .flatMap { page.collectionView.cellForItem(at: $0) }?
            .accessibilityElements?.first as? UIButton
    }
}
