import Foundation
import GhosttyVt
import Testing
import UIKit
@testable import Oppi

private let everyOverview = Set(SSHTerminalBarAction.overviews)

private func offer(
    context: SSHTerminalBarContext = .plain,
    overviews: Set<SSHTerminalBarAction> = everyOverview,
    openTerminals: Int = 2,
    canBrowseFiles: Bool = true,
    program: String = "shell",
    customKeys: [SSHTerminalCustomKey] = [],
    shortcuts: [SSHTerminalKeyAction] = []
) -> SSHTerminalBarOffer {
    SSHTerminalBarOffer(
        context: context, overviews: overviews, openTerminals: openTerminals, canBrowseFiles: canBrowseFiles,
        program: program, customKeys: customKeys, shortcuts: shortcuts
    )
}

private func actions(of slots: [SSHTerminalBarSlot]) -> [SSHTerminalBarAction] {
    slots.compactMap { if case .action(let action) = $0.content { action } else { nil } }
}

private func isolatedDefaults() -> UserDefaults {
    let name = "SSHTerminalBottomBarTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("SSH terminal bottom bar layout")
struct SSHTerminalBarPlacementTests {
    @Test func theDefaultBarIsTodaysPlusTypeInTerminalAndChatBarInOnePill() {
        let placement = offer().placement(layout: .defaultValue, capacity: 8)
        #expect(actions(of: placement.slots) == [.keyboard, .chatBar, .herdr, .rex, .switcher])
        // Turned-off keys and Paste stay out of the menu; Browse Files Here,
        // which the menu always had, stays in it. Program Shortcuts is off and
        // not offered there either.
        #expect(actions(of: placement.menu) == [.browseFiles])
    }

    @Test func buttonsThatDoNotFitMoveIntoTheMenuInOrderButPasteNever() {
        let layout = SSHTerminalBarLayout(
            order: [.action(.escape), .action(.paste), .action(.keyboard), .action(.interrupt), .action(.chatBar)],
            shown: [.action(.escape), .action(.paste), .action(.keyboard), .action(.interrupt), .action(.chatBar), .action(.switcher)]
        )
        let placement = offer().placement(layout: layout, capacity: 2)
        #expect(actions(of: placement.slots) == [.escape, .paste])
        // A shown key with no room is offered; a hidden one is not.
        #expect(actions(of: placement.menu) == [.keyboard, .interrupt, .chatBar, .browseFiles, .herdr, .rex, .switcher])

        let none = offer().placement(layout: layout, capacity: 0)
        #expect(none.slots.isEmpty)
        #expect(!actions(of: none.menu).contains(.paste))
    }

    @Test func anActionTheTerminalCannotOfferIsNeitherDrawnNorInTheMenu() {
        let placement = offer(overviews: [], openTerminals: 1, canBrowseFiles: false)
            .placement(layout: .defaultValue, capacity: 8)
        #expect(actions(of: placement.slots) == [.keyboard, .chatBar])
        #expect(placement.menu.isEmpty)
    }

    @Test func aRexPaneOffersOnlyRexAndAHerdrTerminalOnlyHerdr() {
        func placement(
            _ layout: SSHTerminalBarLayout = .defaultValue, in context: SSHTerminalBarContext
        ) -> SSHTerminalBarPlacement {
            offer(context: context).placement(layout: layout, capacity: 8)
        }
        #expect(actions(of: placement(in: .rex).slots) == [.keyboard, .chatBar, .rex, .switcher])
        #expect(actions(of: placement(in: .herdr).slots) == [.keyboard, .chatBar, .herdr, .switcher])
        // A plain shell on a host with both keeps both.
        #expect(actions(of: placement(in: .plain).slots) == [.keyboard, .chatBar, .herdr, .rex, .switcher])

        // The … menu follows: a multiplexer turned off in the layout is offered
        // there only where its terminal can use it.
        let hiddenBoth = SSHTerminalBarLayout.defaultValue
            .setting(.action(.herdr), shown: false).setting(.action(.rex), shown: false)
        #expect(actions(of: placement(hiddenBoth, in: .rex).menu) == [.browseFiles, .rex])
        #expect(actions(of: placement(hiddenBoth, in: .herdr).menu) == [.browseFiles, .herdr])
        #expect(actions(of: placement(hiddenBoth, in: .plain).menu) == [.browseFiles, .herdr, .rex])
    }

    @Test func theContextComesFromTheTerminalsOwnProgram() {
        #expect(SSHTerminalBarContext(isRexPane: true, command: nil) == .rex)
        #expect(SSHTerminalBarContext(isRexPane: true, command: "herdr") == .rex)
        #expect(SSHTerminalBarContext(isRexPane: false, command: "herdr") == .herdr)
        #expect(SSHTerminalBarContext(isRexPane: false, command: "/Users/me/.local/bin/herdr --attach") == .herdr)
        // Login shells, other multiplexers, and other programs are plain.
        for command in [nil, "", "tmux new -A -s main", "fish", "sh -c 'cd /tmp && herdr'"] {
            #expect(SSHTerminalBarContext(isRexPane: false, command: command) == .plain, "\(command ?? "nil")")
        }
    }

    @Test func reorderingTheShownRowsKeepsTheHiddenOnesPlaceAndChoice() {
        let saved = SSHTerminalBarLayout(
            order: [.action(.keyboard), .action(.herdr), .action(.switcher), .action(.rex), .action(.chatBar)],
            shown: [.action(.keyboard), .action(.herdr), .action(.switcher)]
        )
        // A Rex terminal's page lists Rex and the switcher; the person drags Rex first.
        let moved = saved.reordering([.action(.rex), .action(.switcher)])
        #expect(Array(moved.order.prefix(5)) == [.action(.keyboard), .action(.herdr), .action(.rex), .action(.switcher), .action(.chatBar)])
        #expect(moved.shown == saved.shown)
        #expect(moved.reordering([.action(.switcher), .action(.rex)]) == saved)
    }
}

@Suite("SSH terminal bottom bar fit")
struct SSHTerminalBarFitTests {
    private let iPhone = UIEdgeInsets.zero
    private let landscape = UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)

    @MainActor
    @Test func theOnePillGetsWholeItemsOfTheRoomBetweenBackAndTheTrailingEnd() {
        // iPhone portrait, 393 pt: 12 + Back 36 + 8 on the left and 12 at the
        // edge leave 325 pt, 7 items; … takes one, and the status symbol another.
        #expect(SSHTerminalBottomBar.roomWidth(width: 393, safeInsets: iPhone, rexPanesShown: false) == 325)
        #expect(SSHTerminalBottomBar.capacity(width: 393, safeInsets: iPhone, rexPanesShown: false, fixedItems: 1) == 6)
        #expect(SSHTerminalBottomBar.capacity(width: 393, safeInsets: iPhone, rexPanesShown: false, fixedItems: 2) == 5)
        // The pane switcher's pill and its gap come out of the room.
        let withPanes = SSHTerminalBottomBar.roomWidth(width: 393, safeInsets: iPhone, rexPanesShown: true)
        let expected: CGFloat = 325 - 44 - 8
        #expect(withPanes == expected, "room with the pane switcher: \(withPanes)")
        #expect(SSHTerminalBottomBar.capacity(width: 393, safeInsets: iPhone, rexPanesShown: true, fixedItems: 1) == 5)
        // Landscape safe-area insets take their share.
        #expect(SSHTerminalBottomBar.capacity(width: 852, safeInsets: landscape, rexPanesShown: false, fixedItems: 1) == 14)
        #expect(SSHTerminalBottomBar.capacity(width: 100, safeInsets: iPhone, rexPanesShown: false, fixedItems: 1) == 0)
    }

    @MainActor
    @Test func thePillIsCenteredOnTheScreenAndMovesOnlyWhenItWouldComeCloserThanTheGapToItsNeighbours() {
        let width: CGFloat = 390
        let back = SSHTerminalGlassPill.height + SSHTerminalBottomBar.sideInset
        func clamp(_ pill: CGFloat, rex: Bool) -> CGFloat {
            SSHTerminalBottomBar.pillMinX(pillWidth: pill, viewWidth: width, safeInsets: iPhone, rexPanesShown: rex)
        }
        // Few buttons: centered on the screen, both edges well inside the room.
        #expect(clamp(176, rex: false) == (width - 176) / 2)
        #expect(clamp(176, rex: true) == (width - 176) / 2)
        // Crowded: 7 items fill the room to Back's gap on the left (centered would be 41 pt, 15 pt over Back).
        let full: CGFloat = 7 * 44
        #expect(clamp(full, rex: false) == back + SSHTerminalBottomBar.pillGap)
        // Crowded with the pane switcher's pill: 6 items shift left of center, to its gap.
        let withPanes: CGFloat = 6 * 44
        let shifted = clamp(withPanes, rex: true)
        #expect(shifted < (width - withPanes) / 2)
        #expect(shifted + withPanes == width - SSHTerminalBottomBar.sideInset - SSHTerminalGlassPill.itemWidth - SSHTerminalBottomBar.pillGap)
    }

    @MainActor
    @Test func aPillThatFitsTheCapacityNeverOverlapsBackOrThePaneSwitcherAtAnyWidth() {
        for width in stride(from: CGFloat(320), through: 1032, by: 17) {
            for insets in [iPhone, landscape] {
                for rex in [false, true] {
                    let capacity = SSHTerminalBottomBar.capacity(width: width, safeInsets: insets, rexPanesShown: rex, fixedItems: 1)
                    let pill = CGFloat(capacity + 1) * SSHTerminalGlassPill.itemWidth
                    let minX = SSHTerminalBottomBar.pillMinX(pillWidth: pill, viewWidth: width, safeInsets: insets, rexPanesShown: rex)
                    let backEdge = insets.left + SSHTerminalBottomBar.sideInset + SSHTerminalGlassPill.height
                    let trailing = width - insets.right - SSHTerminalBottomBar.sideInset
                        - (rex ? SSHTerminalGlassPill.itemWidth + SSHTerminalBottomBar.pillGap : 0)
                    #expect(minX >= backEdge + SSHTerminalBottomBar.pillGap, "width \(width), insets \(insets.left), rex \(rex)")
                    #expect(minX + pill <= trailing, "width \(width), insets \(insets.left), rex \(rex)")
                    // And it stays centered whenever centered fits.
                    let centered = (width - pill) / 2
                    if centered >= backEdge + SSHTerminalBottomBar.pillGap, centered + pill <= trailing {
                        #expect(minX == centered, "width \(width), insets \(insets.left), rex \(rex)")
                    }
                }
            }
        }
    }

    /// Whatever fits is a prefix of the shown buttons, whatever overflows is
    /// the rest in order, and the pill that results is never wider than the
    /// room it is centred in.
    @MainActor
    @Test func overflowTakesTheLastButtonsAndTheDrawnOnesFitTheRoom() {
        let all = SSHTerminalBarAction.allCases.map(SSHTerminalBarItem.action)
        let layout = SSHTerminalBarLayout(order: all, shown: Set(all))
        for rexPanesShown in [false, true] {
            let capacity = SSHTerminalBottomBar.capacity(width: 393, safeInsets: .zero, rexPanesShown: rexPanesShown, fixedItems: 2)
            let placement = offer(openTerminals: 2).placement(layout: layout, capacity: capacity)
            #expect(placement.slots.count == capacity)
            #expect(actions(of: placement.slots) == Array(SSHTerminalBarAction.allCases.prefix(capacity)))
            let overflow = SSHTerminalBarAction.allCases.dropFirst(capacity).filter { $0 != .paste }
            #expect(actions(of: placement.menu) == Array(overflow))
            let pillWidth = CGFloat(placement.slots.count + 2) * SSHTerminalGlassPill.itemWidth
            #expect(pillWidth <= SSHTerminalBottomBar.roomWidth(width: 393, safeInsets: .zero, rexPanesShown: rexPanesShown))
        }
    }
}

