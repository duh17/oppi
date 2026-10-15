import SwiftUI

/// App-scoped services the root publishes to every screen.
///
/// The root view applies them with `appRootEnvironment(_:)`, and
/// `uiKitSheet` re-applies the same set on the UIKit-presented controller.
/// Screens presented that way do not depend on SwiftUI passing the
/// presenter's environment into a sheet. The iOS app on Mac (build 54)
/// crashed on that path: "No Observable object of type ConnectionCoordinator".
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

extension EnvironmentValues {
    @Entry var appRootEnvironment: AppRootEnvironment?
}

extension View {
    /// Root services, the active server's scoped stores, and theme values.
    /// Apply where a view tree starts: the app root or a UIKit host.
    func appRootEnvironment(_ root: AppRootEnvironment) -> some View {
        modifier(AppRootEnvironmentModifier(root: root))
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
