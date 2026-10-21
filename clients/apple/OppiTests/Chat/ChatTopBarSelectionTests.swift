import Foundation
import Testing
@testable import Oppi

/// The chat top bar's two quick action slots: the stored choice, the slot an
/// action lands in, and what happens when one cannot be offered right now.
@Suite("Chat top bar actions")
struct ChatTopBarSelectionTests {
    private let everything: Set<ChatTopBarAction> = [.files, .terminal, .outline]

    @Test func theDefaultBarIsFilesAndOutline() {
        #expect(ChatTopBarSelection.defaultValue.actions == [.files, .outline])
        // A missing or unreadable stored value falls back to the default, so
        // nobody who never chose sees a different bar.
        #expect(ChatTopBarSelection(rawValues: []).actions == [.files, .outline])
        #expect(ChatTopBarSelection(rawValues: ["notAnAction"]).actions == [.files, .outline])
        #expect(ChatTopBarSelection(rawValues: ["files"]).actions == [.files, .outline])
    }

    @Test func theStoredChoiceIsExactlyTwoDifferentActions() {
        #expect(ChatTopBarSelection(actions: [.terminal, .files]).actions == [.terminal, .files])
        // A store that cannot name two actions falls back to the default pair.
        #expect(ChatTopBarSelection(actions: [.terminal, .terminal]).actions == [.files, .outline])
        #expect(ChatTopBarSelection(actions: [.files, .terminal, .outline]).actions == [.files, .terminal])
        #expect(ChatTopBarSelection(rawValues: ["outline", "terminal"]).rawValues == ["outline", "terminal"])
    }

    @Test func terminalKeepsItsChosenSlotOnlyWhileTheExperimentIsOn() {
        let chosen = ChatTopBarSelection(actions: [.terminal, .files])
        #expect(chosen.slots(available: everything) == [.terminal, .files])
        #expect(chosen.overflow(available: everything) == [.outline])
        // SSH Terminal off: Terminal disappears and the third action fills the
        // slot. The ring stays; nothing else about the bar changes.
        let withoutTerminal: Set<ChatTopBarAction> = [.files, .outline]
        #expect(chosen.slots(available: withoutTerminal) == [.files, .outline])
        #expect(chosen.overflow(available: withoutTerminal) == [])
    }

    @Test func anActionTheChatCannotOfferGivesItsSlotAway() {
        // A chat with no workspace has no files and no folder to open a
        // terminal in; its timeline still has an outline.
        let selection = ChatTopBarSelection(actions: [.files, .terminal])
        #expect(selection.slots(available: [.outline]) == [.outline])
        #expect(selection.overflow(available: [.outline]) == [])
        // The stored choice is untouched: the bar fills again on a workspace chat.
        #expect(selection.actions == [.files, .terminal])
    }

    @Test func theMenuHoldsTheActionWithoutASlot() {
        #expect(ChatTopBarSelection.defaultValue.slots(available: everything) == [.files, .outline])
        #expect(ChatTopBarSelection.defaultValue.overflow(available: everything) == [.terminal])
        let terminalFirst = ChatTopBarSelection(actions: [.terminal, .outline])
        #expect(terminalFirst.slots(available: everything) == [.terminal, .outline])
        #expect(terminalFirst.overflow(available: everything) == [.files])
    }

    @Test func choosingTakesTheOtherSlotsActionRatherThanDuplicatingIt() {
        let selection = ChatTopBarSelection.defaultValue
        #expect(selection.choosing(.terminal, forSlot: 0).actions == [.terminal, .outline])
        // Picking the action already in the other slot swaps them.
        #expect(selection.choosing(.outline, forSlot: 0).actions == [.outline, .files])
        #expect(selection.choosing(.files, forSlot: 1).actions == [.outline, .files])
        // Picking what is already there changes nothing.
        #expect(selection.choosing(.files, forSlot: 0) == selection)
    }

    @Test func theChoiceIsStoredOnThisDeviceAndAnnouncesOneChange() {
        let defaults = UserDefaults(suiteName: "ChatTopBarSelectionTests.\(UUID().uuidString)")!
        let selection = ChatTopBarSelection(actions: [.terminal, .outline])
        var announcements = 0
        let observer = NotificationCenter.default.addObserver(
            forName: AppPreferences.ChatTopBar.didChangeNotification, object: nil, queue: nil
        ) { _ in announcements += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(AppPreferences.ChatTopBar.selection(in: defaults) == .defaultValue)
        AppPreferences.ChatTopBar.setSelection(selection, in: defaults)
        #expect(AppPreferences.ChatTopBar.selection(in: defaults) == selection)
        #expect(defaults.stringArray(forKey: AppPreferences.ChatTopBar.actionsKey) == ["terminal", "outline"])
        #expect(announcements == 1)

        // Writing the same value again announces nothing.
        AppPreferences.ChatTopBar.setSelection(selection, in: defaults)
        #expect(announcements == 1)
    }

    @Test func everyActionKeepsItsStableIdentityAndSymbol() {
        #expect(ChatTopBarAction.files.accessibilityIdentifier == "chat.toolbar.files")
        #expect(ChatTopBarAction.outline.accessibilityIdentifier == "chat.toolbar.outline")
        #expect(ChatTopBarAction.terminal.accessibilityIdentifier == "chat.toolbar.terminal")
        #expect(Set(ChatTopBarAction.allCases.map(\.accessibilityIdentifier)).count == 3)
        #expect(ChatTopBarAction.files.symbolName == "folder")
        #expect(ChatTopBarAction.files.openSymbolName == "folder.fill")
        #expect(ChatTopBarAction.terminal.openSymbolName == nil)
        // Every action says what it does, not just its name.
        for action in ChatTopBarAction.allCases {
            #expect(!action.accessibilityLabel.isEmpty)
            #expect(!action.label.isEmpty)
        }
    }
}
