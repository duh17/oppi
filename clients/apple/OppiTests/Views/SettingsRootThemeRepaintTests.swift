import Testing
import UIKit
@testable import Oppi

/// The Settings index repaints its rows when the theme changes while the screen
/// is up. A row resolves its colors when it is configured, so a row the diffable
/// data source does not reconfigure keeps the previous theme's colors.
@Suite("Settings root theme repaint", .serialized)
@MainActor
struct SettingsRootThemeRepaintTests {
    @Test func rowsRepaintWhenTheThemeChangesWithTheScreenAlive() async throws {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }

        let server = try #require(PairedServer(from: ServerCredentials(
            host: "settings-root.invalid",
            port: 7749,
            token: "sk_preview",
            name: "mac-studio",
            serverFingerprint: "sha256:settings-root-theme"
        )))
        let coordinator = ConnectionCoordinator(serverStore: ServerStore())
        coordinator.serverStore.replaceServersForPreview([server])
        let screen = SettingsRootViewController(root: AppRootEnvironment(
            coordinator: coordinator,
            navigation: AppNavigation(),
            themeStore: ThemeStore(),
            quickCommentTemplateStore: QuickCommentTemplateStore(templates: QuickCommentTemplate.builtInDefaults),
            composerDraftStore: ComposerDraftStore(),
            chatReaderPayloadStore: ChatReaderPayloadStore(),
            sessionRows: SessionRowDisplayStore(fixed: SessionRowDisplay())
        ))
        // After the root: creating its `ThemeStore` resolves and applies the
        // saved theme, which would overwrite a theme set before it.
        ThemeRuntimeState.setThemeID(.dark)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        window.rootViewController = screen
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        // A page row and a server row: the two cells the index draws.
        let darkPage = try #require(await labelColor(of: "General", on: screen))
        let darkServer = try #require(await labelColor(of: server.name, on: screen))

        // The production path: the runtime theme changes and the screen is told
        // to update. `updateProperties` is the entry point UIKit itself calls.
        ThemeRuntimeState.setThemeID(.light)
        NotificationCenter.default.post(name: .oppiThemeDidChange, object: nil)

        let lightPage = try #require(
            await labelColor(of: "General", on: screen, differingFrom: darkPage),
            "A page row kept its dark colors through a theme change"
        )
        let lightServer = try #require(
            await labelColor(of: server.name, on: screen, differingFrom: darkServer),
            "A server row kept its dark colors through a theme change"
        )
        #expect(lightPage != darkPage)
        #expect(lightServer != darkServer)
    }

    /// The color of the row whose title is `title`, once the list has laid out.
    /// With `previous`, it waits for the row to be reconfigured with a different
    /// color instead, which is what a theme change has to produce.
    private func labelColor(
        of title: String,
        on screen: SettingsRootViewController,
        differingFrom previous: UIColor? = nil
    ) async -> UIColor? {
        for _ in 0..<100 {
            screen.updateProperties()
            screen.view.layoutIfNeeded()
            if let list = Self.collectionView(in: screen.view) {
                for cell in list.visibleCells {
                    for case let label as UILabel in cell.contentView.subviews where label.text == title {
                        if previous == nil || label.textColor != previous { return label.textColor }
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private static func collectionView(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        for subview in view.subviews {
            if let found = collectionView(in: subview) { return found }
        }
        return nil
    }
}

/// The Settings index draws every row's separator from the row's title in, so
/// the grouped card reads as one list. A row whose guide the layout positions
/// itself leaves a full-width line under it.
@Suite("Settings root separators", .serialized)
@MainActor
struct SettingsRootSeparatorTests {
    @Test func everyRowsSeparatorStartsAtItsTitle() async throws {
        let screen = SettingsRootViewController(root: AppRootEnvironment(
            coordinator: ConnectionCoordinator(serverStore: ServerStore()),
            navigation: AppNavigation(),
            themeStore: ThemeStore(),
            quickCommentTemplateStore: QuickCommentTemplateStore(templates: QuickCommentTemplate.builtInDefaults),
            composerDraftStore: ComposerDraftStore(),
            chatReaderPayloadStore: ChatReaderPayloadStore(),
            sessionRows: SessionRowDisplayStore(fixed: SessionRowDisplay())
        ))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 1200)
        window.rootViewController = screen
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let list = try #require(await Self.settingsList(on: screen))
        var checked = 0
        for case let cell as UICollectionViewListCell in list.visibleCells {
            guard let title = Self.title(in: cell) else { continue }
            checked += 1
            let guide = cell.separatorLayoutGuide.layoutFrame
            let name = title.text ?? ""
            #expect(
                abs(guide.minX - title.frame.minX) < 0.5,
                "\(name) separator starts at \(guide.minX), title at \(title.frame.minX)"
            )
        }
        #expect(checked >= 8, "Only \(checked) rows laid out")
    }

    private static func settingsList(on screen: SettingsRootViewController) async -> UICollectionView? {
        for _ in 0..<100 {
            screen.updateProperties()
            screen.view.layoutIfNeeded()
            if let list = collectionView(in: screen.view) { return list }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// The row's title label: the widest plain label the cell paints first.
    private static func title(in cell: UICollectionViewCell) -> UILabel? {
        cell.contentView.subviews
            .compactMap { $0 as? UILabel }
            .first { $0.text?.isEmpty == false }
    }

    private static func collectionView(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        for subview in view.subviews {
            if let found = collectionView(in: subview) { return found }
        }
        return nil
    }
}
