#if DEBUG
import Foundation
import SwiftUI
import UIKit

// MARK: - Configuration

enum ScreenshotPreviewConfig {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--screenshot-preview")
    }

    static var screen: String {
        ProcessInfo.processInfo.environment["SCREENSHOT_SCREEN"] ?? "workspace-settings"
    }
}

/// Debug-only: `SCREENSHOT_ORIENTATION=landscape-left|landscape-right|portrait` rotates the scene so
/// Duo landscape poses (vertical rail on the trailing edge) can be captured
/// without driving Simulator.app.
@MainActor
enum ScreenshotPreviewOrientation {
    static func applyRequested() {
        guard let raw = ProcessInfo.processInfo.environment["SCREENSHOT_ORIENTATION"],
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        else { return }
        let mask: UIInterfaceOrientationMask = switch raw {
        case "landscape", "landscape-right": .landscapeRight
        case "landscape-left": .landscapeLeft
        default: .portrait
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
}

/// Preview-only defaults in the argument domain: a preview reads them like
/// real preferences, and nothing is written to the app's persistent defaults,
/// which a simulator keeps across launches and test runs.
enum ScreenshotVolatileDefaults {
    static func apply(_ values: [String: Any]) {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments.merge(values) { _, new in new }
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    /// Call before `ThemeStore()`: its setters would persist the theme.
    static func applyTheme(_ themeID: ThemeID) {
        apply([
            "\(AppIdentifiers.subsystem).theme.mode": ThemeMode.manual.rawValue,
            ThemeID.storageKey: themeID.rawValue,
        ])
    }

    /// Pins the theme `SCREENSHOT_COLOR_SCHEME` names: a built-in (`dark`,
    /// `light`, `oled`, `night`) or an imported one (`custom:Paper`, from the
    /// settings fixtures). Call before `ThemeStore()`.
    static func applyThemeScheme(_ scheme: String?) {
        guard let scheme, ["dark", "light", "oled", "night"].contains(scheme) || scheme.hasPrefix("custom:") else { return }
        if scheme.hasPrefix("custom:") { applyImportedThemes() }
        applyTheme(ThemeID(rawValue: scheme))
    }

    /// The two imported fixture themes the settings captures use.
    static func applyImportedThemes() {
        apply(["\(AppIdentifiers.subsystem).customThemes": SettingsPageThemes.importedThemes])
    }

    /// Call before `ThemeStore()`: its setters would persist the theme.
    static func applyDarkTheme(_ enabled: Bool) {
        guard enabled else { return }
        apply([
            "\(AppIdentifiers.subsystem).theme.mode": ThemeMode.manual.rawValue,
            ThemeID.storageKey: ThemeID.dark.rawValue,
        ])
    }
}

// MARK: - Root Preview View

/// Launches a standalone screen with mock data for screenshot capture in UI tests.
struct ScreenshotPreviewView: View {
    var body: some View {
        switch ScreenshotPreviewConfig.screen {
        case "chat-routes":
            ChatRoutesHarnessPreview()
        case "session-timeline":
            SessionTimelinePreview()
        case "chat-top-bar-default":
            ChatTopBarScreenshotPreview(
                order: ChatTopBarAction.allCases,
                shown: ChatTopBarAction.defaultShown
            )
        case "chat-top-bar-all":
            ChatTopBarScreenshotPreview(
                order: ChatTopBarAction.allCases,
                shown: Set(ChatTopBarAction.allCases)
            )
        case "chat-top-bar-reordered":
            ChatTopBarScreenshotPreview(
                order: [.outline, .files, .context, .git, .terminal],
                shown: Set(ChatTopBarAction.allCases)
            )
        default:
            Text("Unknown screen: \(ScreenshotPreviewConfig.screen)")
        }
    }
}

/// `SCREENSHOT_SCREEN=chat-routes`: the production chat over
/// the `chat-routes` fixtures with Files, Git, Outline, and Context pinned in
/// the argument domain. These screens are about the panels the bar opens, not
/// the default bar (`chat-top-bar-default`), and a layout saved on this
/// simulator cannot change what they show.
private struct ChatRoutesHarnessPreview: View {
    init() {
        let layout = ChatTopBarLayout(order: ChatTopBarAction.allCases, shown: [.files, .git, .outline, .context])
        ScreenshotVolatileDefaults.apply([
            AppPreferences.ChatTopBar.orderKey: layout.storedOrder,
            AppPreferences.ChatTopBar.shownKey: layout.storedShown,
        ])
    }

    var body: some View { ChatRoutesHarnessView() }
}

/// `SCREENSHOT_SCREEN=chat-top-bar-default`, `-all`, and `-reordered`: the
/// chat's bar over the `chat-routes` fixtures with a chosen top bar. The layout goes in the volatile argument domain, so the simulator's
/// saved settings are untouched and a test's bar does not depend on what an
/// earlier run left behind.
private struct ChatTopBarScreenshotPreview: View {
    init(
        order: [ChatTopBarAction],
        shown: Set<ChatTopBarAction>
    ) {
        let layout = ChatTopBarLayout(order: order, shown: shown)
        ScreenshotVolatileDefaults.apply([
            AppPreferences.ChatTopBar.orderKey: layout.storedOrder,
            AppPreferences.ChatTopBar.shownKey: layout.storedShown,
        ])
    }

    var body: some View { ChatRoutesHarnessView() }
}

/// `SCREENSHOT_SCREEN=settings-chat`: the Chat settings page as the root of a router stack, over fixture services.
/// The page shares the app's `ThemeStore`. Nothing here calls a server.
@MainActor
final class SettingsPagePreviewController: PreviewRootController {
    /// The page shares the app's own `ThemeStore`, the one that owns the window:
    /// a theme chosen on the page then re-themes the window, as in the app. A
    /// store of its own would change only itself.
    init(themeStore: ThemeStore) {
        // Every settings page can be captured in an imported theme
        // (`SCREENSHOT_COLOR_SCHEME=custom:Paper`), not only Appearance.
        ScreenshotVolatileDefaults.applyImportedThemes()
        let root = AppRootEnvironment(
            coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            navigation: AppNavigation(),
            themeStore: themeStore,
            quickCommentTemplateStore: QuickCommentTemplateStore(templates: QuickCommentTemplate.builtInDefaults),
            composerDraftStore: ComposerDraftStore(),
            chatReaderPayloadStore: ChatReaderPayloadStore(),
            sessionRows: SessionRowDisplayStore(fixed: SessionRowDisplay())
        )
        super.init(
            root: root,
            themeStore: themeStore,
            content: PreviewHost.screenStack(root: root) {
                SettingsChatViewController(root: root)
            }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// The two imported themes the settings captures use, one light and one dark,
/// as `CustomThemeStore` keeps them. Only the base colors differ; every other
/// token follows from them.
private enum SettingsPageThemes {
    static var importedThemes: Data {
        func theme(
            _ name: String, scheme: String,
            bg: String, bgDark: String, highlight: String, fg: String, dim: String, comment: String,
            blue: String, cyan: String, green: String, orange: String, purple: String, red: String, yellow: String
        ) -> [String: Any] {
            let colors: [String: String] = [
                "bg": bg, "bgDark": bgDark, "bgHighlight": highlight, "fg": fg, "fgDim": dim, "comment": comment,
                "blue": blue, "cyan": cyan, "green": green, "orange": orange, "purple": purple, "red": red, "yellow": yellow,
                "thinkingText": dim, "userMessageBg": highlight, "userMessageText": fg,
                "toolPendingBg": highlight, "toolSuccessBg": highlight, "toolErrorBg": highlight,
                "toolTitle": fg, "toolOutput": dim, "mdHeading": blue, "mdLink": cyan, "mdLinkUrl": comment,
                "mdCode": cyan, "mdCodeBlock": green, "mdCodeBlockBorder": highlight, "mdQuote": dim,
                "mdQuoteBorder": highlight, "mdHr": highlight, "mdListBullet": orange,
                "toolDiffAdded": green, "toolDiffRemoved": red, "toolDiffContext": comment,
                "syntaxComment": comment, "syntaxKeyword": purple, "syntaxFunction": blue, "syntaxVariable": fg,
                "syntaxString": green, "syntaxNumber": orange, "syntaxType": cyan, "syntaxOperator": fg,
                "syntaxPunctuation": dim, "thinkingOff": highlight, "thinkingMinimal": comment, "thinkingLow": blue,
                "thinkingMedium": cyan, "thinkingHigh": purple, "thinkingXhigh": red,
            ]
            return ["name": name, "colorScheme": scheme, "colors": colors]
        }
        let themes = [
            "Paper": theme(
                "Paper", scheme: "light",
                bg: "#F4EFE6", bgDark: "#E8E1D3", highlight: "#DDD3BF", fg: "#3B3226", dim: "#6A5E4C", comment: "#7F7360",
                blue: "#2F5D9C", cyan: "#1F7A80", green: "#4B7A2E", orange: "#B2661B", purple: "#7A4C9E", red: "#B03A3A", yellow: "#A68416"
            ),
            "Neon Harbor": theme(
                "Neon Harbor", scheme: "dark",
                bg: "#0B1020", bgDark: "#060914", highlight: "#1B2442", fg: "#E4ECFF", dim: "#9CB0DC", comment: "#8498C4",
                blue: "#4DA3FF", cyan: "#3DF0E0", green: "#5DF08A", orange: "#FFB454", purple: "#C08CFF", red: "#FF6B8A", yellow: "#FFE066"
            ),
        ]
        return (try? JSONSerialization.data(withJSONObject: themes)) ?? Data()
    }
}

/// A router screen at the root of a `RouterNavigationController`, the way the
/// router presents a modal with `.inNavigation()`. Previews and harnesses of
/// screens that rely on UIKit bars and the navigator host them here; the app
/// root comes from the window. `content` runs in the screen's own graph: put
/// its fixture environment on it, not on this view.
///
/// The app puts the theme's appearance on its window (`AppRootViewController`),
/// and system chrome that reads the window rather than the screen, such as the
/// Duo's vertical rail, follows it there. A harness's window keeps the system
/// appearance, which drew a light rail beside a dark chat, so this host
/// asks for the theme's color scheme the same way.
struct RouterPreviewNavigation<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.appRootEnvironment) private var root

    var body: some View {
        RouterPreviewNavigationHost(content: content)
            .preferredColorScheme(root?.themeStore.preferredColorScheme)
    }
}

/// `RouterPreviewNavigation` for a UIKit screen (the chat). A new `id`
/// replaces the root screen, the way the shell builds a new screen for
/// another session.
struct RouterPreviewControllerNavigation: View {
    let id: AnyHashable
    let screen: () -> UIViewController
    @Environment(\.appRootEnvironment) private var root

    var body: some View {
        RouterPreviewControllerNavigationHost(id: id, screen: screen)
            .preferredColorScheme(root?.themeStore.preferredColorScheme)
    }
}

private struct RouterPreviewControllerNavigationHost: UIViewControllerRepresentable {
    let id: AnyHashable
    let screen: () -> UIViewController
    @Environment(\.appRootEnvironment) private var root

    final class Coordinator {
        var id: AnyHashable?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> RouterNavigationController {
        guard let root else {
            preconditionFailure("RouterPreviewControllerNavigation needs appRootEnvironment(_:) above it")
        }
        let navigation = RouterNavigationController(rootViewController: screen())
        navigation.traitOverrides.appRootEnvironment = root
        let themeStore = root.themeStore
        navigation.interfaceStyle = { themeStore.userInterfaceStyle }
        context.coordinator.id = id
        return navigation
    }

    func updateUIViewController(_ navigation: RouterNavigationController, context: Context) {
        guard context.coordinator.id != id else { return }
        context.coordinator.id = id
        navigation.setViewControllers([screen()], animated: false)
    }
}

private struct RouterPreviewNavigationHost<Content: View>: UIViewControllerRepresentable {
    let content: () -> Content
    @Environment(\.appRootEnvironment) private var root

    func makeUIViewController(context: Context) -> RouterNavigationController {
        guard let root else {
            preconditionFailure("RouterPreviewNavigation needs appRootEnvironment(_:) above it")
        }
        let navigation = RouterNavigationController(
            rootViewController: HostFactory.screen(root: root, content: content)
        )
        let themeStore = root.themeStore
        navigation.interfaceStyle = { themeStore.userInterfaceStyle }
        return navigation
    }

    func updateUIViewController(_ navigation: RouterNavigationController, context: Context) {}
}

extension AppRootEnvironment {
    /// A preview's own services; the rest fresh.
    static func preview(
        coordinator: ConnectionCoordinator,
        navigation: AppNavigation = AppNavigation(),
        themeStore: ThemeStore = ThemeStore()
    ) -> Self {
        AppRootEnvironment(
            coordinator: coordinator,
            navigation: navigation,
            themeStore: themeStore,
            quickCommentTemplateStore: QuickCommentTemplateStore(templates: QuickCommentTemplate.builtInDefaults),
            composerDraftStore: ComposerDraftStore(),
            chatReaderPayloadStore: ChatReaderPayloadStore(),
            sessionRows: SessionRowDisplayStore(fixed: SessionRowDisplay())
        )
    }
}
#endif
