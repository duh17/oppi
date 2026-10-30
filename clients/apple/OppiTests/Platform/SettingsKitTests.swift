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
        // A page with no scope of its own says nothing of its own; a section that
        // declares one still does.
        #expect(SettingsScope.footer("Footer.", scope: nil, pageScope: nil) == "Footer.")
        #expect(SettingsScope.footer("Footer.", scope: .device, pageScope: nil) == "Saved on this device. Footer.")
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
        defer { hideTestWindow(window); window.rootViewController = nil }

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

    @Test("A section's state row is the list's LoadState, with its identifier and its Retry")
    func sectionStateRow() async throws {
        let page = StateRowsPage()
        page.state = .failed(
            title: "Could not load.", message: nil, retry: RetryAction { [weak page] in page?.retry() }
        )
        let window = try show(page)
        defer { hideTestWindow(window); window.rootViewController = nil }

        // The failed state: one button whose label is the state's words, under the
        // page's identifier, and a tap runs the Retry.
        var retry: UIButton?
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            retry = Self.button(withIdentifier: "test.state", in: page.collectionView)
            return retry != nil
        })
        let button = try #require(retry)
        #expect(button.accessibilityLabel == "Could not load.")
        #expect(button.accessibilityTraits.contains(.button))
        button.sendActions(for: .touchUpInside)
        #expect(page.retries == 1)

        // The empty state is a line of text with nothing to press; the loading
        // state keeps the spinner's row.
        page.state = .empty(title: "Nothing here.", systemImage: "tray")
        page.setNeedsUpdateProperties()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            let row = Self.button(withIdentifier: "test.state", in: page.collectionView)
            return row?.accessibilityLabel == "Nothing here." && row?.isUserInteractionEnabled == false
        })
        page.state = .loading("Loading things…")
        page.setNeedsUpdateProperties()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            return Self.button(withIdentifier: "test.state", in: page.collectionView)?.accessibilityLabel
                == "Loading things…"
        })
    }

    @Test("The list loads when the page appears, and again on pull to refresh")
    func refreshOnAppearanceAndPull() async throws {
        let page = RefreshPage()
        let window = try show(page)
        defer { hideTestWindow(window); window.rootViewController = nil }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.refreshes == 1 }, "appearing loads")

        page.collectionView.refreshControl?.sendActions(for: .valueChanged)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.refreshes == 2 }, "pull to refresh loads")

        // Leaving says the page is not showing, so a covered list keeps still.
        window.rootViewController = UIViewController()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !page.isShowing })
    }

    @Test("Only a page that loads its content pulls to refresh")
    func pullToRefreshIsOptedInto() {
        let plain = ScopedPage()
        plain.loadViewIfNeeded()
        #expect(plain.collectionView.refreshControl == nil, "a page that loads nothing has no spinner to pull")

        let loading = RefreshPage()
        loading.loadViewIfNeeded()
        #expect(loading.collectionView.refreshControl != nil)
    }

    @Test("A page shows a header only on the sections it names")
    func headerPerSection() async throws {
        let page = HeaderPage()
        let window = try show(page)
        defer { hideTestWindow(window); window.rootViewController = nil }

        #expect(page.showsHeader(for: .titled))
        #expect(!page.showsHeader(for: .plain))

        var headers: [String?] = []
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            headers = Self.headerTexts(in: page.collectionView)
            return headers.compactMap { $0 } == ["With Heading"]
        })
        #expect(headers.compactMap { $0 } == ["With Heading"], "the section the page does not name has no header at all")
    }

    @Test("A page with no rows at all is its whole-screen state; a row takes the screen back")
    func wholeScreenStateWhenThereAreNoRows() async throws {
        let page = WholeScreenStatePage()
        let window = try show(page)
        defer { hideTestWindow(window); window.rootViewController = nil }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            return page.contentUnavailableConfiguration != nil
        }, "a page with no rows shows its state over the whole screen")
        #expect(page.shownItems.isEmpty)

        page.hasRow = true
        page.setNeedsUpdateProperties()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            return page.contentUnavailableConfiguration == nil && page.shownItems == [1]
        }, "a page with a row is its rows, whatever its state says")
    }

    private static func headerTexts(in collectionView: UICollectionView) -> [String?] {
        let kind = UICollectionView.elementKindSectionHeader
        return collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind).compactMap { indexPath in
            guard let view = collectionView.supplementaryView(forElementKind: kind, at: indexPath)
                as? UICollectionViewListCell else { return nil }
            return (view.contentConfiguration as? UIListContentConfiguration)?.text
        }
    }

    private static func button(withIdentifier identifier: String, in list: UICollectionView) -> UIButton? {
        for cell in list.visibleCells {
            if let button = button(withIdentifier: identifier, inside: cell) { return button }
        }
        return nil
    }

    private static func button(withIdentifier identifier: String, inside view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { return button }
        for subview in view.subviews {
            if let found = button(withIdentifier: identifier, inside: subview) { return found }
        }
        return nil
    }

    private func show(_ page: UIViewController) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        window.rootViewController = page
        window.makeKeyAndVisible()
        return window
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
private final class ScopedPage: ListScreenController<ScopedPage.Section, Int> {
    enum Section: Hashable, Sendable { case local, remote }

