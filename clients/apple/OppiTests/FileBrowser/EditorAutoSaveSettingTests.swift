import Foundation
import Testing
import UIKit
@testable import Oppi

/// Auto-Save is one editor setting: the editor's "…" menu, Settings > Editor's
/// declared row, and the edit session's write gate read and write the same
/// device value, and it is off until a person turns it on.
@Suite("Editor Auto-Save setting", .serialized)
@MainActor
struct EditorAutoSaveSettingTests {
    private struct Harness {
        var page: SettingsEditorViewController
        var defaults: UserDefaults
        var preferences: CodeEditorPreferences
        var written: Written
        var window: UIWindow
    }

    private final class Written {
        var ids: [String] = []
    }

    private typealias Item = SettingsEditorViewController.Item

    /// The real Settings > Editor page, on a suite of its own, with the editor
    /// preference the "…" menu uses pointed at the same defaults.
    private func makeHarness() throws -> Harness {
        let defaults = makeSettingsDefaults()
        let preferences = CodeEditorPreferences(defaults: defaults)
        let written = Written()
        let store = SettingsStore(
            serverId: nil,
            device: DeviceAdapter(defaults: defaults),
            server: ServerAdapter { _ in nil },
            afterWrite: { written.ids.append($0) }
        )
        let page = SettingsEditorViewController(preferences: preferences, settings: store)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        window.rootViewController = page
        window.makeKeyAndVisible()
        return Harness(page: page, defaults: defaults, preferences: preferences, written: written, window: window)
    }

    private func hide(_ harness: Harness) {
        harness.window.isHidden = true
        harness.window.rootViewController = nil
    }

    /// Presents the page again: an appearance, which is when the page re-reads
    /// the rows it draws.
    private func show(_ harness: Harness) {
        harness.window.rootViewController = harness.page
        harness.window.makeKeyAndVisible()
        harness.page.view.setNeedsLayout()
        harness.page.view.layoutIfNeeded()
    }

    private func cell(_ item: Item, in page: SettingsEditorViewController) -> UICollectionViewCell? {
        page.view.layoutIfNeeded()
        return page.indexPath(for: item).flatMap { page.collectionView.cellForItem(at: $0) }
    }

    private static func switches(in view: UIView) -> [UISwitch] {
        let own = (view as? UISwitch).map { [$0] } ?? []
        return own + view.subviews.flatMap(switches)
    }

    /// The editor's "…" menu, built as the editor builds it.
    private func optionsMenu(_ preferences: CodeEditorPreferences) -> [UIAction] {
        WorkspaceFileEditorOptions.elements(preferences, wrapKind: .text)
            .flatMap { element -> [UIMenuElement] in
                guard let menu = element as? UIMenu else { return [element] }
                return menu.children
            }
            .compactMap { $0 as? UIAction }
    }

    private func autoSaveToggle(_ preferences: CodeEditorPreferences) -> UIAction? {
        optionsMenu(preferences).first { $0.title == String(localized: "Auto-Save") }
    }

    // MARK: The one value

    @Test("Auto-Save is off until a person turns it on")
    func offByDefault() {
        let preferences = CodeEditorPreferences(defaults: makeSettingsDefaults())
        #expect(preferences.autoSaves == false, "nothing stored means off")
        #expect(SettingsCatalog.autoSave.default == false)
        #expect(SettingsCatalog.autoSave.key == AppPreferenceStore.Editor.autoSaveKey)
        #expect(SettingsCatalog.autoSave.id == "settings.editor.autoSave")
    }

    @Test("Settings > Editor's row writes the value the editor's menu shows")
    func theRowWritesTheEditorsSetting() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        #expect(await waitForMainActorCondition { cell(.autoSave, in: h.page) != nil })
        let drawn = Self.switches(in: try #require(cell(.autoSave, in: h.page)))
        #expect(drawn.count == 1)
        let toggle = try #require(drawn.first)
        #expect(toggle.accessibilityIdentifier == "settings.editor.autoSave")
        #expect(toggle.isOn == false, "the row starts off, like the preference")
        #expect(autoSaveToggle(h.preferences)?.state == .off)

        toggle.isOn = true
        toggle.sendActions(for: .valueChanged)

        #expect(h.written.ids == [SettingsCatalog.autoSave.id], "the row writes through the store")
        #expect(h.preferences.autoSaves, "the editor's menu reads the same setting")
        #expect(await waitForMainActorCondition { autoSaveToggle(h.preferences)?.state == .on })
    }

    /// The menu and Settings > Editor are never on screen together (Settings is
    /// its own presentation), and the page re-reads its rows when it appears. So
    /// the contract is: the menu's write is what Settings > Editor shows the next
    /// time it appears.
    @Test("The editor's menu writes the value Settings > Editor shows when it appears")
    func theMenuWritesTheSettingsRow() async throws {
        let h = try makeHarness()
        defer { hide(h) }
        #expect(await waitForMainActorCondition { cell(.autoSave, in: h.page) != nil })
        #expect(Self.switches(in: cell(.autoSave, in: h.page) ?? UIView()).first?.isOn == false, "it starts off")

        // The editor's "…" menu writes while the page is away.
        hide(h)
        try #require(autoSaveToggle(h.preferences)).performWithSender(nil, target: nil)
        #expect(h.preferences.autoSaves, "the menu turned Auto-Save on")
        #expect(
            h.defaults.object(forKey: AppPreferenceStore.Editor.autoSaveKey) as? Bool == true,
            "the menu stores the declared key, not a second one"
        )

        // Appearing again, the page shows what the menu wrote.
        show(h)
        #expect(await waitForMainActorCondition {
            Self.switches(in: cell(.autoSave, in: h.page) ?? UIView()).first?.isOn == true
        }, "the row shows what the menu wrote")

        // And the menu toggles both ways, so the page shows that too.
        hide(h)
        try #require(autoSaveToggle(h.preferences)).performWithSender(nil, target: nil)
        #expect(h.preferences.autoSaves == false, "the menu toggles both ways")
        show(h)
        #expect(await waitForMainActorCondition {
            Self.switches(in: cell(.autoSave, in: h.page) ?? UIView()).first?.isOn == false
        }, "the row shows the menu's second write")
    }
}
