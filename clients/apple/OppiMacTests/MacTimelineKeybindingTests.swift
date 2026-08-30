import Foundation
import Testing
@testable import Oppi

@Suite("Mac timeline keybinding")
struct MacTimelineKeybindingTests {
    private let toolRowIDs = ["tool-a", "tool-b", "tool-c"]

    @Test func clickSelectsToolRowAndFocusesTimeline() {
        var state = MacTimelineKeybinding.State(focus: .composer)
        MacTimelineKeybinding.selectToolRow("tool-b", in: &state)

        #expect(state.selectedToolRowID == "tool-b")
        #expect(state.focus == .timeline)
        #expect(state.expandedToolRowIDs.isEmpty)
    }

    @Test func macDefaultArrowsMoveSelectionAndExpandCollapse() {
        var state = MacTimelineKeybinding.State(
            selectedToolRowID: "tool-a",
            focus: .timeline
        )

        #expect(apply(.downArrow, mode: .macDefault, to: &state) == .nextToolRow)
        #expect(state.selectedToolRowID == "tool-b")

        #expect(apply(.upArrow, mode: .macDefault, to: &state) == .previousToolRow)
        #expect(state.selectedToolRowID == "tool-a")

        #expect(apply(.rightArrow, mode: .macDefault, to: &state) == .expand)
        #expect(state.expandedToolRowIDs == ["tool-a"])

        #expect(apply(.leftArrow, mode: .macDefault, to: &state) == .collapse)
        #expect(state.expandedToolRowIDs.isEmpty)
    }

    @Test func vimLettersNavigateAndToggleWhenTimelineFocused() {
        var state = MacTimelineKeybinding.State(
            selectedToolRowID: "tool-a",
            focus: .timeline
        )

        #expect(apply(.letter("j"), mode: .vim, to: &state) == .nextToolRow)
        #expect(state.selectedToolRowID == "tool-b")

        #expect(apply(.letter("k"), mode: .vim, to: &state) == .previousToolRow)
        #expect(state.selectedToolRowID == "tool-a")

        #expect(apply(.letter("l"), mode: .vim, to: &state) == .expand)
        #expect(state.expandedToolRowIDs == ["tool-a"])

        #expect(apply(.letter("h"), mode: .vim, to: &state) == .collapse)
        #expect(state.expandedToolRowIDs.isEmpty)

        #expect(apply(.letter("e"), mode: .vim, to: &state) == .toggleExpanded)
        #expect(state.expandedToolRowIDs == ["tool-a"])
        #expect(apply(.letter("e"), mode: .vim, to: &state) == .toggleExpanded)
        #expect(state.expandedToolRowIDs.isEmpty)
    }

    @Test func macDefaultUnmodifiedLettersAreNotConsumed() {
        var state = MacTimelineKeybinding.State(
            selectedToolRowID: "tool-b",
            expandedToolRowIDs: ["tool-b"],
            focus: .timeline
        )
        let before = state

        for letter: Character in ["j", "k", "h", "l", "e", "a"] {
            #expect(apply(.letter(letter), mode: .macDefault, to: &state) == nil, "letter \(letter)")
            #expect(!MacTimelineKeybinding.consumes(nil))
        }

        #expect(state == before)
    }

    @Test func composerLettersAndVimKeysDoNotMoveTheTimeline() {
        var state = MacTimelineKeybinding.State(
            selectedToolRowID: "tool-a",
            expandedToolRowIDs: ["tool-a"],
            focus: .composer
        )
        let before = state

        for mode in KeybindingMode.allCases {
            for letter: Character in ["j", "k", "h", "l", "e", "a"] {
                #expect(
                    apply(.letter(letter), mode: mode, to: &state) == nil,
                    "\(mode.rawValue) composer \(letter)"
                )
            }
        }