    init() {
        super.init(title: "Scoped", listIdentifier: "test.scoped.list", scope: .device, footers: true)
    }

    override func sections() -> [ListSection<Section, Int>] {
        [
            ListSection(.local, footer: "Kept here.", items: [1]),
            ListSection(.remote, footer: "Kept on the server.", scope: .server("mac-studio"), items: [2]),
        ]
    }
}

/// A page whose whole content is a state: the base draws it from `LoadState`.
private final class StateRowsPage: ListScreenController<StateRowsPage.Section, Int> {
    enum Section: Hashable, Sendable { case only }

    var state: LoadState = .loading("Loading things…")
    /// How often the state's Retry ran.
    private(set) var retries = 0

    init() {
        super.init(title: "States", listIdentifier: "test.state.list")
    }

    func retry() { retries += 1 }

    override func sections() -> [ListSection<Section, Int>] {
        [ListSection(.only, items: [], state: ListStateRow(state: state, identifier: "test.state"))]
    }
}

/// A page that has only its own state: no rows, so the base paints it over the
/// whole screen instead of in a row.
private final class WholeScreenStatePage: ListScreenController<WholeScreenStatePage.Section, Int> {
    enum Section: Hashable, Sendable { case only }

    var hasRow = false

    init() {
        super.init(title: "Whole", listIdentifier: "test.whole.list")
    }

    override func sections() -> [ListSection<Section, Int>] {
        hasRow ? [ListSection(.only, items: [1])] : []
    }

    override func wholeScreenState() -> LoadState? {
        .loading("Loading the resource…")
    }
}

/// A page that counts its loads.
private final class RefreshPage: ListScreenController<RefreshPage.Section, Int> {
    enum Section: Hashable, Sendable { case only }

    private(set) var refreshes = 0

    init() {
        super.init(title: "Refresh", listIdentifier: "test.refresh.list", pullsToRefresh: true)
    }

    override func sections() -> [ListSection<Section, Int>] { [ListSection(.only, items: [1])] }

    override func refresh() async { refreshes += 1 }
}

/// A page with two sections, only one of which carries a heading.
private final class HeaderPage: ListScreenController<HeaderPage.Section, Int> {
    enum Section: Hashable, Sendable { case titled, plain }

    init() {
        super.init(title: "Headers", listIdentifier: "test.headers.list", headers: true)
    }

    override func sections() -> [ListSection<Section, Int>] {
        [ListSection(.titled, header: "With Heading", items: [1]), ListSection(.plain, items: [2])]
    }

