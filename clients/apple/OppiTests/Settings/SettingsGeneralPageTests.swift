import Foundation
import Testing
import UIKit
@testable import Oppi

/// Settings > General over the real page and a real `SettingsStore` on a
/// suite of its own: each control writes the setting's `AppPreferences` key
/// through the store, with the ids it always had.
@Suite("Settings General page", .serialized)
@MainActor
struct SettingsGeneralPageTests {
    private struct Harness {
        var page: SettingsGeneralViewController
        var defaults: UserDefaults
        var written: Written
        var window: UIWindow
    }

    private final class Written {
        var ids: [String] = []
    }

    private typealias Item = SettingsGeneralViewController.Item

    private func makeHarness() throws -> Harness {
        let defaults = makeSettingsDefaults()
        let written = Written()
        let store = SettingsStore(
            device: DeviceAdapter(defaults: defaults),
            server: ServerAdapter { _ in nil },
            afterWrite: { written.ids.append($0) }
        )
        let page = SettingsGeneralViewController(root: makeTestAppRoot(settings: store))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        window.rootViewController = page
        window.makeKeyAndVisible()
        return Harness(page: page, defaults: defaults, written: written, window: window)
    }

    private func hide(_ harness: Harness) {
        harness.window.isHidden = true
        harness.window.rootViewController = nil
    }

    private func cell(_ item: Item, in page: SettingsGeneralViewController) -> UICollectionViewCell? {
        page.view.layoutIfNeeded()
        return page.indexPath(for: item).flatMap { page.collectionView.cellForItem(at: $0) }
    }

    private func button(_ item: Item, in page: SettingsGeneralViewController) -> UIButton? {
        cell(item, in: page)?.accessibilityElements?.first as? UIButton
    }

    private static func switches(in view: UIView) -> [UISwitch] {
        let own = (view as? UISwitch).map { [$0] } ?? []
        return own + view.subviews.flatMap(switches)
    }

    private func action(titled title: String, of button: UIButton?) -> UIAction? {
        button?.menu?.children.compactMap { $0 as? UIAction }.first { $0.title == title }
    }

    private func footers(_ page: SettingsGeneralViewController) -> [String] {
        let kind = UICollectionView.elementKindSectionFooter
        return page.collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind)
            .sorted { $0.section < $1.section }
            .compactMap { indexPath in
                let view = page.collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? UICollectionViewListCell
                return (view?.contentConfiguration as? UIListContentConfiguration)?.text
            }
    }

    @Test("The haptics switch is the declared one, and flipping it writes the preference's key")
    func hapticsSwitchWritesThroughTheStore() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        #expect(await waitForMainActorCondition { cell(.haptics, in: h.page) != nil })
        let drawn = Self.switches(in: try #require(cell(.haptics, in: h.page)))
        let toggle = try #require(drawn.first)
        #expect(drawn.count == 1)
        #expect(toggle.accessibilityIdentifier == "settings.general.haptics")
        #expect(toggle.isOn, "haptics default to on")

        toggle.isOn = false
        toggle.sendActions(for: .valueChanged)

        #expect(h.defaults.object(forKey: AppPreferenceStore.Interaction.hapticFeedbackEnabledKey) as? Bool == false)
        #expect(await waitForMainActorCondition { Self.switches(in: cell(.haptics, in: h.page) ?? UIView()).first?.isOn == false })
        #expect(Self.switches(in: try #require(cell(.haptics, in: h.page))).count == 1)
    }

    @Test("Keep Awake After Activity writes its key and runs the store's hook, not a write from the page")
    func keepAwakeWritesAndRunsTheHook() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        #expect(await waitForMainActorCondition { button(.keepAwake, in: h.page) != nil })
        let row = try #require(button(.keepAwake, in: h.page))
        #expect(row.accessibilityIdentifier == "settings.general.keepAwake")
        #expect(row.accessibilityValue == AppPreferenceStore.ScreenAwake.timeoutPresetDefault.label)

        try #require(action(titled: "5 minutes", of: row)).performWithSender(nil, target: nil)

        #expect(h.defaults.object(forKey: AppPreferenceStore.ScreenAwake.timeoutPresetKey) as? Int == 300)
        #expect(h.written.ids == [SettingsCatalog.keepAwakeAfterActivity.id])
        #expect(await waitForMainActorCondition { button(.keepAwake, in: h.page)?.accessibilityValue == "5 minutes" })
    }

    @Test("Open Links writes its key, and its footer describes the chosen browser")
    func openLinksWritesAndTheFooterFollows() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        #expect(await waitForMainActorCondition { button(.openLinks, in: h.page) != nil && footers(h.page).count == 3 })
        #expect(button(.openLinks, in: h.page)?.accessibilityIdentifier == "settings.general.openLinks")
        #expect(footers(h.page)[2] == AppPreferenceStore.Browser.LinkOpeningMode.inApp.detail)

        try #require(action(titled: "External Browser", of: button(.openLinks, in: h.page))).performWithSender(nil, target: nil)

        #expect(h.defaults.string(forKey: AppPreferenceStore.Browser.linkOpeningModeKey) == "external")
        #expect(await waitForMainActorCondition { footers(h.page).last == AppPreferenceStore.Browser.LinkOpeningMode.external.detail })
        // The test's hook sees every stored write; which ones do anything is the live
        // hook's filter (`SettingsLiveHookTests`).
        #expect(h.written.ids == [SettingsCatalog.openLinks.id])
    }
}

/// The app's own after-write hook (`SettingsStore.liveAfterWrite`), on a screen-awake
/// controller of the test's own: Keep Awake After Activity refreshes the idle timer
/// and no other setting does.
@Suite("Settings live hook")
@MainActor
struct SettingsLiveHookTests {
    private func makeController(_ updates: UpdateLog) -> ScreenAwakeController {
        ScreenAwakeController(
            timeoutProvider: { .seconds(2) },
            idleTimerSetter: { updates.values.append($0) },
            sleepFunction: { _ in }
        )
    }

    final class UpdateLog {
        var values: [Bool] = []
    }

    @Test("Keep Awake After Activity refreshes the idle timer")
    func keepAwakeRefreshes() {
        let updates = UpdateLog()
        let hook = SettingsStore.liveAfterWrite(screenAwake: makeController(updates))

        hook(SettingsCatalog.keepAwakeAfterActivity.id)

        #expect(updates.values == [true])
    }

    @Test("Open Links, Haptic Feedback, and Server Metrics do not")
    func otherSettingsDoNot() {
        let updates = UpdateLog()
        let hook = SettingsStore.liveAfterWrite(screenAwake: makeController(updates))

        for setting in [SettingsCatalog.openLinks.id, SettingsCatalog.hapticFeedback.id, SettingsCatalog.serverMetricsEnabled.id] {
            hook(setting)
        }

        #expect(updates.values.isEmpty)
    }
}
