import AppIntents
import UIKit

/// The app's entry point. UIKit owns the app and its scene: `SceneDelegate`
/// builds the window, and `OppiApp` holds the app's services. Every open goes
/// to the window's `AppOpener`.
///
/// @MainActor keeps the delegate on the main thread, where UIKit calls it.
@main
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Created at launch, after the process start time and App Lock cover.
    private(set) var app: OppiApp?
    private var sceneAdoption: NSObjectProtocol?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Force-capture process start timestamp before any SwiftUI views load.
        // Static lets are lazy — this ensures it runs at app delegate init, not first view appear.
        ChatSessionTelemetry.warmProcessStartTime()
        // Before any scene connects: a cold launch with App Lock on must show
        // the lock cover before content.
        AppLockCoverController.shared.start()
        AttentionNotificationService.shared.configureForLaunch()
        // Also on a background launch: iOS wakes Oppi when the relay starts a Live
        // Activity, so Oppi can hand the relay the new card's update token.
        LiveActivityManager.shared.startObservingSystem()
        // Before any scene connects, so it sees every phase change.
        _ = AppScenePhase.shared
        app = OppiApp()
        // Before `didFinishLaunching` returns: a notification response
        // delivered during launch must already have its destination.
        AttentionNotificationService.shared.opener = app?.root.opener
        adoptScenesSavedBySwiftUI()
        return true
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
    private func adoptScenesSavedBySwiftUI() {
        sceneAdoption = NotificationCenter.default.addObserver(
            forName: UIScene.willConnectNotification,
            object: nil,
            queue: nil
        ) { note in
            guard let scene = note.object as? UIWindowScene else { return }
            MainActor.assumeIsolated {
                guard !(scene.delegate is SceneDelegate) else { return }
                let delegate = SceneDelegate()
                scene.delegate = delegate
                delegate.connect(scene, urlContexts: [])
            }
        }
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
    }

    /// Builds the window once: from the connection callback, or right away
    /// for a scene adopted from SwiftUI, which UIKit already connected.
    func connect(_ scene: UIScene, urlContexts: Set<UIOpenURLContext>) {
        guard window == nil, let windowScene = scene as? UIWindowScene, let app else { return }
        let window = UIWindow(windowScene: windowScene)
        // UIKit code anywhere in the window, presented controllers included,
        // finds the app root here (`HostFactory.root(near:)`).
        window.traitOverrides.appRootEnvironment = app.root
        window.rootViewController = app.makeRootViewController()
        self.window = window
        window.makeKeyAndVisible()
        app.sceneDidConnect()
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

    /// A system control's Open intent routes here: show Quick Session in its mode.
    private func perform(_ intent: any UISceneAppIntent) {
        guard let intent = intent as? QuickSessionOpenIntent else { return }
        AppDelegate.opener?.open(.quickSession(QuickSessionStart(mode: intent.target)))
    }
}