@Suite("SSH terminal bottom bar saved layout")
struct SSHTerminalBarMigrationTests {
    /// The old bar stored one order over both pills, reordered within each
    /// section, and a set of what was shown.
    @Test func anOldTwoSectionLayoutBecomesOneOrderAndKeepsWhatWasShown() {
        let legacyOrder = ["herdr", "keyboard", "switcher", "interrupt", "chatBar", "rex", "tab", "escape", "up", "down", "enter", "paste", "browseFiles"]
        let legacyShown = ["keyboard", "interrupt", "herdr", "switcher"]
        let migrated = SSHTerminalBarLayout.migrating(legacyOrder: legacyOrder, legacyShown: legacyShown)
        // The middle's buttons in their order, then the ones that sat beside … in theirs.
        #expect(Array(migrated.storedOrder.prefix(13)) == [
            "keyboard", "interrupt", "chatBar", "tab", "escape", "up", "down", "enter", "paste", "browseFiles",
            "herdr", "switcher", "rex",
        ])
        #expect(migrated.shown == Set(legacyShown.compactMap(SSHTerminalBarItem.init(rawValue:))))
        // Program Shortcuts arrived after the layout was saved: in the order, not shown.
        #expect(migrated.order.contains(.programShortcuts))
        #expect(!migrated.isShown(.programShortcuts))
    }

    @Test func theStoreReadsALegacyLayoutAndWritesTheNewOneInItsPlace() {
        let defaults = isolatedDefaults()
        let prefix = AppIdentifiers.subsystem
        defaults.set(["rex", "keyboard", "chatBar"], forKey: "\(prefix).sshTerminal.barOrder")
        defaults.set(["keyboard", "rex"], forKey: "\(prefix).sshTerminal.barShown")
        let store = SSHTerminalBarStore(defaults: defaults)
        #expect(Array(store.layout.order.prefix(3)) == [.action(.keyboard), .action(.chatBar), .action(.rex)])
        #expect(store.layout.shown == [.action(.keyboard), .action(.rex)])

        // A change writes the new keys and retires the old ones.
        store.setLayout(store.layout.setting(.action(.chatBar), shown: true))
        #expect(defaults.stringArray(forKey: "\(prefix).sshTerminal.barOrder") == nil)
        #expect(SSHTerminalBarStore(defaults: defaults).layout.shown == [.action(.keyboard), .action(.rex), .action(.chatBar)])
    }

    @Test func aFreshInstallHasTheDefaultBarAndResetBringsItBack() {
        let defaults = isolatedDefaults()
        let store = SSHTerminalBarStore(defaults: defaults)
        #expect(store.layout == .defaultValue)
        store.setLayout(store.layout.setting(.action(.paste), shown: true))
        #expect(store.layout != store.defaultLayout)
        store.reset()
        #expect(store.layout == .defaultValue)
    }

    @Test func customKeysAndTheirPlaceSurviveAReload() {
        let defaults = isolatedDefaults()
        let store = SSHTerminalBarStore(defaults: defaults)
        let eof = SSHTerminalCustomKey(name: "EOF", control: true, key: "d")
        let next = SSHTerminalCustomKey(name: "Next tab", option: true, shift: true, key: "right", showFor: .agent("claude"))
        store.save(eof)
        store.save(next)
        // New keys go last and are on.
        #expect(Array(store.layout.order.suffix(2)) == [.customKey(eof.id), .customKey(next.id)])
        #expect(store.layout.isShown(.customKey(eof.id)))
        // The person moves one up front and turns the other off.
        store.setLayout(store.layout
            .reordering([.customKey(next.id), .customKey(eof.id)])
            .setting(.customKey(eof.id), shown: false))

        let reloaded = SSHTerminalBarStore(defaults: defaults)
        #expect(reloaded.customKeys == [eof, next])
        #expect(Array(reloaded.layout.order.suffix(2)) == [.customKey(next.id), .customKey(eof.id)])
        #expect(reloaded.layout.isShown(.customKey(next.id)))
        #expect(!reloaded.layout.isShown(.customKey(eof.id)))

        // Editing keeps the key's id and place; deleting drops it from the list.
        var renamed = eof
        renamed.name = "Quit"
        reloaded.save(renamed)
        #expect(reloaded.customKeys.map(\.name) == ["Quit", "Next tab"])
        #expect(Array(reloaded.layout.order.suffix(2)) == [.customKey(next.id), .customKey(eof.id)])
        reloaded.delete(eof.id)
        #expect(reloaded.customKeys == [next])
        #expect(!reloaded.layout.order.contains(.customKey(eof.id)))
        // Reset keeps the person's own keys.
        reloaded.reset()
        #expect(reloaded.layout.order.contains(.customKey(next.id)))
    }
}

