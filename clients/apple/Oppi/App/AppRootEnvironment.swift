import SwiftUI
import UIKit

/// App-scoped services the root publishes to every screen.
///
/// The root view applies them with `appRootEnvironment(_:)`. `HostFactory`
/// re-applies the same set on every SwiftUI screen UIKit hosts, so no screen
/// depends on SwiftUI passing the presenter's environment across a UIKit seam.
/// The iOS app on Mac (build 54) crashed on that path: "No Observable object of
/// type ConnectionCoordinator".
///
/// UIKit code finds the same root as a trait (`UITraitCollection.appRootEnvironment`)
/// with `HostFactory.root(near:)`. The app's scene publishes it on its window,
/// so every controller in the window inherits it: presented ones included.
/// The SwiftUI value is a plain environment value, not bridged to the trait:
/// a bridged value read nil in `NavigationStack` destinations.
///
/// Every member is a store, so the root never changes for the app's
/// lifetime: a screen that captured it when it was pushed reads the same live
/// state as the window. A value member (the saved row appearance once was)
/// went stale in pushed screens until they were rebuilt.
@MainActor
struct AppRootEnvironment {
    let coordinator: ConnectionCoordinator
    let navigation: AppNavigation
    let themeStore: ThemeStore
    let quickCommentTemplateStore: QuickCommentTemplateStore
    let composerDraftStore: ComposerDraftStore
    let chatReaderPayloadStore: ChatReaderPayloadStore
    let sessionRows: SessionRowDisplayStore
    /// The one owner of every open. UIKit reaches it here; SwiftUI through
    /// the root's `openURL` action.
    let opener: AppOpener

    /// The app passes its own opener, the one `AppDelegate` wires to the
    /// notification delegate.
    init(
        coordinator: ConnectionCoordinator,
        navigation: AppNavigation,
        themeStore: ThemeStore,
        quickCommentTemplateStore: QuickCommentTemplateStore,
        composerDraftStore: ComposerDraftStore,
        chatReaderPayloadStore: ChatReaderPayloadStore,
        sessionRows: SessionRowDisplayStore,
        opener: AppOpener
    ) {
        self.coordinator = coordinator
        self.navigation = navigation
        self.themeStore = themeStore
        self.quickCommentTemplateStore = quickCommentTemplateStore
        self.composerDraftStore = composerDraftStore
        self.chatReaderPayloadStore = chatReaderPayloadStore
        self.sessionRows = sessionRows
        self.opener = opener
    }

    /// Previews and tests: the root owns an opener built for these services.
    init(
        coordinator: ConnectionCoordinator,
        navigation: AppNavigation,
        themeStore: ThemeStore,
        quickCommentTemplateStore: QuickCommentTemplateStore,
        composerDraftStore: ComposerDraftStore,
        chatReaderPayloadStore: ChatReaderPayloadStore,
        sessionRows: SessionRowDisplayStore
    ) {
        self.init(
            coordinator: coordinator,
            navigation: navigation,
            themeStore: themeStore,
            quickCommentTemplateStore: quickCommentTemplateStore,
            composerDraftStore: composerDraftStore,
            chatReaderPayloadStore: chatReaderPayloadStore,
            sessionRows: sessionRows,
            opener: AppOpener(
                coordinator: coordinator,
                navigation: navigation,
                composerDraftStore: composerDraftStore
            )
        )
    }
}

/// The same services. Lets UIKit skip trait updates for an unchanged set.
extension AppRootEnvironment: Equatable {
    nonisolated static func == (lhs: AppRootEnvironment, rhs: AppRootEnvironment) -> Bool {
        lhs.coordinator === rhs.coordinator
            && lhs.navigation === rhs.navigation
            && lhs.themeStore === rhs.themeStore
            && lhs.quickCommentTemplateStore === rhs.quickCommentTemplateStore
            && lhs.composerDraftStore === rhs.composerDraftStore
            && lhs.chatReaderPayloadStore === rhs.chatReaderPayloadStore
            && lhs.sessionRows === rhs.sessionRows
            && lhs.opener === rhs.opener
    }
}

