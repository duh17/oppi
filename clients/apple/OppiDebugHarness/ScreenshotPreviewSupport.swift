#if DEBUG
import Foundation
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

// MARK: - Previews

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