@Suite("SSH terminal custom keys")
@MainActor
struct SSHTerminalCustomKeyTests {
    /// What the terminal writes for the key, as the channel's `keys` does.
    private func bytes(_ key: SSHTerminalCustomKey, engine: SSHTerminalEngine) -> Data {
        key.strokes.reduce(into: Data()) { bytes, stroke in
            bytes.append(engine.key(stroke.key, text: stroke.text, modifiers: stroke.modifiers))
        }
    }

    private func key(_ spec: String) -> SSHTerminalCustomKey {
        var key = SSHTerminalCustomKey()
        let parts = spec.split(separator: "+").map(String.init)
        key.control = parts.contains("ctrl")
        key.option = parts.contains("alt")
        key.shift = parts.contains("shift")
        key.key = parts.last ?? ""
        return key
    }

    @Test func aKeyEncodesLikeTheKeyboardBarsKeys() throws {
        let engine = try SSHTerminalEngine { _ in }
        #expect(bytes(key("ctrl+d"), engine: engine) == Data([0x04]))
        #expect(bytes(key("ctrl+c"), engine: engine) == Data([0x03]))
        #expect(bytes(key("x"), engine: engine) == Data("x".utf8))
        #expect(bytes(key("shift+d"), engine: engine) == Data("D".utf8))
        #expect(bytes(key("alt+enter"), engine: engine) == Data("\u{1b}\r".utf8))
        #expect(bytes(key("escape"), engine: engine) == Data([0x1b]))
        #expect(bytes(key("tab"), engine: engine) == Data("\t".utf8))
        #expect(bytes(key("f1"), engine: engine) == Data("\u{1b}OP".utf8))
        #expect(bytes(key("f5"), engine: engine) == Data("\u{1b}[15~".utf8))
        #expect(bytes(key("f12"), engine: engine) == Data("\u{1b}[24~".utf8))
        #expect(bytes(key("ctrl+f5"), engine: engine) == Data("\u{1b}[15;5~".utf8))
        #expect(bytes(key("pageup"), engine: engine) == Data("\u{1b}[5~".utf8))
        #expect(bytes(key("ctrl+-"), engine: engine) == bytes(key("ctrl+minus"), engine: engine))
    }

