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
/// with `HostFactory.root(near:)`. The app root publishes it on its window
/// (`publishesAppRootToWindow`), so every controller in the window inherits
/// it: presented ones and SwiftUI's own navigation hosts included.
/// The SwiftUI value is a plain environment value, not bridged to the trait:
/// a bridged value read nil in `NavigationStack` destinations.
@MainActor
struct AppRootEnvironment {
    let coordinator: ConnectionCoordinator
    let navigation: AppNavigation
    let themeStore: ThemeStore
    let quickCommentTemplateStore: QuickCommentTemplateStore
    let composerDraftStore: ComposerDraftStore
    let chatReaderPayloadStore: ChatReaderPayloadStore
    let sessionRowDisplay: SessionRowDisplay
}

/// Same services, same row appearance. Lets UIKit skip trait updates when the
/// root view re-renders with an unchanged set.
extension AppRootEnvironment: Equatable {
    nonisolated static func == (lhs: AppRootEnvironment, rhs: AppRootEnvironment) -> Bool {
        lhs.coordinator === rhs.coordinator
            && lhs.navigation === rhs.navigation
            && lhs.themeStore === rhs.themeStore
            && lhs.quickCommentTemplateStore === rhs.quickCommentTemplateStore
            && lhs.composerDraftStore === rhs.composerDraftStore
            && lhs.chatReaderPayloadStore === rhs.chatReaderPayloadStore
            && lhs.sessionRowDisplay == rhs.sessionRowDisplay
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
    /// anywhere in the window. Apply once, where the window's content starts.
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
            .environment(\.sessionRowDisplay, root.sessionRowDisplay)
            .environment(\.appRootEnvironment, root)
            .tint(.themeBlue)
    }
}
