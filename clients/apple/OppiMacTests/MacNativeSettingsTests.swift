import AppKit
import SwiftUI
import Testing
@testable import Oppi

@Suite("Mac native settings routing", .serialized)
@MainActor
struct MacNativeSettingsRoutingTests {
    @Test func sidebarAppSettingsKeepsHostToolsInTheMainWindow() {
        #expect(MacSidebarSection.settings.title == "App Settings")
        #expect(MacSettingsPane.hostToolPanes.contains(.pairing))
        #expect(MacSettingsPane.hostToolPanes.contains(.doctor))
        #expect(MacSettingsPane.hostToolPanes.contains(.localServer))
        #expect(!MacSettingsPane.hostToolPanes.contains(.app))
    }

    @Test func hostToolRevealStillOpensMainWindowPanes() {
        for pane in MacSettingsPane.hostToolPanes {
            let revealed = MacHostToolReveal.selection(for: pane)
            #expect(revealed.section == .settings)
            #expect(revealed.pane == pane)
        }
    }

    @Test func generalPaneIsASettingsLinkNotASecondPreferencesForm() {
        let labels = MacViewHost.accessibilityLabels(
            in: MacAppSettingsNativePreferencesPane()
        )
        #expect(labels.contains(where: { $0.contains("App preferences are in Settings") }))
        #expect(!labels.contains(where: { $0.contains("npm install -g oppi-server@latest") }))
        #expect(!labels.contains("Assistant Avatar"))
    }

    @Test func reopenedPreferencesReadTheSameThemeStoreAndPersistedValues() {
        withIsolatedThemeDefaults {
            let snapshot = captureFontDefaults()
            defer { restoreFontDefaults(snapshot) }

            FontPreferenceStore.setCodeFont(.jetBrainsMono)
            FontPreferenceStore.setUseMonoForMessages(true)

            let themeStore = ThemeStore(
                initialSystemColorScheme: .dark,
                systemColorSchemeProvider: { _ in .dark }
            )
            themeStore.mode = .manual
            themeStore.manualThemeID = .night

            let firstID = themeStore.activeThemeID
            let firstMode = themeStore.mode
            let reopened = ThemeStore(
                initialSystemColorScheme: .dark,
                systemColorSchemeProvider: { _ in .dark }
            )

            #expect(reopened.mode == firstMode)
            #expect(reopened.manualThemeID == firstID)
            #expect(reopened.activeThemeID == firstID)
            #expect(FontPreferenceStore.codeFont == .jetBrainsMono)
            #expect(FontPreferenceStore.useMonoForMessages)
            #expect(themeStore.activeThemeID == reopened.activeThemeID)
        }
    }

    @Test func testHostSettingsMenuUsesCommandComma() throws {
        let settingsItem = try #require(
            MacAppMenuInspection.settingsItem(in: NSApp.mainMenu),
            "TEST_HOST App menu is missing Settings…"
        )
        #expect(MacAppMenuInspection.normalizedTitle(settingsItem.title).hasPrefix("Settings"))
        #expect(settingsItem.keyEquivalent == ",")
        #expect(settingsItem.keyEquivalentModifierMask.contains(.command))
    }

    @Test func openingSettingsViaAppMenuShowsOnePreferenceFormAndLeavesPreexistingWindows() throws {
        for window in NSApp.windows where window.title.localizedCaseInsensitiveContains("settings") {
            window.close()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let existing = Set(NSApp.windows.map { ObjectIdentifier($0) })
        let settingsItem = try #require(
            MacAppMenuInspection.settingsItem(in: NSApp.mainMenu),
            "TEST_HOST App menu is missing Settings…"
        )
        #expect(settingsItem.keyEquivalent == ",")
        #expect(settingsItem.keyEquivalentModifierMask.contains(.command))

        if let action = settingsItem.action {
            _ = NSApp.sendAction(action, to: settingsItem.target, from: settingsItem)
        } else {
            _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }

        var settingsWindow: NSWindow?
        let deadline = Date().addingTimeInterval(1)
        while settingsWindow == nil, Date() < deadline {
            settingsWindow = NSApp.windows.first { window in
                window.isVisible && MacViewHost.accessibilityLabels(in: window).contains(where: {
                    $0.contains("npm install -g oppi-server@latest")
                })
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let window = try #require(
            settingsWindow,
            "Settings scene did not present AppSettingsView. Titles: \(NSApp.windows.map(\.title))"
        )

        let labels = MacViewHost.accessibilityLabels(in: window)
        #expect(labels.contains(where: { $0.contains("npm install -g oppi-server@latest") }))
        #expect(!labels.contains(where: { $0.contains("App preferences are in Settings") }))
        #expect(!labels.contains("Pairing"))
        #expect(!labels.contains("Doctor"))

        let remainingExisting = NSApp.windows.filter { existing.contains(ObjectIdentifier($0)) }
        #expect(remainingExisting.count == existing.count)

        NSApp.mainMenu?.update()
        let send = try #require(
            MacAppMenuInspection.item(titled: MacSessionCommandKind.send.menuTitle, in: NSApp.mainMenu)
        )
        #expect(!send.isEnabled)

        window.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        #expect(NSApp.windows.filter { existing.contains(ObjectIdentifier($0)) }.count == existing.count)
    }
}

