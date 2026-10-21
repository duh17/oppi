import Foundation
import Testing
@testable import Oppi

/// The chat top bar's buttons: which ones the bar shows, the order they and the
/// … menu read in, and what happens when one cannot be offered right now.
@Suite("Chat top bar layout")
struct ChatTopBarLayoutTests {
    private let everything = Set(ChatTopBarAction.allCases)

    @Test func theDefaultBarShowsFilesOutlineAndContext() {
        let layout = ChatTopBarLayout.defaultValue
        #expect(layout.order == [.files, .outline, .context, .terminal])
        #expect(layout.bar(available: everything) == [.files, .outline, .context])
        // Terminal is the one … menu item: it needs the SSH Terminal experiment.
        #expect(layout.menu(available: everything) == [.terminal])
        #expect(layout.storedOrder == ["files", "outline", "context", "terminal"])
        #expect(layout.storedShown == ["files", "outline", "context"])
    }

    @Test func everyButtonCanBeHiddenAndShownAgain() {
        let all = ChatTopBarLayout.defaultValue.setting(.terminal, shown: true)
        #expect(all.bar(available: everything) == [.files, .outline, .context, .terminal])
        #expect(all.menu(available: everything) == [])

        // Hiding one button moves it to the menu and leaves the bar's order.
        let withoutOutline = all.setting(.outline, shown: false)
        #expect(withoutOutline.bar(available: everything) == [.files, .context, .terminal])
        #expect(withoutOutline.menu(available: everything) == [.outline])
        // Its place in the order survives, so showing it again restores the bar.
        #expect(withoutOutline.setting(.outline, shown: true) == all)

        let none = all.setting(.files, shown: false)
            .setting(.outline, shown: false)
            .setting(.context, shown: false)
            .setting(.terminal, shown: false)
        #expect(none.bar(available: everything) == [])
        #expect(none.menu(available: everything) == [.files, .outline, .context, .terminal])
        #expect(none.storedShown == [])
    }

    @Test func theOrderCarriesIntoTheBarAndTheMenu() {
        let layout = ChatTopBarLayout(
            order: [.terminal, .files, .outline, .context],
            shown: [.files, .outline, .context]
        )
        #expect(layout.bar(available: everything) == [.files, .outline, .context])
        #expect(layout.menu(available: everything) == [.terminal])

        // What the Top Bar page writes after a drag is a stored order, and the
        // bar and the menu both read it.
        let dragged = ChatTopBarLayout(order: [.terminal, .files, .outline, .context], shown: layout.shown)
        #expect(dragged.order == [.terminal, .files, .outline, .context])
        #expect(dragged.bar(available: everything) == [.files, .outline, .context])
        #expect(dragged.menu(available: everything) == [.terminal])
    }

    @Test func anActionTheChatCannotOfferLeavesTheBarShortRatherThanBorrowing() {
        // A chat with no workspace has no files and no folder to open a terminal
        // in; its ring and its outline timeline are still there.
        let allShown = ChatTopBarLayout(
            order: ChatTopBarAction.allCases,
            shown: Set(ChatTopBarAction.allCases)
        )
        let available: Set<ChatTopBarAction> = [.outline, .context]
        #expect(allShown.bar(available: available) == [.outline, .context])
        // Nothing refills the empty places, and the menu never offers a button
        // that could only fail: Files and Terminal are simply absent.
        #expect(allShown.menu(available: available) == [])
        // The stored layout is untouched, so the bar fills again in its places.
        #expect(allShown.bar(available: everything) == [.files, .outline, .context, .terminal])
    }

    @Test func aHiddenActionStaysOutOfTheMenuWhileItCannotBeOffered() {
        // Terminal hidden and the experiment off: not in the bar, not in the
        // menu, and back in the menu at its own place when the experiment
        // returns.
        let layout = ChatTopBarLayout.defaultValue
        let withoutTerminal: Set<ChatTopBarAction> = [.files, .outline, .context]
        #expect(layout.menu(available: withoutTerminal) == [])
        #expect(layout.menu(available: everything) == [.terminal])
    }

    @Test func theLayoutIsStoredOnThisDeviceAndAnnouncesOneChange() {
        let defaults = UserDefaults(suiteName: "ChatTopBarLayoutTests.\(UUID().uuidString)")!
        let layout = ChatTopBarLayout(
            order: [.terminal, .outline, .context, .files],
            shown: [.terminal, .outline]
        )
        var announcements = 0
        let observer = NotificationCenter.default.addObserver(
            forName: AppPreferences.ChatTopBar.didChangeNotification, object: nil, queue: nil
        ) { _ in announcements += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(AppPreferences.ChatTopBar.layout(in: defaults) == .defaultValue)
        AppPreferences.ChatTopBar.setLayout(layout, in: defaults)
        #expect(AppPreferences.ChatTopBar.layout(in: defaults) == layout)
        #expect(defaults.stringArray(forKey: AppPreferences.ChatTopBar.orderKey) == ["terminal", "outline", "context", "files"])
        #expect(defaults.stringArray(forKey: AppPreferences.ChatTopBar.shownKey) == ["terminal", "outline"])
        #expect(announcements == 1)

        // Writing the same layout again announces nothing.
        AppPreferences.ChatTopBar.setLayout(layout, in: defaults)
        #expect(announcements == 1)

        // Hidden everything is a stored empty list, not a missing value, so it
        // reads back as the choice and not as the default bar.
        let none = layout.setting(.terminal, shown: false).setting(.outline, shown: false)
        AppPreferences.ChatTopBar.setLayout(none, in: defaults)
        #expect(AppPreferences.ChatTopBar.layout(in: defaults) == none)
        #expect(defaults.stringArray(forKey: AppPreferences.ChatTopBar.shownKey) == [])
        #expect(announcements == 2)
    }

    @Test func aStoredLayoutMissingOrRepeatingAnActionStillCoversEveryActionOnce() {
        // Half a store, or an action the app no longer knows: decode what is
        // known and append the rest in the default order.
        #expect(ChatTopBarLayout(storedOrder: ["outline"], storedShown: []).order == [.outline, .files, .context, .terminal])
        #expect(ChatTopBarLayout(storedOrder: ["notAnAction"], storedShown: []).order == [.files, .outline, .context, .terminal])
        #expect(
            ChatTopBarLayout(storedOrder: ["context", "context", "files"], storedShown: [])
                .order == [.context, .files, .outline, .terminal]
        )
        #expect(ChatTopBarLayout(storedOrder: [], storedShown: ["notAnAction"]).shown == [])
    }

    @Test func everyButtonKeepsItsStableIdentity() {
        #expect(ChatTopBarAction.files.accessibilityIdentifier == "chat.toolbar.files")
        #expect(ChatTopBarAction.outline.accessibilityIdentifier == "chat.toolbar.outline")
        #expect(ChatTopBarAction.context.accessibilityIdentifier == "chat.toolbar.context")
        #expect(ChatTopBarAction.terminal.accessibilityIdentifier == "chat.toolbar.terminal")
        #expect(Set(ChatTopBarAction.allCases.map(\.accessibilityIdentifier)).count == 4)
        #expect(Set(ChatTopBarAction.allCases.map(\.menuIdentifier)).count == 4)
        #expect(ChatTopBarAction.context.menuIdentifier == "chat.toolbar.menu.context")
        // The Files menu item names the state it would change.
        #expect(ChatTopBarAction.files.menuTitle(filesOpen: false) == "Open Files")
        #expect(ChatTopBarAction.files.menuTitle(filesOpen: true) == "Close Files")
        #expect(ChatTopBarAction.context.menuTitle(filesOpen: true) == "Context")
    }
}