        #expect(state == before)
    }

    @Test func composerCommandReturnIsSendAndDoesNotOpenAViewerOrExpand() {
        var state = MacTimelineKeybinding.State(
            selectedToolRowID: "tool-a",
            expandedToolRowIDs: [],
            focus: .composer
        )

        for mode in KeybindingMode.allCases {
            let action = apply(.commandReturn, mode: mode, to: &state)
            #expect(action == .send, "\(mode.rawValue)")
            #expect(action != .openViewer, "\(mode.rawValue)")
            #expect(!MacTimelineKeybinding.consumes(action), "\(mode.rawValue)")
        }

        #expect(state.selectedToolRowID == "tool-a")
        #expect(state.expandedToolRowIDs.isEmpty)
        #expect(state.focus == .composer)
    }

    @Test func timelineCommandReturnIsConsumedAndDoesNotSend() {
        var state = MacTimelineKeybinding.State(
            selectedToolRowID: "tool-a",
            expandedToolRowIDs: [],
            focus: .timeline
        )

        for mode in KeybindingMode.allCases {
            let action = apply(.commandReturn, mode: mode, to: &state)
            #expect(action == .openViewer, "\(mode.rawValue)")
            #expect(action != .send, "\(mode.rawValue)")
            #expect(MacTimelineKeybinding.consumes(action), "\(mode.rawValue)")
        }

        #expect(state.selectedToolRowID == "tool-a")
        #expect(state.expandedToolRowIDs.isEmpty)
        #expect(state.focus == .timeline)
    }

    @Test func nextWithoutSelectionPicksTheFirstToolRow() {
        var state = MacTimelineKeybinding.State(focus: .timeline)
        #expect(apply(.downArrow, mode: .macDefault, to: &state) == .nextToolRow)
        #expect(state.selectedToolRowID == "tool-a")
        #expect(state.focus == .timeline)
    }

    @Test func mappedArrowAndLetterChordsMatchTheCatalog() {
        let down = KeybindingEventMap.chord(
            characters: "",
            isUpArrow: false,
            isDownArrow: true,
            isLeftArrow: false,
            isRightArrow: false,
            isReturn: false,
            isEscape: false,
            isTab: false,
            command: false,
            shift: false,
            option: false,
            control: false
        )
        #expect(down == .downArrow)
        #expect(
            KeybindingCatalog.action(for: down!, mode: .macDefault, focus: .timeline)
                == .nextToolRow
        )

        let letterJ = KeybindingEventMap.chord(
            characters: "j",
            isUpArrow: false,
            isDownArrow: false,
            isLeftArrow: false,
            isRightArrow: false,
            isReturn: false,
            isEscape: false,
            isTab: false,
            command: false,
            shift: false,
            option: false,
            control: false
        )
        #expect(letterJ == .letter("j"))
        #expect(KeybindingCatalog.action(for: letterJ!, mode: .macDefault, focus: .timeline) == nil)
        #expect(KeybindingCatalog.action(for: letterJ!, mode: .vim, focus: .timeline) == .nextToolRow)
        #expect(KeybindingCatalog.action(for: letterJ!, mode: .vim, focus: .composer) == nil)
    }

    private func apply(
        _ chord: KeybindingChord,
        mode: KeybindingMode,
        to state: inout MacTimelineKeybinding.State
    ) -> KeybindingAction? {
        MacTimelineKeybinding.apply(
            chord: chord,
            mode: mode,
            to: &state,
            toolRowIDs: toolRowIDs
        )
    }
}

@Suite("Mac session timeline selection store")
@MainActor
struct MacSessionTimelineSelectionStoreTests {
    @Test func storeOwnsSelectionAndExpansionInsteadOfRowLocalState() {
        let store = MacSessionTraceStore()
        store.keybindingFocus = .composer
        store.selectToolRow("tool-a")
        store.setToolRowExpanded("tool-a", expanded: true)

        #expect(store.selectedToolRowID == "tool-a")
        #expect(store.keybindingFocus == .timeline)
        #expect(store.isToolRowExpanded("tool-a"))
        #expect(store.expandedToolRowIDs == ["tool-a"])
    }

    @Test func applyKeybindingUsesSessionOwnedExpansion() {
        let originalMode = UserDefaults.standard.object(forKey: KeybindingMode.preferenceKey)
        defer { UserDefaults.standard.set(originalMode, forKey: KeybindingMode.preferenceKey) }
        let store = MacSessionTraceStore()
        store.keybindingMode = .macDefault
        store.selectToolRow("tool-a")

        #expect(store.applyKeybinding(.rightArrow, toolRowIDs: ["tool-a", "tool-b"]) == .expand)
        #expect(store.expandedToolRowIDs == ["tool-a"])
        #expect(store.applyKeybinding(.downArrow, toolRowIDs: ["tool-a", "tool-b"]) == .nextToolRow)
        #expect(store.selectedToolRowID == "tool-b")
        #expect(store.applyKeybinding(.letter("j"), toolRowIDs: ["tool-a", "tool-b"]) == nil)
        #expect(store.selectedToolRowID == "tool-b")
    }

