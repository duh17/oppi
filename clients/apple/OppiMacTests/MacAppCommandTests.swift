import AppKit
import Foundation
import Testing
@testable import Oppi

@Suite("Mac app command shortcuts")
@MainActor
struct MacAppCommandShortcutTests {
    @Test func defaultShortcutsAreUniqueAndNeverSteal() {
        var seen: [MacKeyShortcut: MacAppCommand] = [:]
        for command in MacAppCommand.allCases {
            guard let shortcut = command.defaultShortcut else { continue }
            #expect(seen[shortcut] == nil, "\(command) collides with \(String(describing: seen[shortcut]))")
            #expect(shortcut.hasCommandLikeModifier, "\(command) would type into the composer")
            #expect(!shortcut.isReservedBySystem, "\(command) takes a macOS shortcut")
            seen[shortcut] = command
        }
    }

    @Test func assigningATakenChordMovesItAndPersists() throws {
        let defaults = try makeDefaults()
        let store = MacKeybindingStore(defaults: defaults)
        let chord = try #require(MacAppCommand.splitRight.defaultShortcut)

        let displaced = try store.assign(chord, to: .newSession)

        #expect(displaced == .splitRight)
        #expect(store.shortcut(for: .newSession) == chord)
        #expect(store.shortcut(for: .splitRight) == nil)
        #expect(store.command(boundTo: chord) == .newSession)

        let reloaded = MacKeybindingStore(defaults: defaults)
        #expect(reloaded.shortcut(for: .newSession) == chord)
        #expect(reloaded.shortcut(for: .splitRight) == nil)
    }

    @Test func resettingRestoresTheDefaultAndTakesItBack() throws {
        let store = MacKeybindingStore(defaults: try makeDefaults())
        let splitChord = try #require(MacAppCommand.splitRight.defaultShortcut)
        try store.assign(splitChord, to: .newSession)

        store.reset(.splitRight)

        #expect(store.shortcut(for: .splitRight) == splitChord)
        #expect(store.shortcut(for: .newSession) == nil)
        #expect(store.command(boundTo: splitChord) == .splitRight)
    }

    @Test func reassigningTheDefaultClearsTheOverride() throws {
        let store = MacKeybindingStore(defaults: try makeDefaults())
        try store.assign(MacKeyShortcut("y", [.command, .option]), to: .newSession)
        #expect(store.isCustomized(.newSession))

        try store.assign(try #require(MacAppCommand.newSession.defaultShortcut), to: .newSession)

        #expect(!store.isCustomized(.newSession))
        #expect(store.overrides.isEmpty)
    }

    @Test func rejectsTypingKeysAndSystemShortcuts() throws {
        let store = MacKeybindingStore(defaults: try makeDefaults())
        #expect(throws: MacKeybindingStore.AssignmentError.needsModifier) {
            try store.assign(MacKeyShortcut("n", []), to: .newSession)
        }
        #expect(throws: MacKeybindingStore.AssignmentError.needsModifier) {
            try store.assign(MacKeyShortcut("n", .shift), to: .newSession)
        }
        #expect(throws: MacKeybindingStore.AssignmentError.reservedBySystem) {
            try store.assign(MacKeyShortcut("q", .command), to: .newSession)
        }
        #expect(store.shortcut(for: .newSession) == MacAppCommand.newSession.defaultShortcut)
    }

    @Test func unboundCommandsStayUnboundAcrossLaunches() throws {
        let defaults = try makeDefaults()
        MacKeybindingStore(defaults: defaults).unbind(.stopTurn)
        #expect(MacKeybindingStore(defaults: defaults).shortcut(for: .stopTurn) == nil)
    }

    @Test func presetPersistsThroughTheSharedTimelineKey() throws {
        let defaults = try makeDefaults()
        MacKeybindingStore(defaults: defaults).setTimelinePreset(.emacs)
        #expect(KeybindingPreferenceStore(defaults: defaults).mode == .emacs)
        #expect(MacKeybindingStore(defaults: defaults).timelinePreset == .emacs)
    }

    @Test func recordsShortcutsFromKeyEvents() throws {
        let shiftD = try #require(keyEvent("D", ignoring: "D", keyCode: 2, flags: [.command, .shift]))
        #expect(MacKeyShortcut(event: shiftD) == MacKeyShortcut("d", [.command, .shift]))
        #expect(MacKeyShortcut(event: shiftD)?.displayString == "⇧⌘D")

        // Shift is part of the typed symbol, which is how AppKit matches it.
        let brace = try #require(keyEvent("}", ignoring: "}", keyCode: 30, flags: [.command, .shift]))
        #expect(MacKeyShortcut(event: brace) == MacKeyShortcut("}", .command))

        let arrow = try #require(keyEvent("\u{F702}", ignoring: "\u{F702}", keyCode: 123, flags: [.command, .option]))
        #expect(MacKeyShortcut(event: arrow)?.displayString == "⌥⌘←")

        let f5 = try #require(keyEvent("\u{F708}", ignoring: "\u{F708}", keyCode: 96, flags: [.command]))
        #expect(MacKeyShortcut(event: f5) == nil)

        let plus = try #require(keyEvent("+", ignoring: "=", keyCode: 24, flags: [.command, .shift]))
        #expect(MacKeyShortcut(event: plus) == MacKeyShortcut("+", .command))
        #expect(MacKeyShortcut(event: plus)?.displayString == "⌘+")
    }

    @Test func zoomDefaultsUseTheStandardChords() {
        #expect(MacAppCommand.zoomIn.defaultShortcut == MacKeyShortcut("+", .command))
        #expect(MacAppCommand.zoomOut.defaultShortcut == MacKeyShortcut("-", .command))
        #expect(MacAppCommand.actualSize.defaultShortcut == MacKeyShortcut("0", .command))
        #expect(MacAppCommand.zoomIn.defaultShortcut?.displayString == "⌘+")
        #expect(MacAppCommand.zoomOut.defaultShortcut?.displayString == "⌘-")
        #expect(MacAppCommand.actualSize.defaultShortcut?.displayString == "⌘0")
    }

    private func keyEvent(
        _ characters: String,
        ignoring: String,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: ignoring,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}

