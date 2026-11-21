import AppIntents
import UIKit

/// The app's entry point. UIKit owns the app and its scene: `SceneDelegate`
/// builds the window, and `OppiApp` holds the app's services. Every open goes
/// to the window's `AppOpener`.
///
/// @MainActor keeps the delegate on the main thread, where UIKit calls it.
///
/// A `UIResponder` so it ends the responder chain: the main menu's keyboard
/// commands (`KeyboardCommandMenu`) reach it from wherever focus is.
@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// Created at launch, after the process start time and App Lock cover.
    private(set) var app: OppiApp?
    private var sceneAdoption: NSObjectProtocol?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
#if DEBUG
        // Before anything reads preferences or drafts: a UI/E2E launch starts
        // from the state its launch arguments ask for.
        TestLaunchContract.applyAtLaunch()
#endif
        // First, so an exception anywhere in launch below still leaves a report.
        UncaughtExceptionRecorder.start()
#if DEBUG
        UncaughtExceptionRecorder.raiseForTestingIfRequested()
#endif
        // Before anything takes a credential, device key, or push state lock.
        CrossProcessFileLock.backgroundHold = CrossProcessFileLock.uiKitBackgroundHold(application)
        // Force-capture process start timestamp before any SwiftUI views load.
        // Static lets are lazy — this ensures it runs at app delegate init, not first view appear.
        ChatSessionTelemetry.warmProcessStartTime()
        TelemetryBackgroundSpans.shared.observeApplication()
        // Before any scene connects: a cold launch with App Lock on must show
        // the lock cover before content.
        AppLockCoverController.shared.start()
        AttentionNotificationService.shared.configureForLaunch()
        // Also on a background launch: iOS wakes Oppi when the relay starts a Live
        // Activity, so Oppi can hand the relay the new card's update token.
        LiveActivityManager.shared.startObservingSystem()
        // Before any scene connects, so it sees every phase change.
        _ = AppScenePhase.shared
        // Reconnect attachment uploads that outlived the last run, so a send of the
        // same file picks them up instead of starting over.
        _ = AttachmentUploadTransport.background
        app = OppiApp()
        // Before `didFinishLaunching` returns: a notification response
        // delivered during launch must already have its destination.
        AttentionNotificationService.shared.opener = app?.root.opener
        adoptScenesSavedBySwiftUI()
        return true
    }

    /// iOS woke or relaunched Oppi because an attachment upload in the background
    /// session finished. Touching the session reconnects it; its delegate takes the
    /// results and calls `completionHandler` once they are all delivered.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == AttachmentUploadTransport.backgroundIdentifier else {
            completionHandler()
            return
        }
        nonisolated(unsafe) let completion = completionHandler
        AttachmentUploadTransport.background.finishEventsWhenDelivered { completion() }
    }

    /// The window's opener, for entry points that run before a scene lookup
    /// (App Intents). The notification delegate holds it directly.
    static var opener: AppOpener? {
        (UIApplication.shared.delegate as? AppDelegate)?.app?.root.opener
    }

    /// A scene session saved by a build whose scene SwiftUI ran (Build 55 and
    /// earlier) keeps that configuration: it reconnects with SwiftUI's scene
    /// delegate and the window stayed black. Such a scene gets `SceneDelegate`
    /// as it connects, which builds the window right away.
    ///
    /// UIKit posts this notification after SwiftUI's delegate took the
    /// connection, so a URL or App Intent that cold-launched the scene is not
    /// opened, and nothing else carries it (`launchOptions` is nil). That
    /// repeats on every cold launch through the old session until the user
    /// swipes Oppi away in the app switcher, which discards it; the next
    /// launch gets a `SceneDelegate` session. Warm opens and notification taps
    /// are unaffected. The app cannot retire the session itself:
    /// `configurationForConnecting` runs only for new sessions,
    /// `session.configuration` is a copy, and `requestSceneSessionDestruction`
    /// fails without multiple-scene support.
    ///
    /// Only application-role scenes are the app's windows. Mac Catalyst also
    /// connects system scenes into the process (the menu bar, and one per
    /// transient AppKit window such as an open menu), with no delegate.
    /// Adopting one built a second app root inside it, whose chat took the
    /// focused stream from the visible one, and its phase changes ran the
    /// app's background path while the window was in front.
    private func adoptScenesSavedBySwiftUI() {
        sceneAdoption = NotificationCenter.default.addObserver(
            forName: UIScene.willConnectNotification,
            object: nil,
            queue: nil
        ) { note in
            guard let scene = note.object as? UIWindowScene else { return }
            MainActor.assumeIsolated {
                guard scene.session.role == .windowApplication,
                      !(scene.delegate is SceneDelegate) else { return }
                let delegate = SceneDelegate()
                scene.delegate = delegate
                delegate.connect(scene, urlContexts: [])
            }
        }
    }

    /// The system discarded these scenes (closed, or swiped away): their
    /// saved pane trees go with them.
    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        PaneTreeStore().discard(scenes: sceneSessions.map(\.persistentIdentifier))
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushRegistration.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushRegistration.shared.didFailToRegisterForRemoteNotifications(error: error)
    }
}

