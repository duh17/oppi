import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Oppi

@Suite("Mac session pane chrome")
struct MacSessionPaneChromeTests {
    @Test func paneHeaderIsTitleAndCloseOnly() throws {
        let source = try paneDeckSource()
        let header = try sourceSlice(
            named: "private var paneHeader: some View {",
            until: "private var title: String {",
            in: source
        )
        #expect(header.contains("mac.session.pane.header"))
        #expect(header.contains("mac.session.pane.close"))
        #expect(header.contains("Image(systemName: \"xmark\")"))
        #expect(!header.contains("ellipsis.circle"))
        #expect(!header.contains("Pane actions"))
        #expect(!header.contains("splitMenu"))
        #expect(!header.contains("Menu(\"Split Right\""))
        #expect(!header.contains("Menu(\"Split Below\""))
        #expect(!source.contains("ellipsis.circle"))
        #expect(!source.contains("splitMenu"))
        #expect(!source.contains("Menu(\"Split Right\""))
        #expect(!source.contains("Menu(\"Split Below\""))
    }

    @Test func focusChromeDoesNotDimOrCoverTheTimeline() throws {
        #expect(MacSessionPaneFocusChrome.usesFullPaneDimmingOverlay == false)
        #expect(MacSessionPaneFocusChrome.focusStrokeAllowsHitTesting == false)

        let source = try paneDeckSource()
        #expect(source.contains("allowsHitTesting(MacSessionPaneFocusChrome.focusStrokeAllowsHitTesting)"))
        #expect(!source.contains("Color.black.opacity"))
        #expect(!source.contains(".overlay {\n            Color."))
        #expect(!source.contains("usesFullPaneDimmingOverlay = true"))
    }

    @Test func documentCloseStaysOutsidePaneTapToFocus() throws {
        let shell = try shellSource()
        let timeline = try sourceSlice(
            named: "private var timelineColumn: some View {",
            until: "private var documentColumn: some View {",
            in: shell
        )
        #expect(timeline.contains("simultaneousGesture("))
        #expect(timeline.contains("activatePane?()"))

        let document = try sourceSlice(
            named: "private var documentColumn: some View {",
            until: "private var reviewCommentStaging:",
            in: shell
        )
        #expect(!document.contains("simultaneousGesture("))
        #expect(!document.contains("activatePane"))

        let column = try documentColumnSource()
        #expect(column.contains("mac.documentColumn.close"))
        #expect(column.contains("Close document"))
    }

    @Test func zeroPaneHomeUsesQuickSessionDeckInsteadOfSelectSessionPlaceholder() throws {
        let deckSource = try paneDeckSource()
        #expect(!deckSource.contains("Select a session"))
        #expect(!deckSource.contains("Choose a session to open the conversation."))

        let main = try contents(of: "OppiMac/Views/MainWindowView.swift")
        let homeDetail = try sourceSlice(
            named: "case .sessionHome:",
            until: "case .agents, .schedules, .skills, .extensions:",
            in: main
        )
        #expect(homeDetail.contains("MacSessionPaneDeckView("))
        #expect(!homeDetail.contains("Select a session"))
        #expect(!homeDetail.contains("Choose a session to open the conversation."))
    }

    @Test func emptyPaneHostsQuickSessionComposer() throws {
        let source = try paneDeckSource()
        #expect(source.contains("MacQuickSessionPaneComposer("))
        #expect(source.contains("\"New Session\""))
        #expect(source.contains("mac.session.pane.quickSession") == false)

        let composer = try quickSessionSource()
        #expect(composer.contains("mac.session.pane.quickSession"))
        #expect(composer.contains("mac.quickSession.workspace"))
        #expect(composer.contains("mac.quickSession.worktree"))
        #expect(composer.contains("mac.quickSession.agent"))
        #expect(composer.contains("mac.composer.input"))
        #expect(composer.contains("MacComposerInputView("))
        #expect(!composer.contains("QuickSessionSheet"))
        #expect(!composer.contains("UIKit"))
    }

    @Test func launchCompletionReplacesTheOriginatingPaneNotFocus() throws {
        let launch = try sourceSlice(
            named: "private func launchQuickSession(",
            until: "private func stopSessionTarget(",
            in: try contents(of: "OppiMac/Views/MainWindowView.swift")
        )
        #expect(launch.contains("launchIntoOriginatingPane"))
        #expect(launch.contains("originatingRuntime: runtime"))
        #expect(!launch.contains("replaceFocused"))
    }

    @Test func focusingQuickSessionInputActivatesItsPane() throws {
        let composer = try quickSessionSource()
        #expect(composer.contains("let activate: () -> Void"))
        let focusHandler = try sourceSlice(
            named: "onFocusChange: { focused in",
            until: "onPasteAttachments:",
            in: composer
        )
        #expect(focusHandler.contains("activate()"))

        let composerCall = try sourceSlice(
            named: "MacQuickSessionPaneComposer(",
            until: "SessionTraceShellDetail(",
            in: try paneDeckSource()
        )
        #expect(composerCall.contains("activate: activate"))
    }
}

