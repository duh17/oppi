import Foundation
import Testing
@testable import Oppi

/// The chat top bar's buttons: which ones the bar shows, the order they and the
/// overflow menu read in, and what happens when one cannot be offered right now.
@Suite("Chat top bar layout")
struct ChatTopBarLayoutTests {
    private let everything = Set(ChatTopBarAction.allCases)
    private let allShown = ChatTopBarLayout(order: ChatTopBarAction.allCases, shown: Set(ChatTopBarAction.allCases))

    @Test func theDefaultBarShowsOnlyTheContextRing() {
        let layout = ChatTopBarLayout.defaultValue
        #expect(layout.order == [.files, .git, .outline, .context, .terminal])
        #expect(layout.bar(available: everything) == [.context])
        // Everything else is in the menu, in the order a pinned button takes.
        #expect(layout.menu(available: everything) == [.files, .git, .outline, .terminal])
        #expect(layout.storedOrder == ["files", "git", "outline", "context", "terminal"])
        #expect(layout.storedShown == ["context"])
        #expect(layout.isDefault)
        // Pinning Files puts it before the ring, where the order has it, and the
        // bar is no longer the default one.
        let pinned = layout.setting(.files, shown: true)
        #expect(pinned.bar(available: everything) == [.files, .context])
        #expect(!pinned.isDefault)
    }

    /// Nothing saved reads as the new default; a saved layout keeps exactly its
    /// buttons, including the old default bar someone saved by using the Top
    /// Bar page before the default changed.
    @Test func aSavedLayoutKeepsItsButtonsWhileAnUnsavedOneGetsTheNewDefault() {
        let defaults = UserDefaults(suiteName: "ChatTopBarLayoutTests.\(UUID().uuidString)")!
        #expect(AppPreferences.ChatTopBar.layout(in: defaults).bar(available: everything) == [.context])

        defaults.set(["files", "git", "outline", "context", "terminal"], forKey: AppPreferences.ChatTopBar.orderKey)
        defaults.set(["files", "git", "outline", "context"], forKey: AppPreferences.ChatTopBar.shownKey)
        let saved = AppPreferences.ChatTopBar.layout(in: defaults)
        #expect(saved.bar(available: everything) == [.files, .git, .outline, .context])
        #expect(saved.menu(available: everything) == [.terminal])
        #expect(!saved.isDefault)
    }

    /// Someone who saved a layout before Git existed keeps the bar they chose;
    /// Git joins the end of their order, hidden, so the menu offers it.
    @Test func aLayoutSavedBeforeGitKeepsItsBarAndOffersGitInTheMenu() {
        let saved = ChatTopBarLayout(
            storedOrder: ["terminal", "files", "outline", "context"],
            storedShown: ["terminal", "files"]
        )
        #expect(saved.order == [.terminal, .files, .outline, .context, .git])
        #expect(saved.bar(available: everything) == [.terminal, .files])
        #expect(saved.menu(available: everything) == [.outline, .context, .git])
        #expect(!saved.isShown(.git))
    }

    @Test func everyButtonCanBeHiddenAndShownAgain() {
        #expect(allShown.bar(available: everything) == [.files, .git, .outline, .context, .terminal])
        #expect(allShown.menu(available: everything) == [])

        // Hiding one button moves it to the menu and leaves the bar's order.
        let withoutOutline = allShown.setting(.outline, shown: false)
        #expect(withoutOutline.bar(available: everything) == [.files, .git, .context, .terminal])
        #expect(withoutOutline.menu(available: everything) == [.outline])
        // Its place in the order survives, so showing it again restores the bar.
        #expect(withoutOutline.setting(.outline, shown: true) == allShown)

        let none = allShown.setting(.files, shown: false)
            .setting(.git, shown: false)
            .setting(.outline, shown: false)
            .setting(.context, shown: false)
            .setting(.terminal, shown: false)
        #expect(none.bar(available: everything) == [])
        #expect(none.menu(available: everything) == [.files, .git, .outline, .context, .terminal])
        #expect(none.storedShown == [])
    }