enum MacViewHost {
    @MainActor
    static func accessibilityLabels<Content: View>(
        in root: Content,
        size: NSSize = NSSize(width: 480, height: 360)
    ) -> [String] {
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return Array(Set(collectLabels(from: host))).sorted()
    }

    @MainActor
    static func accessibilityLabels(in window: NSWindow) -> [String] {
        guard let content = window.contentView else { return [] }
        return Array(Set(collectLabels(from: content))).sorted()
    }

    @MainActor
    private static func collectLabels(from view: NSView) -> [String] {
        var labels: [String] = []
        let candidates = [
            view.accessibilityLabel(),
            view.accessibilityTitle(),
            (view as? NSButton)?.title,
            (view as? NSTextField)?.stringValue,
        ]
        for candidate in candidates {
            if let candidate, !candidate.isEmpty {
                labels.append(candidate)
            }
        }
        for subview in view.subviews {
            labels.append(contentsOf: collectLabels(from: subview))
        }
        return labels
    }
}

private struct FontDefaultsSnapshot {
    let codeFont: Any?
    let relativeScale: Any?
    let storedEffectiveScale: Any?
    let storedSizePreset: Any?
    let messageScale: Any?
    let monoMessages: Any?
}

private func captureFontDefaults() -> FontDefaultsSnapshot {
    FontDefaultsSnapshot(
        codeFont: UserDefaults.standard.object(forKey: FontPreferenceStore.codeFontKey),
        relativeScale: UserDefaults.standard.object(forKey: FontPreferenceStore.codeTextScaleKey),
        storedEffectiveScale: UserDefaults.standard.object(
            forKey: FontPreferenceStore.storedEffectiveCodeTextScaleKey
        ),
        storedSizePreset: UserDefaults.standard.object(forKey: FontPreferenceStore.codeFontSizePresetKey),
        messageScale: UserDefaults.standard.object(forKey: FontPreferenceStore.messageTextScaleKey),
        monoMessages: UserDefaults.standard.object(forKey: FontPreferenceStore.monoMessagesKey)
    )
}

private func restoreFontDefaults(_ snapshot: FontDefaultsSnapshot) {
    restoreObject(snapshot.codeFont, forKey: FontPreferenceStore.codeFontKey)
    restoreObject(snapshot.relativeScale, forKey: FontPreferenceStore.codeTextScaleKey)
    restoreObject(snapshot.storedEffectiveScale, forKey: FontPreferenceStore.storedEffectiveCodeTextScaleKey)
    restoreObject(snapshot.storedSizePreset, forKey: FontPreferenceStore.codeFontSizePresetKey)
    restoreObject(snapshot.messageScale, forKey: FontPreferenceStore.messageTextScaleKey)
    restoreObject(snapshot.monoMessages, forKey: FontPreferenceStore.monoMessagesKey)
}

private func restoreObject(_ value: Any?, forKey key: String) {
    if let value {
        UserDefaults.standard.set(value, forKey: key)
    } else {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

@MainActor
private func withIsolatedThemeDefaults(_ body: () -> Void) {
    let originalThemeID = ThemeRuntimeState.currentThemeID()
    let keys = [
        ThemeID.storageKey,
        "\(AppIdentifiers.subsystem).theme.mode",
        "\(AppIdentifiers.subsystem).theme.light.id",
        "\(AppIdentifiers.subsystem).theme.dark.id",
    ]
    let originals = Dictionary(uniqueKeysWithValues: keys.map {
        ($0, UserDefaults.standard.object(forKey: $0))
    })
    for key in keys {
        UserDefaults.standard.removeObject(forKey: key)
    }
    defer {
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
            if let value = originals[key], let value {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        ThemeRuntimeState.setThemeID(originalThemeID)
    }
    body()
}