    @Test func theKittyKeyboardProtocolChangesTheEncodingTheWayItDoesForOtherKeys() throws {
        let engine = try SSHTerminalEngine { _ in }
        // pi, Claude Code, and Codex ask for it.
        engine.receive(Data("\u{1b}[>1u".utf8))
        #expect(bytes(key("ctrl+d"), engine: engine) == Data("\u{1b}[100;5u".utf8))
        #expect(bytes(key("alt+enter"), engine: engine) == Data("\u{1b}[13;3u".utf8))
        // The strokes are the keymap's own, so they encode as the program's bindings do.
        let ctrlD = try #require(SSHTerminalKeymap.parse("ctrl+d", syntax: .plus))
        #expect(key("ctrl+d").strokes == ctrlD)
    }

    @Test func theCapAndChordNameTheKeyTheWayABarButtonShowsIt() {
        #expect(SSHTerminalCustomKey(name: "EOF", control: true, key: "d").chord == "\u{2303}D")
        // A short name is the cap; a long one falls back to the combination.
        #expect(SSHTerminalCustomKey(name: "EOF", control: true, key: "d").cap == "EOF")
        #expect(SSHTerminalCustomKey(name: "Next window", control: true, key: "d").cap == "\u{2303}D")
        #expect(SSHTerminalCustomKey(control: true, option: true, shift: true, key: "f5").chord == "\u{2303}\u{2325}\u{21E7}F5")
        // Unnamed, the button is spoken as its combination.
        #expect(SSHTerminalCustomKey(control: true, key: "d").displayName == "\u{2303}D")
        #expect(SSHTerminalCustomKey(name: "  Quit \n", key: "q").displayName == "Quit")
    }

