import AppIntents
import UIKit

/// The app's entry point. UIKit owns the app and its scene: `SceneDelegate`
/// builds the window, and `OppiApp` holds the app's services and app-wide
/// handlers.
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
        if ReleaseFeatures.localAttentionNotificationsEnabled {
            AttentionNotificationService.shared.configureForLaunch()
        }
        // Before any scene connects, so it sees every phase change.
        _ = AppScenePhase.shared
        app = OppiApp()
        adoptScenesSavedBySwiftUI()
        return true
    }

    /// A scene session saved by a build whose scene SwiftUI ran keeps that
    /// configuration: it reconnects with SwiftUI's scene delegate and the
    /// window stayed black. UIKit asks `configurationForConnecting` only for
    /// new sessions, a session's configuration cannot change, and a
    /// single-scene app cannot destroy the session. Such a scene gets
    /// `SceneDelegate` as it connects, which builds the window right away;
    /// SwiftUI's delegate already took the connection, so a URL or intent
    /// that cold-launched it is not opened.
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
            app.open(context.url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            app?.open(context.url)
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

    /// The system control's Open intent routes here: show Quick Session.
    private func perform(_ intent: any UISceneAppIntent) {
        guard let intent = intent as? QuickSessionOpenIntent else { return }
        QuickSessionTrigger.shared.requestPresentation(for: intent)
    }
}