@Suite("Mac session pane commands")
struct MacSessionPaneCommandTests {
    @Test func paneShortcutsMatchTheContract() {
        #expect(MacSessionPaneCommand.splitRight.key == "d")
        #expect(MacSessionPaneCommand.splitRight.modifiers == .command)
        #expect(MacSessionPaneCommand.splitDown.key == "d")
        #expect(MacSessionPaneCommand.splitDown.modifiers == [.command, .shift])
        #expect(MacSessionPaneCommand.focusLeft.key == .leftArrow)
        #expect(MacSessionPaneCommand.focusRight.key == .rightArrow)
        #expect(MacSessionPaneCommand.focusUp.key == .upArrow)
        #expect(MacSessionPaneCommand.focusDown.key == .downArrow)
        #expect(MacSessionPaneCommand.focusLeft.modifiers == [.command, .option])
        #expect(MacSessionPaneCommand.closePane.key == "w")
        #expect(MacSessionPaneCommand.closePane.modifiers == [.command, .shift])
    }

    @Test func viewMenuAndHelpExposeTheSameBindings() throws {
        let source = try paneCommandsSource()
        #expect(source.contains("CommandMenu(\"View\")"))
        #expect(source.contains("CommandGroup(after: .help)"))
        #expect(source.contains("Keyboard Shortcuts"))
        #expect(source.contains("keyboardShortcut(\"?\", modifiers: .shift)"))
        #expect(source.contains("canShowCheatSheet"))
        #expect(!source.contains("KeybindingCatalog.action"))
    }

    @Test @MainActor func paneShortcutsTransferKeyboardOwnershipAwayFromTheOriginComposer() async throws {
        let deck = MacSessionPaneDeck()
        let paneA = try #require(deck.openOrFocus(chromeTarget(sessionID: "session-a")))
        let paneB = try #require(deck.splitFocusedRight())
        #expect(deck.focus(paneID: paneA.id))
        let commands = MacSessionPaneCommandCenter(deck: deck)

        let host = NSHostingView(rootView: chromeDeckView(deck: deck))
        host.frame = NSRect(x: 0, y: 0, width: 1_000, height: 700)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
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

        let inputs = chromeDescendants(of: host, type: MacComposerPasteTextView.self)
        let originInput = try #require(inputs.min { lhs, rhs in
            lhs.convert(lhs.bounds, to: nil).midX < rhs.convert(rhs.bounds, to: nil).midX
        })
        #expect(window.makeFirstResponder(originInput))
        await Task.yield()

        #expect(deck.focusedPaneID == paneA.id)
        #expect(paneA.composerState.isComposerFirstResponder)
        #expect(!paneB.composerState.isComposerFirstResponder)
        #expect(!commands.canShowCheatSheet)

        commands.perform(.focusRight)
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            await Task.yield()
            if window.firstResponder !== originInput,
               !paneA.composerState.isComposerFirstResponder {
                break
            }
        }

        #expect(deck.focusedPaneID == paneB.id)
        #expect(!paneA.composerState.isComposerFirstResponder)
        #expect(window.firstResponder !== originInput)

        if let responder = window.firstResponder as? NSTextView {
            responder.insertText("?", replacementRange: responder.selectedRange())
        }
        #expect(!originInput.string.contains("?"))
        #expect(!paneA.composerState.draft.contains("?"))
        if paneB.composerState.isComposerFirstResponder {
            #expect(!commands.canShowCheatSheet)
        }
    }
}