    @Test func onlyAKeyTheTerminalCanSendIsValid() {
        #expect(SSHTerminalCustomKey(key: "d").isValid)
        #expect(SSHTerminalCustomKey(key: "7").isValid)
        #expect(SSHTerminalCustomKey(key: "/").isValid)
        for named in SSHTerminalCustomKey.NamedKey.all {
            #expect(SSHTerminalCustomKey(key: named.key).isValid, "\(named.title)")
        }
        #expect(SSHTerminalCustomKey.NamedKey.all.count == 13 + 12)
        for invalid in ["", "!", "é", "ab", " ", "f13"] {
            #expect(!SSHTerminalCustomKey(key: invalid).isValid, "\(invalid.debugDescription)")
        }
    }

    @Test func aKeySurvivesTheJSONTheStoreWritesAndAnUnsendableOneIsDropped() {
        let store = SSHTerminalBarStore(defaults: isolatedDefaults())
        let keys = [
            SSHTerminalCustomKey(name: "EOF", control: true, key: "d"),
            SSHTerminalCustomKey(name: "Plan", shift: true, key: "tab", showFor: .agent("claude")),
            SSHTerminalCustomKey(name: "Clear", control: true, key: "l", showFor: .shell),
        ]
        keys.forEach(store.save)
        #expect(store.customKeys == keys)
        store.save(SSHTerminalCustomKey(name: "Broken", key: "ab"))
        #expect(store.customKeys == keys, "a key that cannot be sent is not offered")
    }
}

