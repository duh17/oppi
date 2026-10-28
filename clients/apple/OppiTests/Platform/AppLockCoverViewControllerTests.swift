import Testing
import UIKit
@testable import Oppi

/// The cover is the only thing standing between a locked app and its
/// content: what it shows must follow `AppLockService`, and its Unlock button
/// must run the service's unlock.
@MainActor
@Suite("AppLockCoverViewController")
struct AppLockCoverViewControllerTests {
    private final class Authenticator: @unchecked Sendable {
        var outcomes: [DeviceOwnerAuthentication.Outcome]
        var calls = 0
        init(_ outcomes: [DeviceOwnerAuthentication.Outcome]) { self.outcomes = outcomes }
        func next() -> DeviceOwnerAuthentication.Outcome {
            calls += 1
            return outcomes.isEmpty ? .cancelled : outcomes.removeFirst()
        }
    }

    private func makeCover(
        timeout: AppLockTimeout,
        outcomes: [DeviceOwnerAuthentication.Outcome] = []
    ) throws -> (cover: AppLockCoverViewController, service: AppLockService, auth: Authenticator, window: UIWindow) {
        let defaults = try #require(UserDefaults(suiteName: "AppLockCoverTests-\(UUID().uuidString)"))
        AppLockSettings.setTimeout(timeout, in: defaults)
        let auth = Authenticator(outcomes)
        let service = AppLockService(
            defaults: defaults,
            availability: { .available },
            method: { .faceID },
            authenticator: { _ in auth.next() },
            isProtectedDataAvailable: { true }
        )
        let cover = AppLockCoverViewController(service: service)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = cover
        window.isHidden = false
        cover.view.layoutIfNeeded()
        return (cover, service, auth, window)
    }

    private func find<T: UIView>(_ type: T.Type, id: String, in root: UIView) -> T? {
        if let match = root as? T, match.accessibilityIdentifier == id { return match }
        for subview in root.subviews {
            if let match = find(type, id: id, in: subview) { return match }
        }
        return nil
    }

    @Test func lockedCoverOffersUnlockAndRunsIt() async throws {
        let (cover, service, auth, window) = try makeCover(timeout: .fiveMinutes, outcomes: [.success])
        defer { hideTestWindow(window) }
        let button = try #require(find(UIButton.self, id: "appLock.unlock", in: cover.view))
        let status = try #require(find(UILabel.self, id: "appLock.status", in: cover.view))

        #expect(service.isLocked)
        #expect(!button.isHidden)
        #expect(!status.isHidden)
        #expect(status.text == "Oppi is locked.")
        #expect(button.isEnabled)

        button.sendActions(for: .primaryActionTriggered)
        await Task.yield()
        for _ in 0..<50 where service.isLocked { try await Task.sleep(for: .milliseconds(10)) }
        #expect(auth.calls == 1)
        #expect(!service.isLocked)
    }

    @Test func aFailedAttemptSaysSoAndKeepsUnlockAvailable() async throws {
        let (cover, service, _, window) = try makeCover(timeout: .fiveMinutes, outcomes: [.failed])
        defer { hideTestWindow(window) }
        let status = try #require(find(UILabel.self, id: "appLock.status", in: cover.view))

        #expect(await service.unlock() == false)
        cover.updateProperties()

        #expect(status.text == "Couldn’t verify it’s you. Try again.")
        let button = try #require(find(UIButton.self, id: "appLock.unlock", in: cover.view))
        #expect(!button.isHidden)
        #expect(button.isEnabled)
    }

    @Test func anObscuringCoverShowsOnlyTheAppIdentity() throws {
        let (cover, service, _, window) = try makeCover(timeout: .off)
        defer { hideTestWindow(window) }
        let button = try #require(find(UIButton.self, id: "appLock.unlock", in: cover.view))
        let status = try #require(find(UILabel.self, id: "appLock.status", in: cover.view))

        #expect(!service.isLocked)
        #expect(button.isHidden)
        #expect(status.isHidden)
        #expect(cover.view.accessibilityIdentifier == "appLock.cover")
    }
}