    @Test func theOrderCarriesIntoTheBarAndTheMenu() {
        let layout = ChatTopBarLayout(
            order: [.terminal, .git, .files, .outline, .context],
            shown: [.files, .outline, .context]
        )
        #expect(layout.bar(available: everything) == [.files, .outline, .context])
        #expect(layout.menu(available: everything) == [.terminal, .git])

        // What the Top Bar page writes after a drag is a stored order, and the
        // bar and the menu both read it.
        let dragged = ChatTopBarLayout(order: [.outline, .terminal, .git, .files, .context], shown: layout.shown)
        #expect(dragged.order == [.outline, .terminal, .git, .files, .context])
        #expect(dragged.bar(available: everything) == [.outline, .files, .context])
        #expect(dragged.menu(available: everything) == [.terminal, .git])
    }

    @MainActor @Test func anActionTheChatCannotOfferLeavesTheBarShortRatherThanBorrowing() {
        // A chat with no workspace has no files, no Git, and no folder to open a
        // terminal in; its ring and its outline timeline are still there.
        let available = ChatBarItems.availableActions(
            hasWorkspace: false, gitAvailable: true, showsOutline: true, hasTerminalFolder: true
        )
        #expect(available == [.outline, .context])
        #expect(allShown.bar(available: available) == [.outline, .context])
        // Nothing refills the empty places, and the menu never offers a button
        // that could only fail: Files, Git, and Terminal are simply absent.
        #expect(allShown.menu(available: available) == [])
        // The stored layout is untouched, so the bar fills again in its places.
        #expect(allShown.bar(available: everything) == [.files, .git, .outline, .context, .terminal])
    }

    /// Git is offered in a workspace that may be a repository, and not where
    /// it could only fail: Git status turned off, or a loaded status that says
    /// the folder is no repository. Files stays either way.
    @MainActor @Test func gitIsOfferedOnlyWhereTheWorkspaceMayBeARepository() {
        let repo = GitStatus(
            isGitRepo: true, branch: "main", headSha: "abc1234",
            ahead: 0, behind: 0, dirtyCount: 0, untrackedCount: 0, stagedCount: 0,
            files: [], totalFiles: 0, addedLines: 0, removedLines: 0,
            stashCount: 0, lastCommitMessage: nil, lastCommitDate: nil, recentCommits: []
        )
        var notARepo = repo
        notARepo.isGitRepo = false
        // Not loaded yet: offered, so the button does not appear late.
        #expect(ChatBarItems.mayOfferGit(gitStatusEnabled: nil, loadedStatus: nil))
        #expect(ChatBarItems.mayOfferGit(gitStatusEnabled: true, loadedStatus: repo))
        #expect(!ChatBarItems.mayOfferGit(gitStatusEnabled: true, loadedStatus: notARepo))
        #expect(!ChatBarItems.mayOfferGit(gitStatusEnabled: false, loadedStatus: nil))
        #expect(!ChatBarItems.mayOfferGit(gitStatusEnabled: false, loadedStatus: repo))

        let withGit = ChatBarItems.availableActions(
            hasWorkspace: true, gitAvailable: true, showsOutline: false, hasTerminalFolder: false
        )
        #expect(withGit == [.files, .git, .context])
        let withoutGit = ChatBarItems.availableActions(
            hasWorkspace: true, gitAvailable: false, showsOutline: false, hasTerminalFolder: false
        )
        #expect(withoutGit == [.files, .context])
    }