@Suite("Mac keyboard cheat sheet")
struct MacAppKeybindingHelpTests {
    @Test func listsEveryMacAppBinding() {
        let actions = Set(MacAppKeybindingHelp.entries.map(\.action))
        for required in [
            "Split Right", "Split Down", "Focus Left", "Focus Right",
            "Focus Up", "Focus Down", "Close Pane", "Close Window",
            "Send", "Keyboard Shortcuts", "Close Document",
            "Previous Tool Row", "Next Tool Row", "Open Document",
            "Vim Next Tool Row", "Vim Focus Composer",
        ] {
            #expect(actions.contains(required), "Missing \(required)")
        }
        #expect(MacAppKeybindingHelp.entries.contains { $0.shortcut == "⌘D" })
        #expect(MacAppKeybindingHelp.entries.contains { $0.shortcut == "⌘⇧D" })
        #expect(MacAppKeybindingHelp.entries.contains { $0.shortcut == "⌘⇧W" })
        #expect(MacAppKeybindingHelp.entries.contains { $0.shortcut == "⌘W" })
        #expect(MacAppKeybindingHelp.entries.contains { $0.shortcut == "⇧?" })
        #expect(MacAppKeybindingHelp.entries.count == MacAppKeybindingHelp.paneEntries.count
            + MacAppKeybindingHelp.sessionEntries.count
            + MacAppKeybindingHelp.timelineEntries.count)
    }

    @Test func shiftQuestionDoesNotStealComposerTyping() {
        #expect(MacAppKeybindingHelp.allowsCheatSheetShortcut(composerIsFirstResponder: false))
        #expect(!MacAppKeybindingHelp.allowsCheatSheetShortcut(composerIsFirstResponder: true))
    }

    @Test @MainActor func cheatSheetWorksUntilTheComposerIsFirstResponder() throws {
        let deck = MacSessionPaneDeck()
        let session = Session(
            id: "session-a",
            workspaceId: "workspace",
            workspaceName: "workspace",
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastActivity: Date(timeIntervalSince1970: 1_800_000_001),
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        )
        let runtime = try #require(deck.openOrFocus(
            MacSelectedSessionTarget(
                workspaceId: "workspace",
                sessionId: "session-a",
                summary: SessionSummary(from: session)
            )
        ))
        let commands = MacSessionPaneCommandCenter(deck: deck)

        #expect(runtime.traceStore.keybindingFocus == .composer)
        #expect(!runtime.composerState.isComposerFirstResponder)
        #expect(commands.canShowCheatSheet)

        runtime.composerState.isComposerFirstResponder = true
        #expect(!commands.canShowCheatSheet)

        runtime.composerState.isComposerFirstResponder = false
        #expect(commands.canShowCheatSheet)
    }

    @Test @MainActor func shiftQuestionFollowsTheTypingComposerNotTheOutlinedPane() throws {
        let deck = MacSessionPaneDeck()
        let paneA = try #require(deck.openOrFocus(chromeTarget(sessionID: "session-a")))
        let paneB = try #require(deck.splitFocusedRight())
        #expect(deck.focus(paneID: paneA.id))
        paneA.composerState.isComposerFirstResponder = true
        let commands = MacSessionPaneCommandCenter(deck: deck)
        #expect(!commands.canShowCheatSheet)

        #expect(deck.focus(paneID: paneB.id))
        #expect(deck.focusedPaneID == paneB.id)
        #expect(paneA.composerState.isComposerFirstResponder)
        #expect(!paneB.composerState.isComposerFirstResponder)
        #expect(!commands.canShowCheatSheet)
    }
}

@MainActor
private func chromeDeckView(deck: MacSessionPaneDeck) -> some View {
    MacSessionPaneDeckView(
        deck: deck,
        workspaces: [chromeWorkspace()],
        isStoppingSession: { _ in false },
        stopTarget: { _ in },
        loadWorktrees: { _ in [] },
        launchQuickSession: { _, _ in },
        loadsSessionsOnMount: false
    )
    .environment(\.theme, AppTheme.dark)
    .environment(\.themeID, ThemeID.dark)
}

private func chromeTarget(sessionID: String) -> MacSelectedSessionTarget {
    let session = Session(
        id: sessionID,
        workspaceId: "workspace",
        workspaceName: "workspace",
        name: sessionID,
        status: .ready,
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        lastActivity: Date(timeIntervalSince1970: 1_800_000_001),
        messageCount: 1,
        tokens: TokenUsage(input: 0, output: 0),
        cost: 0
    )
    return MacSelectedSessionTarget(
        workspaceId: "workspace",
        sessionId: sessionID,
        summary: SessionSummary(from: session)
    )
}

private func chromeWorkspace() -> Workspace {
    Workspace(
        id: "workspace",
        name: "Oppi",
        description: nil,
        icon: .symbol("folder"),
        systemPrompt: nil,
        hostMount: "/tmp/oppi",
        tools: nil,
        gitStatusEnabled: nil,
        runtime: .host,
        sandboxConfig: nil,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
}

@MainActor
private func chromeDescendants<T: NSView>(of root: NSView, type: T.Type) -> [T] {
    var matches: [T] = []
    if let match = root as? T {
        matches.append(match)
    }
    for subview in root.subviews {
        matches.append(contentsOf: chromeDescendants(of: subview, type: type))
    }
    return matches
}

private func paneDeckSource() throws -> String {
    try contents(of: "OppiMac/Views/MacSessionPaneDeckView.swift")
}

private func paneCommandsSource() throws -> String {
    try contents(of: "OppiMac/Session/Models/MacSessionPaneCommands.swift")
}

private func quickSessionSource() throws -> String {
    try contents(of: "OppiMac/Views/MacQuickSessionPaneComposer.swift")
}

private func shellSource() throws -> String {
    try contents(of: "OppiMac/Views/MacSessionShellViews.swift")
}

private func documentColumnSource() throws -> String {
    try contents(of: "OppiMac/Views/MacToolDocumentColumn.swift")
}

private func sourceSlice(named marker: String, until endMarker: String, in source: String) throws -> String {
    guard let start = source.range(of: marker) else {
        Issue.record("Missing source marker \(marker)")
        throw SourceSliceError.missingMarker(marker)
    }
    guard let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
        Issue.record("Missing source end marker \(endMarker)")
        throw SourceSliceError.missingMarker(endMarker)
    }
    return String(source[start.lowerBound..<end.lowerBound])
}

private enum SourceSliceError: Error {
    case missingMarker(String)
}

private func contents(of relativePath: String) throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: relativePath)
    return try String(contentsOf: sourceURL, encoding: .utf8)
}