@Suite("Mac client script")
struct MacClientScriptTests {
    @Test func parsesFocusCommandAndCatalog() {
        #expect(MacClientScript.parse("focus timeline") == .focus(.timeline))
        #expect(MacClientScript.parse("command focusComposer") == .command(.focusComposer))
        #expect(MacClientScript.parse("catalog nextToolRow") == .catalog(.nextToolRow))
        #expect(MacClientScript.parse("focus nowhere") == nil)
        #expect(MacClientScript.parse("press j") == nil)
    }

    @Test func sendStaysAComposerControl() {
        #expect(MacClientScript.controlIdentifier(for: .send) == "mac.composer.send")
        #expect(MacClientScript.controlIdentifier(for: .focusTimeline) == nil)
    }

    @Test func snapshotLineIsStableForComputerUse() {
        let line = MacClientScriptSnapshot(
            focus: "timeline",
            section: "sessionHome",
            sessionID: "sess",
            selectedToolRowID: "tool-1",
            openDocumentID: "-",
            palette: "closed",
            lastStep: "catalog nextToolRow",
            lastResult: "performed"
        ).accessibilityValue
        #expect(line == "focus=timeline section=sessionHome session=sess row=tool-1 document=- palette=closed last=catalog nextToolRow result=performed")
    }
}

@Suite("Mac text zoom")
struct MacTextZoomTests {
    @Test func stepsBothScalesAndClampsEachIndependently() {
        let start = MacTextZoom.Scales(code: 1.0, message: 1.0)
        #expect(MacTextZoom.stepped(start, .larger) == .init(code: 1.1, message: 1.1))
        #expect(MacTextZoom.stepped(start, .smaller) == .init(code: 0.9, message: 0.9))

        var scales = start
        for _ in 0..<10 { scales = MacTextZoom.stepped(scales, .larger) }
        #expect(scales == .init(
            code: FontPreferenceStore.maximumCodeTextScale,
            message: FontPreferenceStore.maximumMessageTextScale
        ))
        #expect(!MacTextZoom.canStep(scales, .larger))
        #expect(MacTextZoom.canStep(scales, .smaller))

        // Message bottoms out at 0.9 while code still has room to 0.85.
        let smallest = MacTextZoom.stepped(.init(code: 0.95, message: 0.9), .smaller)
        #expect(smallest == .init(code: 0.85, message: 0.9))
    }
}

@Suite("Mac tool row clicks")
struct MacToolRowClickTests {
    @Test func singleClickTogglesAndDoubleClickOpensTheDocument() {
        #expect(MacToolRowClick.action(clickCount: 1, canExpand: true, canOpenDocument: true) == .toggleExpanded)
        #expect(MacToolRowClick.action(clickCount: 2, canExpand: true, canOpenDocument: true)
            == .openDocument(revertExpansion: true))
        #expect(MacToolRowClick.action(clickCount: 2, canExpand: false, canOpenDocument: true)
            == .openDocument(revertExpansion: false))
        #expect(MacToolRowClick.action(clickCount: 1, canExpand: false, canOpenDocument: true) == nil)
        #expect(MacToolRowClick.action(clickCount: 2, canExpand: true, canOpenDocument: false) == nil)
        #expect(MacToolRowClick.action(clickCount: 3, canExpand: true, canOpenDocument: true) == nil)
    }
}

