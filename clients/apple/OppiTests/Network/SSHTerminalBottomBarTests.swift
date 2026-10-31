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
        // Rex Sessions is not in a Rex pane's bar at all: the pane switcher's panel holds it.
        #expect(actions(of: placement(in: .rex).slots) == [.keyboard, .chatBar, .switcher])
        #expect(actions(of: placement(in: .herdr).slots) == [.keyboard, .chatBar, .herdr, .switcher])
        // A plain shell on a host with both keeps both.
        #expect(actions(of: placement(in: .plain).slots) == [.keyboard, .chatBar, .herdr, .rex, .switcher])

        // The … menu follows: a multiplexer turned off in the layout is offered
        // there only where its terminal can use it (a Rex pane offers no Rex Sessions).
        let hiddenBoth = SSHTerminalBarLayout.defaultValue
            .setting(.action(.herdr), shown: false).setting(.action(.rex), shown: false)
        #expect(actions(of: placement(hiddenBoth, in: .rex).menu) == [.browseFiles])
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

    @Test func retiringTheOldKeysAnnouncesTheChangeEvenWhenTheNewLayoutIsTheDefault() {
        let defaults = isolatedDefaults()
        let prefix = AppIdentifiers.subsystem
        // A saved bar the old way: not the default.
        defaults.set(["escape", "keyboard"], forKey: "\(prefix).sshTerminal.barOrder")
        defaults.set(["escape"], forKey: "\(prefix).sshTerminal.barShown")
        let store = SSHTerminalBarStore(defaults: defaults)
        #expect(store.layout != .defaultValue)
        final class Counter: @unchecked Sendable { var posts = 0 }
        let counter = Counter()
        let token = NotificationCenter.default.addObserver(forName: SSHTerminalBarStore.didChange, object: nil, queue: nil) { _ in counter.posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        // Saving the default writes nothing new, but the bar now reads the default, not the migrated one.
        store.setLayout(.defaultValue)
        #expect(counter.posts >= 1, "the open terminal must hear that the layout it reads changed")
        #expect(store.layout == .defaultValue)
        #expect(defaults.stringArray(forKey: "\(prefix).sshTerminal.barOrder") == nil)
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

    @Test func oneStoredKeyThatDoesNotDecodeDoesNotTakeTheOthersWithIt() throws {
        let defaults = isolatedDefaults()
        let store = SSHTerminalBarStore(defaults: defaults)
        let kept = SSHTerminalCustomKey(name: "EOF", control: true, key: "d")
        let other = SSHTerminalCustomKey(name: "Clear", control: true, key: "l", showFor: .shell)
        // A damaged entry and one with a field another version added in place of ours, between two good ones.
        var entries = try [kept, other].map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        entries.insert(["id": "not-a-uuid", "name": 7], at: 1)
        entries.append(["future": true])
        defaults.set(try JSONSerialization.data(withJSONObject: entries), forKey: "\(AppIdentifiers.subsystem).sshTerminal.barKeys")
        #expect(store.customKeys == [kept, other])
        // Saving another key keeps them, so the next write does not lose what still decodes.
        let added = SSHTerminalCustomKey(name: "Quit", key: "q")
        store.save(added)
        #expect(SSHTerminalBarStore(defaults: defaults).customKeys == [kept, other, added])
    }

    @Test func shiftOnlyTakesALetterOrANamedKey() {
        #expect(SSHTerminalCustomKey(shift: true, key: "d").isValid)
        #expect(SSHTerminalCustomKey(shift: true, key: "tab").isValid)
        #expect(SSHTerminalCustomKey(shift: true, key: "f5").isValid)
        // Shift-1 is `!` and shift-/ is `?`: the keymap cannot say that, so it is not offered.
        for typed in ["1", "/", "-", ";", "["] {
            #expect(!SSHTerminalCustomKey(shift: true, key: typed).isValid, "shift + \(typed)")
            #expect(SSHTerminalCustomKey(key: typed).isValid, "\(typed) alone")
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

@Suite("SSH terminal Rex control")
@MainActor
struct SSHTerminalRexControlTests {
    @Test func aRexPaneLeavesOutRexSessionsAndTheProgramStatusSymbolButHerdrAndPlainShellsKeepTheirs() {
        // The pane switcher's pill is the one Rex control: its panel holds
        // Rex Sessions and the status, so neither is in the bar.
        #expect(SSHTerminalBarContext.rex.hidden == [.herdr, .rex])
        #expect(!SSHTerminalBarContext.rex.showsProgramStatus)
        #expect(SSHTerminalBarContext.plain.hidden.isEmpty && SSHTerminalBarContext.plain.showsProgramStatus)
        #expect(SSHTerminalBarContext.herdr.hidden == [.rex] && SSHTerminalBarContext.herdr.showsProgramStatus)
        // What the terminal's polls and attention still count is only what its multiplexer rules out:
        // Back's dot keeps hearing about Rex panes that need you.
        #expect(SSHTerminalBarContext.rex.overviewsRuledOut == [.herdr])

        let layout = SSHTerminalBarLayout.defaultValue
        let inRex = offer(context: .rex).placement(layout: layout, capacity: 8)
        #expect(actions(of: inRex.slots) == [.keyboard, .chatBar, .switcher])
        #expect(!(inRex.slots + inRex.menu).contains { $0.item == .action(.rex) || $0.item == .action(.herdr) })
        // The saved layout is untouched: a plain shell shows Rex again as it was left.
        #expect(layout.isShown(.action(.rex)))
        #expect(actions(of: offer(context: .plain).placement(layout: layout, capacity: 8).slots).contains(.rex))
    }

    @MainActor
    @Test func theIconCarriesTheProgramsStatusTheProgressRingAndHowManyOthersNeedYou() {
        let button = SSHTerminalRexPanesButton()
        let panes: [RexSessionState.Pane] = [.init(blockID: "a", name: "pi"), .init(blockID: "b", name: "shell")]
        let state = RexSessionState(panes: panes, shown: "a", minimap: [])
        let theme = ThemeRuntimeState.currentThemeID()

        button.apply(state: state, tint: .white, status: .none, themeID: theme)
        #expect(button.shownStatus == nil && button.badgeText == nil && button.ring.isHidden)
        #expect(button.accessibilityValue == "pi, 1 of 2")

        // A resting program draws nothing: a quiet pane's icon stays clean.
        button.apply(state: state, tint: .white, status: .init(headline: .idle), themeID: theme)
        #expect(button.shownStatus == nil)

        button.apply(state: state, tint: .white, status: .init(headline: .working), themeID: theme)
        #expect(button.shownStatus == .working)

        let blocked = SSHTerminalRexPillStatus(
            headline: .needsApproval, progress: SSHTerminalProgressReport(state: .set, percent: 40), needsYou: 2
        )
        button.apply(state: state, tint: .white, status: blocked, themeID: theme)
        #expect(button.shownStatus == .needsApproval)
        #expect(button.badgeText == "2")
        #expect(!button.ring.isHidden && button.ring.drawnFraction == 0.4)
        #expect(button.accessibilityValue == "pi, 1 of 2, \(SessionStatusKind.needsApproval.label), Progress 40%, 2 need you")

        button.apply(state: state, tint: .white, status: .init(needsYou: 12), themeID: theme)
        #expect(button.badgeText == "9+")

        // Not a Rex session: the control and its marks go.
        button.apply(state: nil, tint: .white, status: blocked, themeID: theme)
        #expect(button.isHidden && button.shownStatus == nil && button.badgeText == nil)
    }

    // MARK: The panel

    private func record(_ state: ProgramStatusState, kind: ProgramStatusKind? = nil) -> SSHTerminalPaneRecord {
        SSHTerminalPaneRecord(id: "", state: state, kind: kind, app: "pi")
    }

    private func pane(_ id: String, _ records: [SSHTerminalPaneRecord] = []) -> RexSnapshot.Pane {
        RexSnapshot.Pane(blockID: id, label: nil, title: id, pwd: nil, records: records)
    }

    private func session(
        _ id: String, _ label: String, active: String? = nil, focused: String? = nil, panes: [RexSnapshot.Pane]
    ) -> RexSnapshot.Session {
        RexSnapshot.Session(
            sessionID: id, label: label, activeWindowID: "\(id).w",
            windows: [RexSnapshot.Window(windowID: "\(id).w", label: nil, focusedBlockID: focused, panes: panes)]
        )
    }

    private var snapshot: RexSnapshot {
        RexSnapshot(sessions: [
            session("s1", "oppi", panes: [pane("a", [record(.working)]), pane("b", [record(.blocked, kind: .permission)])]),
            session("s2", "dotfiles", focused: "d2", panes: [pane("d1"), pane("d2", [record(.blocked, kind: .question)])]),
            session("s3", "scratch", panes: [pane("e", [record(.idle)])]),
        ])
    }

    private let state = RexSessionState(
        panes: [.init(blockID: "a", name: "pi"), .init(blockID: "b", name: "claude")], shown: "a", minimap: []
    )

    private var statusRows: [SSHTerminalStatusRow] {
        [SSHTerminalStatusRow(id: "root", status: .working, title: "pi", message: "Refactoring", depth: 0)]
    }

    private func rows(_ settings: SSHTerminalRexPanelSettings = .init(), snapshot: RexSnapshot? = nil) -> [SSHTerminalOverviewSection] {
        SSHTerminalRexPanelContent.sections(
            settings: settings, sessionID: "s1", state: state, snapshot: snapshot ?? self.snapshot, statusRows: statusRows
        )
    }

    @Test func thePanelHasThisPaneThePanesOfTheSessionAndTheOtherSessions() throws {
        let sections = rows()
        #expect(sections.map(\.id) == ["thisPane", "panes", "otherSessions"])

        let thisPane = try #require(sections.first { $0.id == "thisPane" })
        #expect(thisPane.rows.map(\.title) == ["This pane", "pi"])
        #expect(thisPane.rows[1].kind == .item(subtitle: "Refactoring", focused: false, status: .known(.working)))

        // Each pane shows its status from the snapshot; the shown one is bold; a tap shows it.
        let panes = try #require(sections.first { $0.id == "panes" })
        #expect(panes.rows.map(\.title) == ["Panes in this session", "pi", "claude", "New Pane"])
        #expect(panes.rows[1].kind == .item(subtitle: nil, focused: true, status: .known(.working)))
        #expect(panes.rows[2].kind == .item(subtitle: nil, focused: false, status: .known(.needsApproval)))
        #expect(panes.rows[2].focus == .init(scope: "s1", id: "b", isGroup: false))
        #expect(panes.rows[2].accessibilityID == "sshTerminal.rexPanel.pane.b")
        #expect(panes.rows[3].focus == SSHTerminalRexPanelContent.newPaneFocus)

        // The other sessions, not this one, each with its panes and how many need you.
        let others = try #require(sections.first { $0.id == "otherSessions" })
        #expect(others.rows.map(\.title) == ["Other sessions", "dotfiles", "scratch"])
        #expect(others.rows[1].kind == .item(subtitle: "2 panes \u{00B7} 1 needs you", focused: false, status: .known(.question)))
        #expect(others.rows[2].kind == .item(subtitle: "1 pane", focused: false, status: .known(.idle)))
        // A tap opens the pane Rex types into there, else the first.
        #expect(others.rows[1].focus == .init(scope: "s2", id: "d2", isGroup: false))
        #expect(others.rows[2].focus == .init(scope: "s3", id: "e", isGroup: false))
    }

    @Test func eachSectionOfThePanelCanBeTurnedOff() {
        var settings = SSHTerminalRexPanelSettings()
        settings.showsThisPane = false
        #expect(rows(settings).map(\.id) == ["panes", "otherSessions"])
        settings.showsPanes = false
        #expect(rows(settings).map(\.id) == ["otherSessions"])
        settings.showsOtherSessions = false
        #expect(rows(settings).isEmpty)
    }

    @Test func thePanelSaysWhatIsMissingInsteadOfDrawingNothing() throws {
        let loading = SSHTerminalRexPanelContent.sections(
            settings: .init(), sessionID: "s1", state: state, snapshot: nil, statusRows: []
        )
        #expect(try #require(loading.first { $0.id == "thisPane" }).rows.map(\.title) == ["This pane", "No program status reported."])
        #expect(try #require(loading.first { $0.id == "otherSessions" }).rows.map(\.title) == ["Other sessions", "Loading\u{2026}"])
        let alone = RexSnapshot(sessions: [session("s1", "oppi", panes: [pane("a")])])
        #expect(try #require(rows(snapshot: alone).first { $0.id == "otherSessions" }).rows.map(\.title) == ["Other sessions", "No other sessions."])
    }

    @Test func theBadgeCountsPanesThatNeedYouExceptTheOneOnScreen() {
        func panes(shown: String) -> RexSessionState {
            var state = RexSessionState(
                panes: [.init(blockID: "a", name: "pi"), .init(blockID: "b", name: "claude")], shown: shown, minimap: []
            )
            state.panes[1].records = [record(.blocked, kind: .permission)]
            return state
        }
        // This session's other panes count from Rex's own reports, the host's other sessions from its snapshot (s2/d2 is blocked).
        #expect(SSHTerminalRexPanelContent.needsYou(state: panes(shown: "a"), snapshot: snapshot, sessionID: "s1") == 2)
        #expect(SSHTerminalRexPanelContent.needsYou(state: panes(shown: "b"), snapshot: snapshot, sessionID: "s1") == 1, "the shown pane's own status is on the icon already")
        #expect(SSHTerminalRexPanelContent.needsYou(state: panes(shown: "a"), snapshot: nil, sessionID: "s1") == 1)
        #expect(SSHTerminalRexPanelContent.needsYou(state: nil, snapshot: nil, sessionID: nil) == 0)
    }

    @Test func aPanesOwnRexReportsGiveItsStatusAndTheRowsOfThisPane() throws {
        var live = state
        live.panes[0].records = [record(.working)]
        // The pane's records win over the host snapshot, which was read a moment ago.
        let sections = SSHTerminalRexPanelContent.sections(
            settings: .init(), sessionID: "s1", state: live, snapshot: nil, statusRows: []
        )
        let panes = try #require(sections.first { $0.id == "panes" })
        #expect(panes.rows[1].kind == .item(subtitle: nil, focused: true, status: .known(.working)))
        // With none from the terminal's own stream, This pane is read from Rex's records.
        let rows = SSHTerminalRexPanelContent.statusRows(from: [
            SSHTerminalPaneRecord(id: "bash", state: .blocked, kind: .permission, message: "Run it?", app: "claude"),
            SSHTerminalPaneRecord(id: "", state: .working, app: "claude"),
        ])
        #expect(rows.map(\.id) == ["root", "bash"])
        #expect(rows.map(\.status) == [.working, .needsApproval])
        #expect(rows[1].message == "Run it?" && rows[1].depth == 1)
    }

    @Test func thePanelChoicesRoundTripAndDefaultToEverythingOn() {
        let store = SSHTerminalBarStore(defaults: isolatedDefaults())
        #expect(store.rexPanel == SSHTerminalRexPanelSettings())
        var settings = store.rexPanel
        settings.showsOtherSessions = false
        settings.showsStatusOnIcon = false
        store.setRexPanel(settings)
        #expect(SSHTerminalBarStore(defaults: store.defaults).rexPanel == settings)
        store.reset()
        #expect(store.rexPanel == settings, "Reset to Default is for the bar's list")
    }
}