@Suite("SSH terminal bar: what the terminal offers")
struct SSHTerminalBarOfferTests {
    private let eof = SSHTerminalCustomKey(name: "EOF", control: true, key: "d", showFor: .all)
    private let shellOnly = SSHTerminalCustomKey(name: "Clear", control: true, key: "l", showFor: .shell)
    private let piOnly = SSHTerminalCustomKey(name: "Tree", option: true, key: "t", showFor: .agent("pi"))
    private let claudeOnly = SSHTerminalCustomKey(name: "Plan", shift: true, key: "tab", showFor: .agent("claude"))

    private var everyKey: [SSHTerminalCustomKey] { [eof, shellOnly, piOnly, claudeOnly] }

    private func shown(_ keys: [SSHTerminalCustomKey]) -> SSHTerminalBarLayout {
        keys.reduce(SSHTerminalBarLayout.defaultValue) { $0.adding(.customKey($1.id), shown: true) }
    }

    private func names(program: String) -> [String] {
        offer(program: program, customKeys: everyKey)
            .placement(layout: shown(everyKey), capacity: 20).slots
            .compactMap { if case .customKey(let key) = $0.content { key.name } else { nil } }
    }

    @Test func aCustomKeyShowsOnlyForTheProgramItNames() {
        #expect(names(program: "shell") == ["EOF", "Clear"])
        #expect(names(program: "pi") == ["EOF", "Tree"])
        #expect(names(program: "claude") == ["EOF", "Plan"])
        // An agent with no key of its own gets only the ones for every program.
        #expect(names(program: "codex") == ["EOF"])
    }

    @Test func theProgramComesFromTheKeyStripsOwnDetection() {
        // Herdr, and a program that does not report, are the shell.
        #expect(SSHTerminalAgentDetection.keymapProgram(root: nil, app: "") == "shell")
        // A reported agent, with a suffix, is that agent.
        #expect(SSHTerminalAgentDetection.agentName("claude-code") == "claude")
        #expect(SSHTerminalCustomKey.ShowFor.agent("claude").matches(program: "claude"))
        #expect(!SSHTerminalCustomKey.ShowFor.shell.matches(program: "claude"))
        #expect(!SSHTerminalCustomKey.ShowFor.agent("claude").matches(program: "shell"))
        // Every agent the key strips know is a choice, after All programs and Shell.
        let choices = SSHTerminalCustomKey.ShowFor.choices
        #expect(Array(choices.prefix(2)) == [.all, .shell])
        #expect(Set(choices.dropFirst(2)) == Set(SSHTerminalAgentDetection.agentApps.map { .agent($0) }))
        #expect(Array(choices.dropFirst(2).prefix(3)).map(\.title) == ["pi", "Claude Code", "Codex"])
    }

    @Test func aKeyForAnotherProgramIsNeitherDrawnNorInTheMenuEvenWhenTurnedOff() {
        let layout = shown([piOnly]).setting(.customKey(piOnly.id), shown: false)
        let inShell = offer(program: "shell", customKeys: [piOnly]).placement(layout: layout, capacity: 20)
        #expect(!inShell.menu.contains { $0.item == .customKey(piOnly.id) })
        // In pi, the same key turned off is offered in the menu: nothing else has it.
        let inPi = offer(program: "pi", customKeys: [piOnly]).placement(layout: layout, capacity: 20)
        #expect(inPi.menu.contains { $0.item == .customKey(piOnly.id) })
        #expect(!inPi.slots.contains { $0.item == .customKey(piOnly.id) })
    }