    override func showsHeader(for section: Section) -> Bool {
        if case .titled = section { return true }
        return false
    }
}

// MARK: - Live text size

extension SettingsKitTests {
    @Test("Every kit row re-measures when the text size changes live, and none of its text is cut off")
    func kitRowsGrowWithTheTextSize() async throws {
        let page = KitRowsPage()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 3600)
        window.rootViewController = page
        window.makeKeyAndVisible()
        // The AX5 override must not outlive the test: a later test's page measures at it.
        defer {
            page.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
            hideTestWindow(window)
            window.rootViewController = nil
        }
        page.traitOverrides.preferredContentSizeCategory = .large

        let rows = KitRowsPage.Row.allCases
        func heights() async -> [KitRowsPage.Row: CGFloat]? {
            for _ in 0..<150 {
                page.view.layoutIfNeeded()
                let cells = rows.compactMap { row in
                    page.indexPath(for: row).flatMap { page.collectionView.cellForItem(at: $0) }.map { (row, $0.bounds.height) }
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
        let menuBefore = try Self.menuRowLines(in: page)
        #expect(abs(menuBefore.title.midY - menuBefore.value.midY) < 1, "the choice should share the title's line at .large")
        // The Style row's control shares the title's line at the standard size.
        let segmentedBefore = try Self.segmentedRowFrames(in: page)
        #expect(abs(segmentedBefore.title.midY - segmentedBefore.control.midY) < 1, "the control should share the title's line at .large")
        // The preview pill holds its text at the standard size.
        let pillBefore = try Self.workPreviewFrames(in: page)
        for text in pillBefore.texts {
            #expect(pillBefore.pill.insetBy(dx: -0.5, dy: -0.5).contains(text), "work preview text sits outside its pill at .large: \(text)")
        }

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
        // The menu row's choice sits under its title too, inside the row instead of past its edge.
        let menuStacked = try Self.menuRowLines(in: page)
        #expect(menuStacked.value.minY >= menuStacked.title.maxY - 0.5, "the choice should sit under the title at XXXL")
        #expect(menuStacked.value.maxX <= menuStacked.cellWidth + 0.5, "the choice runs off the row at XXXL")

        // The Style row's control sits under its title, inside the row.
        let segmentedStacked = try Self.segmentedRowFrames(in: page)
        #expect(segmentedStacked.control.minY >= segmentedStacked.title.maxY - 0.5, "the control should sit under the title at XXXL")
        #expect(segmentedStacked.control.maxX <= segmentedStacked.cellWidth + 0.5, "the control runs off the row at XXXL")
        #expect(segmentedStacked.control.maxY <= segmentedStacked.cellHeight + 0.5, "the control runs off the bottom of the row at XXXL")
        // The preview pill grows around its text instead of letting it spill out.
        let pillStacked = try Self.workPreviewFrames(in: page)
        #expect(pillStacked.texts.count >= 2, "the pill's text was not found")
        for text in pillStacked.texts {
            #expect(pillStacked.pill.insetBy(dx: -0.5, dy: -0.5).contains(text), "work preview text spills out of its pill at XXXL: \(text)")
        }
        #expect(pillStacked.pill.maxY <= pillStacked.cellHeight + 0.5, "the pill runs off the bottom of the row at XXXL")

        // Nothing the rows say is clipped or truncated at the larger size.
        page.view.layoutIfNeeded()
        for row in rows {
            var checked = 0
            guard let indexPath = page.indexPath(for: row), let cell = page.collectionView.cellForItem(at: indexPath) else {
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
            #expect(checked >= (row == .index || row == .slider || row == .entry || row == .work ? 2 : 1), "\(row): only \(checked) labels were checked")
        }
    }

    /// The index row's title and value label frames, in the cell's space.
    private static func indexRowLines(in page: ListScreenController<KitRowsPage.Section, KitRowsPage.Row>) throws -> (title: CGRect, value: CGRect) {
        page.view.layoutIfNeeded()
        let indexPath = try #require(page.indexPath(for: .index))
        let cell = try #require(page.collectionView.cellForItem(at: indexPath))
        let labels = Self.labels(in: cell)
        let title = try #require(labels.first { $0.text == "Terminal Colors" })
        let value = try #require(labels.first { $0.text == "Standard" })
        return (title.convert(title.bounds, to: cell), value.convert(value.bounds, to: cell))
    }

    /// The menu row's title and choice label frames in the cell's space, and the cell's width.
    private static func menuRowLines(in page: ListScreenController<KitRowsPage.Section, KitRowsPage.Row>) throws -> (title: CGRect, value: CGRect, cellWidth: CGFloat) {
        page.view.layoutIfNeeded()
        let indexPath = try #require(page.indexPath(for: .menu))
        let cell = try #require(page.collectionView.cellForItem(at: indexPath))
        let labels = Self.labels(in: cell)
        let title = try #require(labels.first { $0.text == "Voice Replies" })
        let value = try #require(labels.first { $0.text == "Agent decides" })
        return (title.convert(title.bounds, to: cell), value.convert(value.bounds, to: cell), cell.bounds.width)
    }

    /// The Style row's title and control frames in the cell's space, and the cell's size.
    private static func segmentedRowFrames(in page: ListScreenController<KitRowsPage.Section, KitRowsPage.Row>) throws -> (title: CGRect, control: CGRect, cellWidth: CGFloat, cellHeight: CGFloat) {
        page.view.layoutIfNeeded()
        let indexPath = try #require(page.indexPath(for: .segmented))
        let cell = try #require(page.collectionView.cellForItem(at: indexPath))
        let title = try #require(Self.labels(in: cell).first { $0.text == "Style" })
        let control = try #require(Self.views(of: UISegmentedControl.self, in: cell).first)
        return (title.convert(title.bounds, to: cell), control.convert(control.bounds, to: cell), cell.bounds.width, cell.bounds.height)
    }

    /// The preview pill's frame and the frames of the text drawn on it, in the cell's space.
    private static func workPreviewFrames(in page: ListScreenController<KitRowsPage.Section, KitRowsPage.Row>) throws -> (pill: CGRect, texts: [CGRect], cellHeight: CGFloat) {
        page.view.layoutIfNeeded()
        let indexPath = try #require(page.indexPath(for: .work))
        let cell = try #require(page.collectionView.cellForItem(at: indexPath))
        let pill = try #require(Self.views(of: TimelineChromeSurfaceView.self, in: cell).first)
        let texts = Self.labels(in: cell)
            .filter { $0.text != "Preview" && !($0.text ?? $0.attributedText?.string ?? "").isEmpty && !$0.isHidden }
            .map { $0.convert($0.bounds, to: cell) }
        return (pill.convert(pill.bounds, to: cell), texts, cell.bounds.height)
    }

    private static func views<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for subview in view.subviews { found += views(of: type, in: subview) }
        return found
    }

    private static func labels(in view: UIView) -> [UILabel] {
        var found: [UILabel] = []
        if let label = view as? UILabel { found.append(label) }
        for subview in view.subviews { found += labels(in: subview) }
        return found
    }
}

/// One of each kit row, with text long enough to wrap at the largest sizes.
private final class KitRowsPage: ListScreenController<KitRowsPage.Section, KitRowsPage.Row> {
    enum Section: Hashable, Sendable { case rows }
    enum Row: CaseIterable, Hashable, Sendable { case index, menu, menuLong, action, state, slider, entry, segmented, work, toggle, info }

    init() {
        super.init(title: "Kit", listIdentifier: "test.kit.list", scope: .device)
    }

    override func sections() -> [ListSection<Section, Row>] {
        [ListSection(.rows, items: Row.allCases)]
    }

    private lazy var indexRow = UICollectionView.CellRegistration<SettingsIndexRowCell, Row> { cell, _, _ in
        cell.configure(title: "Terminal Colors", systemImage: "paintpalette", value: "Standard", identifier: "test.index") {}
    }

    private lazy var menuRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Row> { cell, _, _ in
        cell.configure(
            title: "Voice Replies",
            identifier: "test.menu",
            options: [("Agent decides", true, {}), ("Manual", false, {})]
        )
    }

    /// A long title with a short choice: the title wraps and the choice stays beside its last line or under it.
    private lazy var menuLongRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Row> { cell, _, _ in
        cell.configure(
            title: "Keep Awake After Activity",
            identifier: "test.menuLong",
            options: [("2 minutes", true, {}), ("5 minutes", false, {})]
        )
    }

    private lazy var actionRow = UICollectionView.CellRegistration<SettingsActionRowCell, Row> { cell, _, _ in
        cell.configure(title: "Remove Saved Sudo Password", systemImage: "trash", tint: .destructive, identifier: "test.action") {}
    }

    private lazy var stateRow = UICollectionView.CellRegistration<SettingsStateRowCell, Row> { cell, _, _ in
        cell.configure(.failure("Skills are unavailable. The selected server has no cached Skills catalog.", retry: {}))
    }

    private lazy var sliderRow = UICollectionView.CellRegistration<SettingsSliderRowCell, Row> { cell, _, _ in
        cell.configure(
            title: "Message Text Size and a longer name", valueText: "110%", spokenValue: "110 percent",
            value: 1.1, range: 0.8...1.5, step: 0.05, identifier: "test.slider"
        ) { _ in }
    }

    private lazy var entryRow = UICollectionView.CellRegistration<SettingsEntryRowCell, Row> { cell, _, _ in
        cell.configure(
            title: "Explain this part of the code in more detail",
            caption: "Explain how this works, with a longer line of text under it.",
            systemImage: "questionmark.bubble", identifier: "test.entry"
        ) {}
    }

    private lazy var segmentedRow = UICollectionView.CellRegistration<SettingsSegmentedRowCell, Row> { cell, _, _ in
        cell.configure(
            title: "Style",
            identifier: "test.segmented",
            options: [("Full", false), ("Compact", false), ("Chat", true)]
        ) { _ in }
    }

    /// The conversation pill: "Worked 9s · 2 steps" on a capsule.
    private lazy var workRow = UICollectionView.CellRegistration<SettingsWorkPreviewCell, Row> { cell, _, _ in
        cell.configureWorkLine(
            SettingsChatViewController.conversationSample,
            chromeStyle: .conversation,
            caption: "Preview",
            symbol: "bubble.left.and.text.bubble.right",
            labelColor: .secondaryLabel
        )
    }

    override func prepareRegistrations() {
        _ = (indexRow, menuRow, menuLongRow, actionRow, stateRow, sliderRow, entryRow, segmentedRow, workRow)
    }

    override func dequeue(_ item: Row, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .index: collectionView.dequeueConfiguredReusableCell(using: indexRow, for: indexPath, item: item)
        case .menu: collectionView.dequeueConfiguredReusableCell(using: menuRow, for: indexPath, item: item)
        case .menuLong: collectionView.dequeueConfiguredReusableCell(using: menuLongRow, for: indexPath, item: item)
        case .action: collectionView.dequeueConfiguredReusableCell(using: actionRow, for: indexPath, item: item)
        case .state: collectionView.dequeueConfiguredReusableCell(using: stateRow, for: indexPath, item: item)
        case .slider: collectionView.dequeueConfiguredReusableCell(using: sliderRow, for: indexPath, item: item)
        case .entry: collectionView.dequeueConfiguredReusableCell(using: entryRow, for: indexPath, item: item)
        case .segmented: collectionView.dequeueConfiguredReusableCell(using: segmentedRow, for: indexPath, item: item)
        case .work: collectionView.dequeueConfiguredReusableCell(using: workRow, for: indexPath, item: item)
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