    /// A menu item keeps its details on the label's line, after it, so the
    /// icon stays beside the label; Git's details are short enough not to
    /// wrap on an iPhone and leave out what is zero.
    @MainActor @Test func aMenuItemCarriesItsGlanceAfterTheLabel() {
        #expect(ChatBarItems.menuTitle("Context", detail: "0.8%") == "Context  0.8%")
        #expect(ChatBarItems.menuTitle("Outline", detail: nil) == "Outline")
        #expect(
            ChatBarItems.gitMenuDetail(changedFiles: 3, added: 12, removed: 4, ahead: 2, behind: 1)
                == "+12 \u{2212}4  \u{2191}2 \u{2193}1"
        )
        #expect(ChatBarItems.gitMenuDetail(changedFiles: 0, added: 0, removed: 0, ahead: 2, behind: 0) == "\u{2191}2")
        #expect(ChatBarItems.gitMenuDetail(changedFiles: 1, added: 0, removed: 5, ahead: nil, behind: nil) == "\u{2212}5")
        // Changes without line counts (new binary files) still say how many.
        #expect(ChatBarItems.gitMenuDetail(changedFiles: 2, added: 0, removed: 0, ahead: nil, behind: 3) == "2 changed  \u{2193}3")
        // A clean branch even with its upstream has nothing to add.
        #expect(ChatBarItems.gitMenuDetail(changedFiles: 0, added: 0, removed: 0, ahead: 0, behind: nil) == nil)
    }

    @Test func aHiddenActionStaysOutOfTheMenuWhileItCannotBeOffered() {
        // Terminal hidden and no folder a shell can start in: not in the bar,
        // not in the menu, and back in the menu at its own place when the chat
        // has a usable folder again.
        let layout = ChatTopBarLayout.defaultValue
        let withoutTerminal: Set<ChatTopBarAction> = [.files, .git, .outline, .context]
        #expect(layout.menu(available: withoutTerminal) == [.files, .git, .outline])
        #expect(layout.menu(available: everything) == [.files, .git, .outline, .terminal])
    }

    @Test func theLayoutIsStoredOnThisDeviceAndAnnouncesOneChange() {
        let defaults = UserDefaults(suiteName: "ChatTopBarLayoutTests.\(UUID().uuidString)")!
        let layout = ChatTopBarLayout(
            order: [.terminal, .outline, .context, .git, .files],
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
        #expect(defaults.stringArray(forKey: AppPreferences.ChatTopBar.orderKey) == ["terminal", "outline", "context", "git", "files"])
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
        #expect(
            ChatTopBarLayout(storedOrder: ["outline"], storedShown: []).order
                == [.outline, .files, .git, .context, .terminal]
        )
        #expect(
            ChatTopBarLayout(storedOrder: ["notAnAction"], storedShown: []).order
                == [.files, .git, .outline, .context, .terminal]
        )
        #expect(
            ChatTopBarLayout(storedOrder: ["context", "context", "files"], storedShown: [])
                .order == [.context, .files, .git, .outline, .terminal]
        )
        #expect(ChatTopBarLayout(storedOrder: [], storedShown: ["notAnAction"]).shown == [])
    }

    @Test func everyButtonKeepsItsStableIdentity() {
        #expect(ChatTopBarAction.files.accessibilityIdentifier == "chat.toolbar.files")
        #expect(ChatTopBarAction.git.accessibilityIdentifier == "chat.toolbar.git")
        #expect(ChatTopBarAction.outline.accessibilityIdentifier == "chat.toolbar.outline")
        #expect(ChatTopBarAction.context.accessibilityIdentifier == "chat.toolbar.context")
        #expect(ChatTopBarAction.terminal.accessibilityIdentifier == "chat.toolbar.terminal")
        #expect(Set(ChatTopBarAction.allCases.map(\.accessibilityIdentifier)).count == ChatTopBarAction.allCases.count)
        #expect(Set(ChatTopBarAction.allCases.map(\.menuIdentifier)).count == ChatTopBarAction.allCases.count)
        #expect(ChatTopBarAction.context.menuIdentifier == "chat.toolbar.menu.context")
        #expect(ChatTopBarAction.git.menuIdentifier == "chat.toolbar.menu.git")
        // The Files menu item names the state it would change.
        #expect(ChatTopBarAction.files.menuTitle(filesOpen: false) == "Open Files")
        #expect(ChatTopBarAction.files.menuTitle(filesOpen: true) == "Close Files")
        #expect(ChatTopBarAction.context.menuTitle(filesOpen: true) == "Context")
    }
}