@Suite("Mac home session order")
struct MacHomeSessionOrderTests {
    @Test func adjacentFollowsDisplayOrderWithoutWrapping() {
        let targets = ["a", "b", "c"].map(orderTarget)
        #expect(MacHomeSessionOrder.adjacent(to: "a", in: targets, offset: 1)?.sessionId == "b")
        #expect(MacHomeSessionOrder.adjacent(to: "b", in: targets, offset: -1)?.sessionId == "a")
        #expect(MacHomeSessionOrder.adjacent(to: "c", in: targets, offset: 1) == nil)
        #expect(MacHomeSessionOrder.adjacent(to: "a", in: targets, offset: -1) == nil)
        #expect(MacHomeSessionOrder.adjacent(to: nil, in: targets, offset: 1)?.sessionId == "a")
        #expect(MacHomeSessionOrder.adjacent(to: "gone", in: targets, offset: -1)?.sessionId == "c")
        #expect(MacHomeSessionOrder.adjacent(to: "a", in: [], offset: 1) == nil)
    }

    @Test func orderPutsWorkingBeforeStopped() {
        let stopped = orderTarget("stopped", status: .stopped)
        let busy = orderTarget("busy", status: .busy)
        #expect(MacHomeSessionOrder.ordered([stopped, busy]).map(\.sessionId) == ["busy", "stopped"])
    }
}

@Suite("Mac command palette search")
struct MacCommandPaletteSearchTests {
    @Test func ranksWordStartsAndPrefixesFirstAndDropsNonMatches() {
        let items = [
            paletteItem("Zoom Out", keywords: "text size"),
            paletteItem("Split Right"),
            paletteItem("Session Outline", keywords: "outline navigator"),
            paletteItem("Stop Turn", keywords: "abort cancel"),
        ]
        #expect(MacCommandPaletteSearch.rank(items, query: "sr").map(\.title).first == "Split Right")
        #expect(MacCommandPaletteSearch.rank(items, query: "outl").map(\.title).first == "Session Outline")
        #expect(MacCommandPaletteSearch.rank(items, query: "abort").map(\.title) == ["Stop Turn"])
        #expect(MacCommandPaletteSearch.rank(items, query: "font size").map(\.title) == [])
        #expect(MacCommandPaletteSearch.rank(items, query: "text").map(\.title) == ["Zoom Out"])
        #expect(MacCommandPaletteSearch.rank(items, query: "qqq").isEmpty)
    }

    @Test func emptyQueryKeepsOrderButSinksDisabledItems() {
        let items = [
            paletteItem("Send", enabled: false),
            paletteItem("New Session"),
            paletteItem("Zoom In"),
        ]
        #expect(MacCommandPaletteSearch.rank(items, query: "").map(\.title) == ["New Session", "Zoom In", "Send"])
    }

    @Test func selectionStaysInBounds() {
        #expect(MacCommandPaletteSearch.moveSelection(0, by: -1, count: 3) == 0)
        #expect(MacCommandPaletteSearch.moveSelection(2, by: 1, count: 3) == 2)
        #expect(MacCommandPaletteSearch.moveSelection(1, by: 1, count: 3) == 2)
        #expect(MacCommandPaletteSearch.moveSelection(4, by: 1, count: 0) == 0)
    }

    private func paletteItem(_ title: String, keywords: String = "", enabled: Bool = true) -> MacCommandPaletteItem {
        MacCommandPaletteItem(
            id: title,
            kind: .command(.newSession),
            title: title,
            subtitle: nil,
            systemImage: "circle",
            shortcut: nil,
            isEnabled: enabled,
            keywords: keywords
        )
    }
}

@Suite("Mac new session pane")
@MainActor
struct MacNewSessionPaneTests {
    @Test func reusesAnEmptyPaneBeforeClearingTheFocusedSession() throws {
        let deck = MacSessionPaneDeck()
        deck.noteWindowSize(MacSessionPaneMeasuredSize(width: 1_600, height: 900))
        let sessionPane = try #require(deck.openOrFocus(orderTarget("session-a")))
        let emptyPane = try #require(deck.splitFocusedRight())
        #expect(deck.focus(paneID: sessionPane.id))

        #expect(deck.showNewSessionPane() === emptyPane)
        #expect(deck.focusedPaneID == emptyPane.id)
        #expect(sessionPane.target?.sessionId == "session-a")

        #expect(deck.closeFocused())
        #expect(deck.focusedPaneID == sessionPane.id)
        let cleared = try #require(deck.showNewSessionPane())
        #expect(cleared === sessionPane)
        #expect(cleared.isEmpty)
        #expect(deck.focusedSessionID == nil)
        #expect(deck.paneCount == 1)
    }
}

private func orderTarget(_ id: String) -> MacSelectedSessionTarget {
    orderTarget(id, status: .ready)
}

private func orderTarget(_ id: String, status: SessionStatus) -> MacSelectedSessionTarget {
    let session = Session(
        id: id,
        workspaceId: "workspace",
        workspaceName: "workspace",
        status: status,
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        lastActivity: Date(timeIntervalSince1970: 1_800_000_001),
        messageCount: 1,
        tokens: TokenUsage(input: 0, output: 0),
        cost: 0
    )
    return MacSelectedSessionTarget(workspaceId: "workspace", sessionId: id, summary: SessionSummary(from: session))
}

private func makeDefaults() throws -> UserDefaults {
    let suiteName = "MacAppCommandTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