/// The app scene's phase for SwiftUI screens UIKit hosts. SwiftUI's own
/// `scenePhase` stays `.background` in a UIKit scene's hosting controllers,
/// which would pause everything that waits for `.active` (the chat
/// timeline, the SSH terminal); `appRootEnvironment(_:)` applies this one.
@MainActor @Observable
final class AppScenePhase {
    static let shared = AppScenePhase()

    private(set) var phase: ScenePhase
    var isBackground: Bool { phase == .background }
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        phase = switch UIApplication.shared.applicationState {
        case .active: .active
        case .background: .background
        default: .inactive
        }
        let transitions: [(Notification.Name, ScenePhase)] = [
            (UIScene.willEnterForegroundNotification, .inactive),
            (UIScene.didActivateNotification, .active),
            (UIScene.willDeactivateNotification, .inactive),
            (UIScene.didEnterBackgroundNotification, .background),
        ]
        for (name, phase) in transitions {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.phase = phase }
            })
        }
    }
}

private struct AppRootTrait: UITraitDefinition {
    static var defaultValue: AppRootEnvironment? { nil }
}

extension EnvironmentValues {
    @Entry var appRootEnvironment: AppRootEnvironment?
}

extension UITraitCollection {
    var appRootEnvironment: AppRootEnvironment? {
        self[AppRootTrait.self]
    }
}

extension UITraitOverrides {
    /// UIKit traps reading an override that was never set, so this reads only
    /// a set one; nil removes it.
    var appRootEnvironment: AppRootEnvironment? {
        get { contains(AppRootTrait.self) ? self[AppRootTrait.self] : nil }
        set {
            if let newValue {
                self[AppRootTrait.self] = newValue
            } else {
                remove(AppRootTrait.self)
            }
        }
    }
}

extension View {
    /// Root services, the active server's scoped stores, and theme values.
    /// Apply where a view tree starts: the app root, or a harness root.
    /// `HostFactory` applies it to every SwiftUI screen UIKit hosts.
    func appRootEnvironment(_ root: AppRootEnvironment) -> some View {
        modifier(AppRootEnvironmentModifier(root: root))
    }

    /// Publishes `root` as the trait of this view's window, for UIKit code
    /// anywhere in the window: a preview or test whose fixture root differs
    /// from the one the app's scene publishes.
    func publishesAppRootToWindow(_ root: AppRootEnvironment) -> some View {
        background {
            AppRootWindowPublisher(root: root)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

private struct AppRootWindowPublisher: UIViewRepresentable {
    let root: AppRootEnvironment

    func makeUIView(context: Context) -> AppRootWindowPublisherView {
        AppRootWindowPublisherView(root: root)
    }

    func updateUIView(_ view: AppRootWindowPublisherView, context: Context) {
        view.root = root
    }
}

private final class AppRootWindowPublisherView: UIView {
    var root: AppRootEnvironment {
        didSet { publish() }
    }

    init(root: AppRootEnvironment) {
        self.root = root
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        publish()
    }

    private func publish() {
        guard let window, window.traitOverrides.appRootEnvironment != root else { return }
        window.traitOverrides.appRootEnvironment = root
    }
}

/// A view modifier so `activeConnection` and theme reads are tracked and the
/// scoped stores follow server switches while the tree is up.
private struct AppRootEnvironmentModifier: ViewModifier {
    let root: AppRootEnvironment

    func body(content: Content) -> some View {
        content
            .environment(root.coordinator)
            .withServerScopedEnvironment(root.coordinator.activeConnection)
            .environment(root.navigation)
            .environment(\.chatReaderPayloadStore, root.chatReaderPayloadStore)
            .environment(root.coordinator.serverStore)
            .environment(root.themeStore)
            .environment(root.quickCommentTemplateStore)
            .environment(\.composerDraftStore, root.composerDraftStore)
            .environment(\.theme, root.themeStore.appTheme)
            .environment(\.themeID, root.themeStore.activeThemeID)
            .environment(\.scenePhase, AppScenePhase.shared.phase)
            .environment(\.appRootEnvironment, root)
            // Every SwiftUI `Link` and `openURL` — Settings and onboarding
            // included — follows the app's browser preference through the
            // owner, never Safari directly.
            .environment(\.openURL, OpenURLAction { url in
                root.opener.open(AppOpenRequest(url: url, origin: .inAppHyperlink))
                return .handled
            })
            .tint(.themeBlue)
    }
}
