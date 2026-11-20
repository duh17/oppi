import Foundation
import Testing
import UIKit
@testable import Oppi

/// Settings > Panes over the real page and a store on a suite of its own, and
/// the Settings index that lists it only where panes split.
@Suite("Settings Panes page", .serialized)
@MainActor
struct SettingsPanesPageTests {
    /// One side per kind, a terminal Below and the rest Automatic until
    /// changed, and a choice saves only that kind's side.
    @Test func listsASidePerKindAndSavesAChoice() async throws {
        let defaults = try makeSettingsDefaults()
        let page = SettingsPanesViewController(
            settings: SettingsStore(serverId: nil, device: DeviceAdapter(defaults: defaults), server: ServerAdapter { _ in nil })
        )
        let window = try Self.show(page, wide: true)
        defer { window.isHidden = true; window.rootViewController = nil }

        let kinds = PlatformCapabilities.godotPane ? 5 : 4
        var shown: [String: UIButton] = [:]
        for _ in 0..<50 where shown.count < kinds {
            page.view.layoutIfNeeded()
            shown = Self.buttons(in: page.view, prefix: "settings.panes.")
            if shown.count < kinds { try? await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(shown.count == kinds, "\(shown.keys.sorted())")
        let terminal = try #require(shown["settings.panes.terminal"])
        #expect(terminal.accessibilityValue == "Below")
        #expect(shown["settings.panes.files"]?.accessibilityValue == "Automatic")

        try KitMenuRow.choose("Right", in: terminal)
        for _ in 0..<50 where AppPreferenceStore.NewPanes.side(for: .terminal, in: defaults) != .right {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(AppPreferenceStore.NewPanes.side(for: .terminal, in: defaults) == .right)
        #expect(AppPreferenceStore.NewPanes.side(for: .files, in: defaults) == .automatic, "one kind at a time")
    }

    /// A compact window (iPhone, a narrow iPad window) never places a pane,
    /// so the index lists Panes only on a wide one.
    @Test func settingsListsPanesOnAWideWindowOnly() async throws {
        func listsPanes(wide: Bool) async throws -> Bool {
            let screen = SettingsRootViewController(root: makeTestAppRoot())
            let window = try Self.show(screen, wide: wide)
            defer { window.isHidden = true; window.rootViewController = nil }
            // The row after Panes is always listed, so once it draws the index is complete.
            for _ in 0..<50 {
                screen.view.layoutIfNeeded()
                let rows = Self.buttons(in: screen.view, prefix: "settings.row.")
                if rows["settings.row.voice"] != nil { return rows["settings.row.panes"] != nil }
                try? await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("the index never drew Voice & Dictation")
            return false
        }
        #expect(try await listsPanes(wide: true))
        #expect(try await !listsPanes(wide: false))
    }

    private static func show(_ page: UIViewController, wide: Bool) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: wide ? 1133 : 390, height: 1400)
        window.traitOverrides.horizontalSizeClass = wide ? .regular : .compact
        window.rootViewController = page
        window.makeKeyAndVisible()
        return window
    }

    /// Visible buttons whose identifier starts with `prefix`, by identifier:
    /// a collection view keeps removed cells hidden in its reuse pool.
    private static func buttons(in view: UIView, prefix: String) -> [String: UIButton] {
        func visible(_ view: UIView) -> [UIButton] {
            guard !view.isHidden else { return [] }
            return (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(visible)
        }
        return Dictionary(
            visible(view).compactMap { button in button.accessibilityIdentifier.flatMap { $0.hasPrefix(prefix) ? ($0, button) : nil } },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