    @Test func nextKeyEventReadsPersistedModeWithoutRecreatingSessionStore() {
        let originalMode = UserDefaults.standard.object(forKey: KeybindingMode.preferenceKey)
        defer { UserDefaults.standard.set(originalMode, forKey: KeybindingMode.preferenceKey) }
        let preferences = KeybindingPreferenceStore()
        preferences.mode = .macDefault

        let store = MacSessionTraceStore()
        store.selectToolRow("tool-a")
        #expect(store.applyKeybinding(.letter("j"), toolRowIDs: ["tool-a", "tool-b"]) == nil)
        #expect(store.selectedToolRowID == "tool-a")

        preferences.mode = .vim

        #expect(store.applyKeybinding(.letter("j"), toolRowIDs: ["tool-a", "tool-b"]) == .nextToolRow)
        #expect(store.selectedToolRowID == "tool-b")
    }

    @Test func composerFocusKeepsLettersAndCommandReturnSend() {
        let originalMode = UserDefaults.standard.object(forKey: KeybindingMode.preferenceKey)
        defer { UserDefaults.standard.set(originalMode, forKey: KeybindingMode.preferenceKey) }
        let store = MacSessionTraceStore()
        store.keybindingMode = .vim
        store.keybindingFocus = .composer
        store.selectToolRow("tool-a")
        store.keybindingFocus = .composer

        #expect(store.applyKeybinding(.letter("j"), toolRowIDs: ["tool-a", "tool-b"]) == nil)
        #expect(store.selectedToolRowID == "tool-a")
        #expect(store.applyKeybinding(.commandReturn, toolRowIDs: ["tool-a", "tool-b"]) == .send)
        #expect(!MacTimelineKeybinding.consumes(.send))
        #expect(store.selectedToolRowID == "tool-a")
        #expect(store.expandedToolRowIDs.isEmpty)
        #expect(store.keybindingFocus == .composer)
    }

    @Test func timelineCommandReturnIsConsumedAndDoesNotSend() {
        let originalMode = UserDefaults.standard.object(forKey: KeybindingMode.preferenceKey)
        defer { UserDefaults.standard.set(originalMode, forKey: KeybindingMode.preferenceKey) }
        let store = MacSessionTraceStore()
        store.keybindingMode = .macDefault
        store.selectToolRow("tool-a")

        let action = store.applyKeybinding(.commandReturn, toolRowIDs: ["tool-a", "tool-b"])
        #expect(action == .openViewer)
        #expect(action != .send)
        #expect(MacTimelineKeybinding.consumes(action))
        #expect(store.selectedToolRowID == "tool-a")
        #expect(store.expandedToolRowIDs.isEmpty)
        #expect(store.keybindingFocus == .timeline)
    }

    @Test func changingSessionsClearsSelectionAndExpansion() {
        let store = MacSessionTraceStore()
        store.select(makeTarget(sessionId: "session-1"))
        store.selectToolRow("tool-a")
        store.setToolRowExpanded("tool-a", expanded: true)

        store.select(makeTarget(sessionId: "session-2"))

        #expect(store.selectedToolRowID == nil)
        #expect(store.expandedToolRowIDs.isEmpty)
        #expect(store.keybindingFocus == .composer)
    }

    @Test func toolTimelineRowsDoNotKeepRowLocalExpandedState() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "OppiMac/Views/MacSessionTimelineViews.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try #require(source.range(of: "private struct ToolTimelineBubble: View {"))
        let end = try #require(
            source.range(
                of: "private struct MacBashCommandBar: View {",
                range: start.upperBound..<source.endIndex
            )
        )
        let bubble = String(source[start.lowerBound..<end.lowerBound])
        #expect(!bubble.contains("@State private var isExpanded"))
        #expect(bubble.contains("store.isToolRowExpanded"))
        #expect(bubble.contains("store.selectToolRow"))
    }

    @Test func expandCollapseButtonIsNotOwnedByHighPriorityRowGesture() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "OppiMac/Views/MacSessionTimelineViews.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(!source.contains("highPriorityGesture"))
        #expect(source.contains("Button(isExpanded ? \"Collapse\" : \"Expand\")"))
        #expect(source.contains("store.setToolRowExpanded"))
    }
}

private func makeTarget(sessionId: String) -> MacSelectedSessionTarget {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let session = Session(
        id: sessionId,
        workspaceId: "workspace-timeline",
        workspaceName: "Workspace",
        status: .ready,
        createdAt: now,
        lastActivity: now,
        model: "provider/model",
        messageCount: 1,
        tokens: TokenUsage(input: 0, output: 0),
        cost: 0,
        firstMessage: "Hello"
    )
    return MacSelectedSessionTarget(
        workspaceId: "workspace-timeline",
        sessionId: session.id,
        summary: SessionSummary(from: session)
    )
}
