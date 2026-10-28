import Testing
import SwiftUI
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

    @Test("A page that mixes scopes has none of its own, so every section with a scope says it")
    func mixedPageSaysEverySectionsScope() {
        #expect(SettingsScope.footer("Footer.", scope: .device, pageScope: nil) == "Saved on this device. Footer.")
        #expect(SettingsScope.footer(nil, scope: .server("mac-studio"), pageScope: nil) == "Applies to every device on mac-studio.")
        #expect(SettingsScope.footer("Footer.", scope: nil, pageScope: nil) == "Footer.")
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

    @Test("The card is whichever of the system card and bgHighlight reads better against bg")
    func cardColorFollowsTheThemeWithEnoughContrast() {
        let system = UIColor.secondarySystemGroupedBackground
        func color(_ hex: Int) -> Color {
            Color(UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1))
        }

        // A built-in dark theme: its highlight reads better than the system card.
        let dark = ThemeID.dark.palette
        let darkStyle = SettingsStyle(palette: dark, isDark: true)
        #expect(darkStyle.card == UIColor(dark.bgHighlight))
        // Every built-in dark theme's card reads against its page.
        for id in [ThemeID.dark, .oled, .night] {
            let style = SettingsStyle(palette: id.palette, isDark: true)
            #expect(SettingsStyle.contrast(style.card, style.page, isDark: true) >= SettingsStyle.minimumCardContrast, "\(id)")
        }
        // Whichever color is chosen reads at least as well as the one passed over.
        for id in [ThemeID.dark, .oled, .night, .light] {
            let isDark = id != .light
            let palette = id.palette
            let style = SettingsStyle(palette: palette, isDark: isDark)
            let other = style.card == system ? UIColor(palette.bgHighlight) : system
            let chosen = SettingsStyle.contrast(style.card, style.page, isDark: isDark)
            let passedOver = SettingsStyle.contrast(other, style.page, isDark: isDark)
            if isDark {
                #expect(chosen >= passedOver, "\(id) passed over a color that reads better")
            } else if style.card == system {
                // A light theme keeps white while it reads, or while nothing reads better.
                #expect(chosen >= SettingsStyle.minimumCardContrast || chosen >= passedOver, "\(id)")
            } else {
                #expect(chosen > passedOver, "\(id) left white for a color that reads no better")
            }
        }

        // A dark bg near #1C1C1E is the system card's own color: any highlight that
        // differs more wins, and one that does not leaves the system card.
        var nearSystem = dark
        nearSystem.bg = color(0x1C1C1E)
        nearSystem.bgHighlight = color(0x2C2C30)
        #expect(SettingsStyle(palette: nearSystem, isDark: true).card == UIColor(nearSystem.bgHighlight))
        nearSystem.bgHighlight = color(0x1C1C1E)
        #expect(SettingsStyle(palette: nearSystem, isDark: true).card == system)

        // A light theme keeps the system (white) card when it reads against bg...
        #expect(SettingsStyle(palette: ThemeID.light.palette, isDark: false).card == system)

        // ...and takes bgHighlight when bg is white itself and the highlight reads better.
        var white = ThemeID.light.palette
        white.bg = color(0xFFFFFF)
        white.bgHighlight = color(0xE8E8EC)
        #expect(SettingsStyle(palette: white, isDark: false).card == UIColor(white.bgHighlight))
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

// MARK: - Live text size

extension SettingsKitTests {
    @Test("Every kit row re-measures when the text size changes live, and none of its text is cut off")
    func kitRowsGrowWithTheTextSize() async throws {
        let page = KitRowsPage()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 2400)
        window.rootViewController = page
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        page.traitOverrides.preferredContentSizeCategory = .large

        let rows = KitRowsPage.Row.allCases
        func heights() async -> [KitRowsPage.Row: CGFloat]? {
            for _ in 0..<150 {
                page.view.layoutIfNeeded()
                let cells = rows.compactMap { row in
                    page.dataSource?.indexPath(for: row).flatMap { page.collectionView.cellForItem(at: $0) }.map { (row, $0.bounds.height) }
                }
                if cells.count == rows.count { return Dictionary(uniqueKeysWithValues: cells) }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return nil
        }
        let before = try #require(await heights())
        // At the standard size the index row's value sits beside its title.
        let indexLines = try Self.indexRowLines(in: page)
        #expect(abs(indexLines.title.midY - indexLines.value.midY) < 1, "the value should share the title's line at .large")

        page.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        var after = before
        for _ in 0..<150 {
            page.view.layoutIfNeeded()
            after = (await heights()) ?? before
            if rows.allSatisfy({ (after[$0] ?? 0) > (before[$0] ?? .greatestFiniteMagnitude) }) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        for row in rows {
            #expect((after[row] ?? 0) > (before[row] ?? .greatestFiniteMagnitude), "\(row) did not grow: \(before[row] ?? 0) -> \(after[row] ?? 0)")
        }

        // At the largest size it sits under the title instead of squeezing it.
        let stacked = try Self.indexRowLines(in: page)
        #expect(stacked.value.minY >= stacked.title.maxY - 0.5, "the value should sit under the title at XXXL")

        // Nothing the rows say is clipped or truncated at the larger size.
        page.view.layoutIfNeeded()
        for row in rows {
            var checked = 0
            guard let indexPath = page.dataSource?.indexPath(for: row), let cell = page.collectionView.cellForItem(at: indexPath) else {
                Issue.record("\(row) has no cell")
                continue
            }
            for label in Self.labels(in: cell) where !(label.text ?? "").isEmpty && !label.isHidden && label.bounds.width > 0 {
                checked += 1
                let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                #expect(needed.height <= label.bounds.height + 1, "\(row): \"\(label.text ?? "")\" is clipped (\(needed.height) > \(label.bounds.height))")
                if label.numberOfLines == 1 {
                    #expect(label.intrinsicContentSize.width <= label.bounds.width + 1, "\(row): \"\(label.text ?? "")\" is truncated")
                }
            }
            // Every row has its text inspected: the index row has a title and a value.
            #expect(checked >= (row == .index ? 2 : 1), "\(row): only \(checked) labels were checked")
        }
    }

    /// The index row's title and value label frames, in the cell's space.
    private static func indexRowLines(in page: SettingsListViewController<KitRowsPage.Section, KitRowsPage.Row>) throws -> (title: CGRect, value: CGRect) {
        page.view.layoutIfNeeded()
        let indexPath = try #require(page.dataSource?.indexPath(for: .index))
        let cell = try #require(page.collectionView.cellForItem(at: indexPath))
        let labels = Self.labels(in: cell)
        let title = try #require(labels.first { $0.text == "Terminal Colors" })
        let value = try #require(labels.first { $0.text == "Standard" })
        return (title.convert(title.bounds, to: cell), value.convert(value.bounds, to: cell))
    }

    private static func labels(in view: UIView) -> [UILabel] {
        var found: [UILabel] = []
        if let label = view as? UILabel { found.append(label) }
        for subview in view.subviews { found += labels(in: subview) }
        return found
    }
}

/// One of each kit row, with text long enough to wrap at the largest sizes.
private final class KitRowsPage: SettingsListViewController<KitRowsPage.Section, KitRowsPage.Row> {
    enum Section: Hashable, Sendable { case rows }
    enum Row: CaseIterable, Hashable, Sendable { case index, menu, action, state, toggle, info }

    init() {
        super.init(title: "Kit", listIdentifier: "test.kit.list", scope: .device)
    }

    override func sections() -> [SettingsSectionModel<Section, Row>] {
        [SettingsSectionModel(.rows, items: Row.allCases)]
    }

    private lazy var indexRow = UICollectionView.CellRegistration<SettingsIndexRowCell, Row> { cell, _, _ in
        cell.configure(title: "Terminal Colors", systemImage: "paintpalette", value: "Standard", identifier: "test.index") {}
    }

    private lazy var menuRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Row> { cell, _, _ in
        cell.configure(
            title: "Keep Awake After Activity",
            identifier: "test.menu",
            options: [("2 minutes", true, {}), ("5 minutes", false, {})]
        )
    }

    private lazy var actionRow = UICollectionView.CellRegistration<SettingsActionRowCell, Row> { cell, _, _ in
        cell.configure(title: "Remove Saved Sudo Password", systemImage: "trash", tint: .destructive, identifier: "test.action") {}
    }

    private lazy var stateRow = UICollectionView.CellRegistration<SettingsStateRowCell, Row> { cell, _, _ in
        cell.configure(.failure("Skills are unavailable. The selected server has no cached Skills catalog.", retry: {}))
    }

    override func prepareRegistrations() {
        _ = (indexRow, menuRow, actionRow, stateRow)
    }

    override func dequeue(_ item: Row, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .index: collectionView.dequeueConfiguredReusableCell(using: indexRow, for: indexPath, item: item)
        case .menu: collectionView.dequeueConfiguredReusableCell(using: menuRow, for: indexPath, item: item)
        case .action: collectionView.dequeueConfiguredReusableCell(using: actionRow, for: indexPath, item: item)
        case .state: collectionView.dequeueConfiguredReusableCell(using: stateRow, for: indexPath, item: item)
        case .toggle, .info: super.dequeue(item, at: indexPath)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Row) {
        switch item {
        case .toggle:
            toggleRow(cell, title: "Close Brackets and Quotes", isOn: true) { _ in }
        default:
            var content = content(.info)
            content.text = "Local Cache"
            content.secondaryText = "Calculating a long local cache size"
            cell.contentConfiguration = content
        }
    }
}