    @Test func customKeysFollowTheListsOrderAmongTheBuiltInButtons() {
        let layout = SSHTerminalBarLayout(
            order: [.customKey(eof.id), .action(.keyboard), .action(.chatBar)],
            shown: [.customKey(eof.id), .action(.keyboard), .action(.chatBar)]
        )
        let placement = offer(customKeys: [eof]).placement(layout: layout, capacity: 20)
        #expect(placement.slots.map(\.item) == [.customKey(eof.id), .action(.keyboard), .action(.chatBar)])
    }

    @Test func aKeyThatDoesNotFitGoesToTheMenuAndIsStillSent() throws {
        let placement = offer(customKeys: [eof]).placement(layout: shown([eof]), capacity: 2)
        #expect(placement.slots.map(\.item) == [.action(.keyboard), .action(.chatBar)])
        let overflowed = try #require(placement.menu.first { $0.item == .customKey(eof.id) })
        #expect(overflowed.strokes == eof.strokes)
        #expect(overflowed.title == "EOF")
    }

    @Test func programShortcutsAreTheProgramsActionsAndFollowItsKeybindingFile() throws {
        let pi = try #require(SSHTerminalKeymap.profile(for: "pi"))
        let defaults = SSHTerminalKeymap.actions(for: pi, userFile: nil)
        let layout = SSHTerminalBarLayout.defaultValue.setting(.programShortcuts, shown: true)
        let plain = offer(program: "pi", shortcuts: defaults).placement(layout: layout, capacity: 20)
        let shortcuts = plain.slots.filter { $0.item == .programShortcuts }
        #expect(shortcuts.map(\.title) == ["Thinking", "Model", "Tools"])
        #expect(shortcuts.map(\.keyCap) == ["\u{21E7}Tab", "^L", "^O"])

        // The user's own keybinding file, read by the same loader, rebinds Model.
        let overridden = SSHTerminalKeymap.actions(for: pi, userFile: #"{"app.model.select":"ctrl+k"}"#)
        let rebound = offer(program: "pi", shortcuts: overridden).placement(layout: layout, capacity: 20)
        let model = try #require(rebound.slots.first { $0.title == "Model" })
        #expect(model.keyCap == "^K")
        #expect(model.strokes == SSHTerminalKeymap.parse("ctrl+k", syntax: .plus))
        // Unbinding an action removes its button.
        let unbound = SSHTerminalKeymap.actions(for: pi, userFile: #"{"app.model.select":[]}"#)
        let without = offer(program: "pi", shortcuts: unbound).placement(layout: layout, capacity: 20)
        #expect(without.slots.filter { $0.item == .programShortcuts }.map(\.title) == ["Thinking", "Tools"])
    }

    @Test func programShortcutsAreInlineCapsThatOverflowOneAtATimeAndStayOutOfTheMenuWhenOff() throws {
        let claude = try #require(SSHTerminalKeymap.profile(for: "claude"))
        let actions = SSHTerminalKeymap.actions(for: claude, userFile: nil)
        #expect(actions.count == 5)
        let layout = SSHTerminalBarLayout.defaultValue.setting(.programShortcuts, shown: true)
        // Room for the two input buttons and three of Claude Code's five shortcuts.
        let crowded = offer(program: "claude", shortcuts: actions).placement(layout: layout, capacity: 5)
        #expect(crowded.slots.filter { $0.item == .programShortcuts }.count == 3)
        // The two that did not fit are in the menu, with the buttons that were never drawn.
        let overflow = crowded.menu.filter { $0.item == .programShortcuts }
        #expect(overflow.map(\.title) == actions.suffix(2).map(\.title))
        // Off, they are not in the menu: the key strips have them.
        let off = offer(program: "claude", shortcuts: actions).placement(layout: .defaultValue, capacity: 20)
        #expect(!(off.slots + off.menu).contains { $0.item == .programShortcuts })
    }

    @Test func aProgramWithNoShortcutsOffersNoProgramShortcutsRow() {
        let layout = SSHTerminalBarLayout.defaultValue.setting(.programShortcuts, shown: true)
        let none = offer(program: "opencode", shortcuts: []).placement(layout: layout, capacity: 20)
        #expect(!(none.slots + none.menu).contains { $0.item == .programShortcuts })
        #expect(!offer(program: "opencode", shortcuts: []).items.contains(.programShortcuts))
    }
}
