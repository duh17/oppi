import Testing
import UIKit
@testable import Oppi

@Suite("Settings kit")
@MainActor
struct SettingsKitTests {
    @Test("A section says its scope only when it differs from the page's")
    func scopeSentenceAppearsOnlyWhereTheSectionDiffers() {
        let page = SettingsScope.device
        // The page's own scope, and no scope at all, leave the footer alone.
        #expect(SettingsScope.footer("Footer.", scope: nil, pageScope: page) == "Footer.")
        #expect(SettingsScope.footer("Footer.", scope: .device, pageScope: page) == "Footer.")
        #expect(SettingsScope.footer(nil, scope: nil, pageScope: page) == nil)
        // A differing scope puts its sentence in front, or stands alone.
        #expect(
            SettingsScope.footer("Footer.", scope: .server("mac-studio"), pageScope: page)
                == "Applies to every device on mac-studio. Footer."
        )
        #expect(SettingsScope.footer(nil, scope: .workspace("oppi"), pageScope: page) == "Applies to this workspace.")
        #expect(SettingsScope.footer("", scope: .workspace("oppi"), pageScope: page) == "Applies to this workspace.")
        #expect(
            SettingsScope.footer("Footer.", scope: .device, pageScope: .server("mac-studio"))
                == "Saved on this device. Footer."
        )
        #expect(
            SettingsScope.footer(nil, scope: .deviceOnServer("mac-studio"), pageScope: page)
                == "For this device, kept on mac-studio."
        )
    }

    @Test("A page's footer shows the scope sentence of a section that differs")
    func pageFooterCarriesTheScopeSentence() async throws {
        let page = ScopedPage()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        window.rootViewController = page
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        var footers: [String] = []
        for _ in 0..<100 {
            page.view.layoutIfNeeded()
            footers = Self.footerTexts(in: page.collectionView)
            if footers.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(footers.sorted() == ["Applies to every device on mac-studio. Kept on the server.", "Kept here."])
    }

    @Test("A failure row's button retries; a message row has nothing to press")
    func stateRowButton() throws {
        let cell = SettingsStateRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 80))
        let button = try #require(cell.accessibilityElements?.first as? UIButton)
        var retried = 0
        cell.configure(.failure("Could not load.", retry: { retried += 1 }), identifier: "test.retry")
        #expect(button.isUserInteractionEnabled)
        #expect(button.accessibilityIdentifier == "test.retry")
        button.sendActions(for: .touchUpInside)
        #expect(retried == 1)

        cell.configure(.failure("Could not load.", retry: nil))
        #expect(!button.isUserInteractionEnabled)
        cell.configure(.message("Nothing here."))
        #expect(!button.isUserInteractionEnabled)
        // A reused cell does not keep the retry it had.
        button.sendActions(for: .touchUpInside)
        #expect(retried == 1)
    }

    @Test("A disabled or busy action row cannot be pressed and says so")
    func actionRowStaysStillWhenDisabledOrBusy() throws {
        let cell = SettingsActionRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 60))
        let button = try #require(cell.accessibilityElements?.first as? UIButton)
        var ran = 0
        cell.configure(title: "Connect", identifier: "test.action") { ran += 1 }
        #expect(button.isEnabled)
        button.sendActions(for: .touchUpInside)
        #expect(ran == 1)

        cell.configure(title: "Connect", identifier: "test.action", isEnabled: false) { ran += 1 }
        #expect(!button.isEnabled)
        #expect(button.accessibilityTraits.contains(.notEnabled))
        cell.configure(title: "Connect", identifier: "test.action", isBusy: true) { ran += 1 }
        #expect(!button.isEnabled)
        #expect(button.accessibilityValue != nil)
    }

    @Test("A dark theme's card is its bgHighlight unless that is too close to bg; a light theme keeps the system card")
    func cardColorFollowsTheThemeWithEnoughContrast() {
        let system = UIColor.secondarySystemGroupedBackground
        let dark = ThemeID.dark.palette
        let darkStyle = SettingsStyle(palette: dark, isDark: true)
        #expect(darkStyle.card == UIColor(dark.bgHighlight))
        #expect(SettingsStyle.contrast(darkStyle.card, darkStyle.page) >= SettingsStyle.minimumCardContrast)

        // An imported dark theme whose highlight barely differs from its page.
        var flat = dark
        flat.bgHighlight = flat.bg
        #expect(SettingsStyle(palette: flat, isDark: true).card == system)

        // A light theme keeps the system card whatever its highlight is.
        #expect(SettingsStyle(palette: ThemeID.light.palette, isDark: false).card == system)

        // Every built-in dark theme's card reads against its page.
        for id in [ThemeID.dark, .oled, .night] {
            let style = SettingsStyle(palette: id.palette, isDark: true)
            #expect(SettingsStyle.contrast(style.card, style.page) >= SettingsStyle.minimumCardContrast, "\(id)")
        }
    }

    private static func footerTexts(in collectionView: UICollectionView) -> [String] {
        let kind = UICollectionView.elementKindSectionFooter
        return collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind).compactMap { indexPath in
            let view = collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? UICollectionViewListCell
            return (view?.contentConfiguration as? UIListContentConfiguration)?.text
        }
    }
}

/// A page on the device whose second section lives on a server.
private final class ScopedPage: SettingsListViewController<ScopedPage.Section, Int> {
    enum Section: Hashable, Sendable { case local, remote }

    init() {
        super.init(title: "Scoped", listIdentifier: "test.scoped.list", scope: .device, footers: true)
    }

    override func sections() -> [SettingsSectionModel<Section, Int>] {
        [
            SettingsSectionModel(.local, footer: "Kept here.", items: [1]),
            SettingsSectionModel(.remote, footer: "Kept on the server.", scope: .server("mac-studio"), items: [2]),
        ]
    }
}