/// The app's one window. Opens incoming URLs and App Intent targets, and
/// reports scene phases to `OppiApp`.
@MainActor
final class SceneDelegate: NSObject, UIWindowSceneDelegate, @preconcurrency AppIntentSceneDelegate {
    var window: UIWindow?

    private var app: OppiApp? {
        (UIApplication.shared.delegate as? AppDelegate)?.app
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        connect(scene, urlContexts: connectionOptions.urlContexts)
        if let intent = connectionOptions.appIntent {
            perform(intent)
        }
        if let shortcut = connectionOptions.shortcutItem {
            _ = perform(shortcut)
        }
    }

    /// A Home Screen quick action while the app runs.
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(perform(shortcutItem))
    }

    /// Builds the window once: from the connection callback, or right away
    /// for a scene adopted from SwiftUI, which UIKit already connected.
    func connect(_ scene: UIScene, urlContexts: Set<UIOpenURLContext>) {
        guard window == nil, let windowScene = scene as? UIWindowScene, let app else { return }
        if let minimum = PlatformCapabilities.minimumWindowSize {
            windowScene.sizeRestrictions?.minimumSize = minimum
        }
        let window = AppWindow(windowScene: windowScene)
        // UIKit code anywhere in the window, presented controllers included,
        // finds the app root here (`AppRootEnvironment.near()`).
        window.traitOverrides.appRootEnvironment = app.root
        app.root.navigation.window = window
        window.rootViewController = app.makeRootViewController()
        self.window = window
        window.makeKeyAndVisible()
        app.sceneDidConnect(sceneIdentifier: windowScene.session.persistentIdentifier)
        // An adopted scene may be past these callbacks already.
        switch windowScene.activationState {
        case .foregroundActive: app.sceneDidBecomeActive()
        case .background: app.sceneDidEnterBackground()
        default: break
        }
        for context in urlContexts {
            app.root.opener.open(AppOpenRequest(url: context.url, origin: .externalURL))
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let app else { return }
        for context in URLContexts {
            app.root.opener.open(AppOpenRequest(url: context.url, origin: .externalURL))
        }
    }

    func scene(_ scene: UIScene, willPerformAppIntent appIntent: any UISceneAppIntent) {
        perform(appIntent)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        app?.sceneWillEnterForeground()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        app?.sceneDidBecomeActive()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        app?.sceneWillResignActive()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        app?.sceneDidEnterBackground()
    }

    /// The Home Screen quick actions (`UIApplicationShortcutItems`): Pinned
    /// opens the Pinned screen. False for an action this build does not know.
    private func perform(_ shortcut: UIApplicationShortcutItem) -> Bool {
        guard shortcut.type.hasSuffix(".pinned"), let app else { return false }
        app.root.opener.open(.pinned)
        return true
    }

    /// A system control's Open intent routes here: show Quick Session in its mode.
    private func perform(_ intent: any UISceneAppIntent) {
        guard let intent = intent as? QuickSessionOpenIntent else { return }
        AppDelegate.opener?.open(.quickSession(QuickSessionStart(mode: intent.target)))
    }
}
