import SwiftUI
import UIKit

/// Paints the App Lock cover in its own window above every window of each
/// scene, so it also hides sheets, full-screen covers, and UIKit
/// presentations. One window per `UIWindowScene` (iPad can have several).
///
/// It is shown when the app is locked, and while a scene is inactive or in
/// the background with App Lock on or a server, workspace, or session
/// unlocked, so the app-switcher snapshot never holds session content.
@MainActor
final class AppLockCoverController {
    static let shared = AppLockCoverController()

    private struct SceneCover {
        weak var scene: UIWindowScene?
        let window: UIWindow
        var obscured: Bool
    }

    private let service: AppLockService
    private let scopedLocks: ScopedLockService
    private var covers: [ObjectIdentifier: SceneCover] = [:]
    private var observers: [NSObjectProtocol] = []

    init(service: AppLockService = .shared, scopedLocks: ScopedLockService = .shared) {
        self.service = service
        self.scopedLocks = scopedLocks
    }

    /// Register for scene lifecycle notifications. Call from
    /// `application(_:didFinishLaunchingWithOptions:)`, before any scene
    /// connects, so a cold launch with App Lock on never paints content first.
    func start() {
        guard observers.isEmpty else { return }
        service.onLockStateChange = { [weak self] in self?.refreshAll() }

        let center = NotificationCenter.default
        // `queue: nil` runs each handler synchronously while UIKit posts the
        // notification, before the scene callback returns. A `.main` queue
        // would defer it to a later turn, after the app-switcher snapshot.
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (UIWindowScene) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { note in
                guard let scene = note.object as? UIWindowScene else { return }
                MainActor.assumeIsolated { handler(scene) }
            })
        }

        observe(UIScene.willConnectNotification) { [weak self] scene in
            self?.install(in: scene)
        }
        observe(UIScene.didDisconnectNotification) { [weak self] scene in
            self?.covers.removeValue(forKey: ObjectIdentifier(scene))
        }
        observe(UIScene.willDeactivateNotification) { [weak self] scene in
            guard let self else { return }
            // With App Lock off, an open server, workspace, or session
            // unlock still keeps the app-switcher snapshot covered.
            setObscured(
                service.obscuresInactiveScenes || scopedLocks.obscuresInactiveScenes,
                scene: scene
            )
        }
        observe(UIScene.didEnterBackgroundNotification) { [weak self] scene in
            guard let self else { return }
            let otherScenesInForeground = UIApplication.shared.connectedScenes.contains {
                $0 !== scene && $0.activationState != .background && $0.activationState != .unattached
            }
            var scopedContentOpen = scopedLocks.hasOpenUnlock
            if !otherScenesInForeground {
                scopedContentOpen = scopedLocks.backgroundTransition {
                    service.appDidEnterBackground()
                }
            }
            setObscured(service.isEnabled || scopedContentOpen, scene: scene)
        }
        observe(UIScene.didActivateNotification) { [weak self] scene in
            guard let self else { return }
            // Apply a due lock before removing the privacy cover so content
            // never shows between the two.
            service.sceneDidBecomeActive()
            setObscured(false, scene: scene)
        }
    }

    private func install(in scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        guard covers[key] == nil else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: AppLockCoverView(service: service))
        window.accessibilityViewIsModal = true
        window.rootViewController?.view.accessibilityViewIsModal = true
        window.isHidden = true
        // A scene that connects while already backgrounded (state restoration,
        // background launch) starts obscured.
        let obscured = service.isEnabled && scene.activationState != .foregroundActive
        covers[key] = SceneCover(scene: scene, window: window, obscured: obscured)
        refresh(key)
    }

    private func setObscured(_ obscured: Bool, scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        if covers[key] == nil {
            install(in: scene)
        }
        covers[key]?.obscured = obscured
        // Always refresh: SwiftUI's main window, created after the cover on
        // cold launch, may have taken key status.
        refresh(key)
    }

    private func refreshAll() {
        for key in covers.keys {
            refresh(key)
        }
    }

    private func refresh(_ key: ObjectIdentifier) {
        guard let cover = covers[key] else { return }
        let visible = service.isLocked || cover.obscured
        let contentWindows = cover.scene?.windows.filter { $0 !== cover.window } ?? []
        if visible {
            if cover.window.isHidden {
                // The keyboard window sits above the cover, and its QuickType
                // bar can echo typed text, so dismiss it on every cover.
                contentWindows.forEach { $0.endEditing(true) }
                cover.window.isHidden = false
            }
            // Take key status so a hardware keyboard cannot type behind it.
            if service.isLocked, !cover.window.isKeyWindow {
                cover.window.makeKey()
            }
        } else if !cover.window.isHidden {
            cover.window.isHidden = true
            contentWindows
                .first { !$0.isHidden && $0.windowLevel == .normal }?
                .makeKey()
        }
    }
}
