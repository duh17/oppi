import SwiftUI
import UIKit

extension ScenePhase {
    init(_ phase: AppPhase) {
        switch phase {
        case .active: self = .active
        case .inactive: self = .inactive
        case .background: self = .background
        }
    }
}

extension EnvironmentValues {
    @Entry var appRootEnvironment: AppRootEnvironment?
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
            .environment(root.coordinator.serverStore)
            .environment(root.themeStore)
            .environment(root.quickCommentTemplateStore)
            .environment(\.theme, root.themeStore.appTheme)
            .environment(\.themeID, root.themeStore.activeThemeID)
            .environment(\.scenePhase, ScenePhase(AppScenePhase.shared.phase))
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
