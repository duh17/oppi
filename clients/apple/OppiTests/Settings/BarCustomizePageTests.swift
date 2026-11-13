import Foundation
import Testing
import UIKit
@testable import Oppi

/// Customize, the one screen every customizable bar uses, over the real page
/// and a `UserDefaults` suite of its own (the chat's top bar here): the rows are
/// the stored order, a switch and a drag write the layout the bar reads, and
/// Reset to Default shows only while the layout differs from the default.
@Suite("Bar Customize page", .serialized)
@MainActor
struct BarCustomizePageTests {
    private typealias Page = BarCustomizeViewController<ChatTopBarAction, Never>

    private func show(on defaults: UserDefaults) async throws -> (page: Page, window: UIWindow) {
        let page = Page(surface: .chatTopBar(defaults: defaults))
        let window = makeSceneWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        #expect(await waitForMainActorCondition {
            page.view.layoutIfNeeded()
            return page.collectionView.visibleCells.count >= ChatTopBarAction.allCases.count
        }, "the page must draw a row for every button")
        return (page, window)
    }

    private func toggle(_ action: ChatTopBarAction, in page: Page) throws -> UISwitch {
        let cell = try #require(page.indexPath(for: .action(action)).flatMap { page.collectionView.cellForItem(at: $0) })
        let found = Self.switches(in: cell)
        #expect(found.count == 1, "\(action)'s row must carry one switch")
        let toggle = try #require(found.first)
        #expect(toggle.accessibilityIdentifier == "settings.chat.topBar.\(action.rawValue)")
        return toggle
    }

    private static func switches(in view: UIView) -> [UISwitch] {
        ((view as? UISwitch).map { [$0] } ?? []) + view.subviews.flatMap(switches)
    }

    private static func buttons(in view: UIView) -> [UIButton] {
        ((view as? UIButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons)
    }

    @Test("A switch and a drag write the layout; Reset to Default appears once it differs and brings the default back")
    func switchesAndDragsWriteTheLayoutAndResetRestoresIt() async throws {
        let defaults = try makeSettingsDefaults()
        let h = try await show(on: defaults)
        defer { hideTestWindow(h.window) }

        #expect(h.page.shownItems == ChatTopBarAction.allCases.map(Page.Row.action), "nothing saved reads as the default bar")
        #expect(!h.page.shownItems.contains(.reset), "the default bar offers no reset")
        #expect(try toggle(.context, in: h.page).isOn)

        let outline = try toggle(.outline, in: h.page)
        outline.isOn = true
        outline.sendActions(for: .valueChanged)
        var written = AppPreferences.ChatTopBar.layout(in: defaults)
        #expect(written.shown == [.outline, .context])
        #expect(written.order == ChatTopBarAction.allCases, "a switch must not move its row")

        // What the list calls when a drag on a handle drops the row.
        let dataSource = try #require(h.page.dataSource)
        let from = try #require(h.page.indexPath(for: .action(.terminal)))
        let to = try #require(h.page.indexPath(for: .action(.files)))
        dataSource.collectionView(h.page.collectionView, moveItemAt: from, to: to)
        written = AppPreferences.ChatTopBar.layout(in: defaults)
        #expect(written.order == [.terminal, .files, .git, .outline, .context])
        #expect(written.shown == [.outline, .context], "a drag must not change which buttons are on")

        #expect(await waitForMainActorCondition {
            h.page.updatePropertiesIfNeeded()
            return h.page.shownItems.contains(.reset)
        }, "a customized bar offers Reset to Default")
        let resetPath = try #require(h.page.indexPath(for: .reset))
        h.page.view.layoutIfNeeded()
        let resetCell = try #require(h.page.collectionView.cellForItem(at: resetPath))
        let reset = try #require(Self.buttons(in: resetCell).first { $0.accessibilityIdentifier == "settings.chat.topBar.reset" })
        reset.sendActions(for: .touchUpInside)
        #expect(AppPreferences.ChatTopBar.layout(in: defaults) == .defaultValue)
        #expect(defaults.stringArray(forKey: AppPreferences.ChatTopBar.orderKey) == nil, "Reset forgets the saved layout")
        #expect(await waitForMainActorCondition {
            h.page.updatePropertiesIfNeeded()
            return !h.page.shownItems.contains(.reset) && h.page.shownItems.first == .action(.files)
        }, "the page reads the default back")
    }
}
