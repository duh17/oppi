import Foundation
import Testing
import UIKit
@testable import Oppi

/// Settings > Chat > Top Bar over the real page and a `UserDefaults` suite of
/// its own: the rows are the stored order, each switch says whether its button
/// is on the bar, and a switch or a drag writes the layout the chat's bar reads.
/// A page made again on the same defaults is what a relaunch shows.
@Suite("Settings Chat Top Bar page", .serialized)
@MainActor
struct SettingsChatTopBarPageTests {
    private struct Harness {
        var page: SettingsChatTopBarViewController
        var window: UIWindow
    }

    private func show(on defaults: UserDefaults) async throws -> Harness {
        let page = SettingsChatTopBarViewController(defaults: defaults)
        let window = makeSceneWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        let rowCount = ChatTopBarAction.allCases.count
        #expect(await waitForMainActorCondition {
            page.view.layoutIfNeeded()
            return page.collectionView.visibleCells.count == rowCount
        }, "the page must draw a row for every button")
        return Harness(page: page, window: window)
    }

    private func hide(_ harness: Harness) {
        hideTestWindow(harness.window)
    }

    private func cell(_ action: ChatTopBarAction, in page: SettingsChatTopBarViewController) -> UICollectionViewListCell? {
        page.indexPath(for: action).flatMap { page.collectionView.cellForItem(at: $0) as? UICollectionViewListCell }
    }

    private func toggle(_ action: ChatTopBarAction, in page: SettingsChatTopBarViewController) throws -> UISwitch {
        let drawn = Self.switches(in: try #require(cell(action, in: page), "\(action) has no row"))
        #expect(drawn.count == 1, "\(action)'s row must carry one switch")
        let toggle = try #require(drawn.first)
        #expect(toggle.accessibilityIdentifier == "settings.chat.topBar.\(action.rawValue)")
        return toggle
    }

    private static func switches(in view: UIView) -> [UISwitch] {
        let own = (view as? UISwitch).map { [$0] } ?? []
        return own + view.subviews.flatMap(switches)
    }

    /// The rows top to bottom, by the identifier each row carries.
    private func rowIdentifiers(_ page: SettingsChatTopBarViewController) -> [String?] {
        page.shownItems.map { cell($0, in: page)?.accessibilityIdentifier }
    }

    @Test("Nothing saved: the default bar, Context on and the rest in the menu, and Terminal's switch works like the others")
    func theDefaultLayoutReadsAsTheDefaultBar() async throws {
        let h = try await show(on: makeSettingsDefaults())
        defer { hide(h) }

        #expect(h.page.shownItems == [.files, .git, .outline, .context, .terminal])
        #expect(try toggle(.context, in: h.page).isOn, "Context starts on")
        for action in [ChatTopBarAction.files, .git, .outline, .terminal] {
            #expect(try !toggle(action, in: h.page).isOn, "\(action) starts in the menu")
        }
        #expect(try toggle(.terminal, in: h.page).isEnabled, "Terminal's switch works like the others")
    }

    @Test("A stored order is the rows' order; the page is always editing, so every row can be dragged")
    func theRowsFollowTheStoredOrder() async throws {
        let defaults = makeSettingsDefaults()
        AppPreferences.ChatTopBar.setLayout(
            ChatTopBarLayout(order: [.outline, .files, .context, .git, .terminal], shown: Set(ChatTopBarAction.allCases)),
            in: defaults
        )
        let h = try await show(on: defaults)
        defer { hide(h) }

        #expect(rowIdentifiers(h.page) == ["outline", "files", "context", "git", "terminal"].map { "settings.chat.topBar.row.\($0)" })
        #expect(h.page.collectionView.isEditing, "the page is always in editing mode, with no Edit button")
        // What the list asks before a row's handle can start a drag.
        let dataSource = try #require(h.page.dataSource)
        for action in h.page.shownItems {
            let indexPath = try #require(h.page.indexPath(for: action))
            #expect(
                dataSource.collectionView(h.page.collectionView, canMoveItemAt: indexPath),
                "\(action) must keep its reorder handle"
            )
        }
        for action in ChatTopBarAction.allCases {
            #expect(try toggle(action, in: h.page).isOn, "\(action) is on the bar")
        }
    }

    @Test("A switch pins its button: the layout keeps the order and shows it, and the page reads it back")
    func aSwitchWritesTheLayout() async throws {
        let defaults = makeSettingsDefaults()
        let h = try await show(on: defaults)
        defer { hide(h) }

        let outline = try toggle(.outline, in: h.page)
        #expect(!outline.isOn, "Outline starts in the menu")
        outline.isOn = true
        outline.sendActions(for: .valueChanged)

        let written = AppPreferences.ChatTopBar.layout(in: defaults)
        #expect(written.shown == [.outline, .context])
        #expect(written.order == [.files, .git, .outline, .context, .terminal], "a switch must not move its row")
        hide(h)

        let again = try await show(on: defaults)
        defer { hide(again) }
        #expect(try toggle(.outline, in: again.page).isOn, "the pinned button must still be pinned on the next visit")
    }

    @Test("A drag writes the order: Terminal moved to the top is the bar's order, switches untouched, and the page reads it back")
    func aDragWritesTheOrder() async throws {
        let defaults = makeSettingsDefaults()
        let h = try await show(on: defaults)
        defer { hide(h) }
        let dataSource = try #require(h.page.dataSource)
        let from = try #require(h.page.indexPath(for: .terminal))
        let to = try #require(h.page.indexPath(for: .files))

        // What the list calls when a drag on a handle drops the row.
        dataSource.collectionView(h.page.collectionView, moveItemAt: from, to: to)

        let written = AppPreferences.ChatTopBar.layout(in: defaults)
        #expect(written.order == [.terminal, .files, .git, .outline, .context])
        #expect(written.shown == [.context], "a drag must not change which buttons are on")
        hide(h)

        let again = try await show(on: defaults)
        defer { hide(again) }
        #expect(again.page.shownItems == [.terminal, .files, .git, .outline, .context])
        #expect(try toggle(.context, in: again.page).isOn)
        #expect(try !toggle(.terminal, in: again.page).isOn)
    }
}
