import Foundation
import Testing
import UIKit
@testable import Oppi

/// B1: App Lock with a pane open. The cover is a window of its own above
/// every window of the scene, so it hides the chat's leaf and the pane beside
/// it alike, takes the keyboard from a field in the pane, and leaves both
/// panes as they were when the app unlocks.
@MainActor
@Suite("App Lock with a pane open", .serialized)
struct PaneAppLockTests {
    @Test func theCoverHidesBothPanesAndUnlockingLeavesThemOpen() async throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "App Lock tests need the test host's window scene"
        )
        let size = scene.effectiveGeometry.coordinateSpace.bounds.size
        let host = PaneTestHost(width: size.width, height: size.height)
        let companion = PaneCompanionScreen()
        host.showPanel(minWidth: 200, idealWidth: 260, makeScreen: { companion })
        defer {
            hideTestWindow(host.window)
            host.hide()
        }
        #expect(companion.viewIfLoaded?.window === host.window, "the pane is open beside the leaf")
        #expect(companion.field.becomeFirstResponder())

        let suite = "PaneAppLockTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AppLockSettings.setTimeout(.immediately, in: defaults)
        let appLock = AppLockService(
            defaults: defaults,
            availability: { .available },
            method: { .faceID },
            authenticator: { _ in .success },
            didTurnOn: {},
            isProtectedDataAvailable: { true }
        )
        let covers = AppLockCoverController(
            service: appLock,
            scopedLocks: ScopedLockService(defaults: defaults, appLock: appLock, didLock: { _ in }, isProtectedDataAvailable: { true })
        )
        covers.start()
        // The scene connecting is when the cover installs, before any content.
        NotificationCenter.default.post(name: UIScene.willConnectNotification, object: scene)

        // The test host's own cover (App Lock off) stays hidden; this one shows.
        let cover = try #require(
            scene.windows.first { !$0.isHidden && $0.rootViewController is AppLockCoverViewController },
            "a locked app shows its cover"
        )
        defer { cover.isHidden = true }
        #expect(cover.windowLevel > host.window.windowLevel)
        #expect(cover.isKeyWindow, "a hardware keyboard cannot type behind the cover")
        #expect(!companion.field.isFirstResponder, "the field in the pane gave up the keyboard")
        for leaf in [host.panes.primary.view, companion.view].compactMap(\.self) {
            let frame = leaf.convert(leaf.bounds, to: cover)
            #expect(cover.bounds.contains(frame), "the cover hides \(frame)")
        }

        #expect(await appLock.unlock())
        #expect(cover.isHidden, "unlocking takes the cover down")
        #expect(companion.viewIfLoaded?.window === host.window, "the pane is still open after unlock")
        #expect(host.panes.primary.viewIfLoaded?.window === host.window)
    }
}
