import SwiftUI
import Testing
@testable import Oppi

@Suite("Chat file browser panel")
struct ChatFileBrowserPanelTests {
    @Test func tabStoreDefaultsToChangedWhenSessionHasNoPreference() {
        let fixture = makeDefaults()
        defer { fixture.cleanup() }
        let store = ChatFileBrowserPanelTabStore(defaults: fixture.defaults)

        #expect(store.tab(for: "session-1") == .changed)
    }

    @Test func tabStoreRemembersSelectionPerSession() {
        let fixture = makeDefaults()
        defer { fixture.cleanup() }
        let store = ChatFileBrowserPanelTabStore(defaults: fixture.defaults)

        store.setTab(.all, for: "session-1")
        store.setTab(.changed, for: "session-2")

        #expect(store.tab(for: "session-1") == .all)
        #expect(store.tab(for: "session-2") == .changed)
    }

    @Test func tabStoreFallsBackToChangedForMissingOrInvalidSessionIds() {
        let fixture = makeDefaults()
        defer { fixture.cleanup() }
        let store = ChatFileBrowserPanelTabStore(defaults: fixture.defaults)

        store.setTab(.all, for: "   ")

        #expect(store.tab(for: "") == .changed)
        #expect(store.tab(for: "   ") == .changed)
    }

    @Test func layoutUsesSideRailForWideChatAndBottomPanelForNarrowChat() {
        #expect(ChatFileBrowserPanelLayout.style(for: CGSize(width: 900, height: 700)) == .sideRail)
        #expect(ChatFileBrowserPanelLayout.style(for: CGSize(width: 390, height: 844)) == .bottomPanel)
    }

    @Test func layoutSizesStayWithinComfortableBounds() {
        let regularWidth = ChatFileBrowserPanelLayout.sideRailWidth(for: CGSize(width: 1_100, height: 800))
        let largeWidth = ChatFileBrowserPanelLayout.sideRailWidth(for: CGSize(width: 2_000, height: 1_000))
        let phoneHeight = ChatFileBrowserPanelLayout.bottomPanelHeight(for: CGSize(width: 390, height: 844))
        let tallHeight = ChatFileBrowserPanelLayout.bottomPanelHeight(for: CGSize(width: 800, height: 1_300))

        #expect(regularWidth >= 320 && regularWidth <= 460)
        #expect(largeWidth == 460)
        #expect(phoneHeight >= 260 && phoneHeight <= 360)
        #expect(tallHeight == 460)
    }

    private struct DefaultsFixture {
        let suiteName: String
        let defaults: UserDefaults

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeDefaults() -> DefaultsFixture {
        let suiteName = "ChatFileBrowserPanelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return DefaultsFixture(suiteName: suiteName, defaults: defaults)
    }
}
