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
        #expect(header.contains("mac.session.pane.ask"))
        #expect(header.contains("Needs input"))
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

    @Test func timelineFollowsPaneOwnedLiveTailIntent() throws {
        let shell = try shellSource()
        let timelineCall = try sourceSlice(
            named: "MacSessionTimelineView(",
            until: ".frame(",
            in: shell
        )
        #expect(timelineCall.contains("presentation: presentation"))

        let timeline = try contents(of: "OppiMac/Views/MacSessionTimelineViews.swift")
        #expect(timeline.contains("var presentation: MacSessionPanePresentationState?"))
        #expect(timeline.contains("presentation?.isLiveTailAttached"))
        #expect(timeline.contains("presentation.isLiveTailAttached = attached"))
        #expect(!timeline.contains("@State private var isAttachedToLatestRow"))
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

    @Test func restorationSurfaceNamesPendingOfflineAndRetry() throws {
        let source = try paneDeckSource()
        let restoration = try sourceSlice(
            named: "private func restorationChrome(_ message: String) -> some View {",
            until: "private var paneHeader: some View {",
            in: source
        )
        #expect(restoration.contains("Opening this session"))
        #expect(restoration.contains("Retry"))
        #expect(restoration.contains("mac.session.pane.restoration.retry"))
        #expect(restoration.contains("mac.session.pane.restoration.pending"))
        #expect(restoration.contains("mac.session.pane.restoration.disconnected"))
        #expect(restoration.contains("mac.session.pane.restoration.unavailable"))
        #expect(restoration.contains("showsRetry"))
    }

    @Test @MainActor func nestedThreePaneDragAndShrinkKeepNonnegativeReachableChrome() async throws {
        let deck = MacSessionPaneDeck()
        let windowSize = MacSessionPaneMeasuredSize(width: 1_320, height: 800)
        deck.noteWindowSize(windowSize)
        _ = try #require(deck.openOrFocus(chromeTarget(sessionID: "session-a")))
        _ = try #require(deck.splitFocusedRight(with: chromeTarget(sessionID: "session-b")))
        _ = try #require(deck.splitFocusedRight(with: chromeTarget(sessionID: "session-c")))
        #expect(deck.paneCount == 3)

        let host = NSHostingView(rootView: chromeDeckView(deck: deck))
        let window = offscreenWindow(hosting: host, size: NSSize(width: 1_320, height: 800))
        defer { tearDownOffscreen(window) }
        flush(host)

        let splitIDs = chromeSplitIDs(deck.root)
        #expect(splitIDs.count == 2)
        // Fractions are set on the layout model, not claimed as divider gestures.
        for splitID in splitIDs {
            for fraction in [0.05, 0.95] {
                #expect(deck.setFraction(fraction, for: splitID))
                flush(host)
                try assertNonnegativeDescendantFrames(host)
                try assertEachPaneCloseAndComposerReachable(host, paneCount: 3)
            }
        }

        host.frame = NSRect(x: 0, y: 0, width: 400, height: 360)
        window.setContentSize(NSSize(width: 400, height: 360))
        deck.noteWindowSize(MacSessionPaneMeasuredSize(width: 400, height: 360))
        flush(host)
        try assertNonnegativeDescendantFrames(host)
        try assertEachPaneCloseAndComposerReachable(host, paneCount: 3)

        host.frame = NSRect(x: 0, y: 0, width: 1_320, height: 800)
        window.setContentSize(NSSize(width: 1_320, height: 800))
        deck.noteWindowSize(windowSize)
        flush(host)
        try assertNonnegativeDescendantFrames(host)
        try assertEachPaneCloseAndComposerReachable(host, paneCount: 3)
    }
}

@Suite("Mac session pane commands")
struct MacSessionPaneCommandTests {
    @Test @MainActor func paneCommandsStayOffHiddenHomeDeckIncludingStatsOnly() throws {
        #expect(
            MacSessionPaneCommandAvailability.isDeckDisplayed(
                section: .sessionHome,
                homeDetail: .none
            )
        )
        #expect(
            !MacSessionPaneCommandAvailability.isDeckDisplayed(
                section: .agents,
                homeDetail: .none
            )
        )
        #expect(
            !MacSessionPaneCommandAvailability.isDeckDisplayed(
                section: .workspaces,
                homeDetail: .none
            )
        )
        #expect(
            !MacSessionPaneCommandAvailability.isDeckDisplayed(
                section: .settings,
                homeDetail: .none
            )
        )
        let stats = StatsActiveSession(
            id: "runtime-only",
            status: "busy",
            model: "test/model",
            cost: 0,
            name: "runtime-only",
            firstMessage: nil,
            workspaceName: "Oppi",
            thinkingLevel: nil,
            contextTokens: nil,
            contextWindow: nil,
            createdAt: nil
        )
        #expect(
            !MacSessionPaneCommandAvailability.isDeckDisplayed(
                section: .sessionHome,
                homeDetail: .statsOnly(stats)
            )
        )

        let deck = MacSessionPaneDeck()
        deck.noteWindowSize(MacSessionPaneMeasuredSize(width: 1_200, height: 800))
        let runtime = try #require(deck.openOrFocus(chromeTarget(sessionID: "session-a")))
        runtime.composerState.draft = "Keep this draft"
        let paneID = runtime.id
        let commands = MacSessionPaneCommandCenter(deck: deck)
        commands.isDeckDisplayed = false

        #expect(!commands.canClosePane)
        #expect(!commands.canSplit)
        commands.perform(.closePane)
        commands.perform(.splitRight)
        #expect(deck.runtime(for: paneID) === runtime)
        #expect(runtime.composerState.draft == "Keep this draft")
        #expect(deck.paneCount == 1)

        commands.isDeckDisplayed = true
        #expect(commands.canClosePane)
        commands.perform(.splitRight)
        #expect(deck.paneCount == 2)
    }

    @Test func mainWindowWiresRecordLookupAndUnpublishesHiddenPaneCommands() throws {
        let main = try contents(of: "OppiMac/Views/MainWindowView.swift")
        #expect(main.contains("unresolvedRestoredRoute: .lookup"))
        #expect(main.contains("getSessionRecord(sessionId:"))
        #expect(main.contains("resolvePendingRestoredSessions"))
        #expect(main.contains("fromSessionRecord"))
        #expect(main.contains("MacSessionRestorationCatalog.retryDisconnected"))
        #expect(main.contains("retryDisconnectedRestoration("))
        #expect(main.contains("paneID: paneID"))
        #expect(main.contains("MacSessionRestorationCatalog.apply"))
        #expect(main.contains("onAccepted:"))
        #expect(main.contains("publishAccepted([target]"))
        #expect(main.contains("isPaneDeckDisplayed ? paneCommands : nil"))
    }

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
        deck.noteWindowSize(MacSessionPaneMeasuredSize(width: 1_200, height: 800))
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
        deck.noteWindowSize(MacSessionPaneMeasuredSize(width: 1_200, height: 800))
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
private func offscreenWindow(hosting host: NSView, size: NSSize) -> NSWindow {
    host.frame = NSRect(origin: .zero, size: size)
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
    return window
}

@MainActor
private func tearDownOffscreen(_ window: NSWindow) {
    window.orderOut(nil)
    window.contentView = nil
    window.close()
}

@MainActor
private func flush(_ host: NSView) {
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
}

private func chromeSplitIDs(_ node: MacSessionPaneNode?) -> [MacSessionPaneSplitID] {
    guard case .split(let split) = node else { return [] }
    return [split.id] + chromeSplitIDs(split.first) + chromeSplitIDs(split.second)
}

@MainActor
private func assertNonnegativeDescendantFrames(_ root: NSView) throws {
    var stack = [root]
    while let view = stack.popLast() {
        #expect(view.frame.width >= -0.001)
        #expect(view.frame.height >= -0.001)
        stack.append(contentsOf: view.subviews)
    }
}

@MainActor
private func assertEachPaneCloseAndComposerReachable(_ root: NSView, paneCount: Int) throws {
    let closeButtons = chromeIdentifiedViews(root, identifier: "mac.session.pane.close")
    let composers = chromeDescendants(of: root, type: MacComposerPasteTextView.self)
    if closeButtons.count != paneCount {
        let buttons = chromeDescendants(of: root, type: NSButton.self)
        let descriptions = buttons.map { button -> String in
            let identifier = button.accessibilityIdentifier() ?? ""
            let label = button.accessibilityLabel() ?? ""
            let tip = button.toolTip ?? ""
            return "id=\(identifier) label=\(label) title=\(button.title) tip=\(tip)"
        }.joined(separator: " | ")
        Issue.record("close controls \(closeButtons.count)/\(paneCount); NSButtons: \(descriptions)")
    }
    #expect(closeButtons.count == paneCount)
    #expect(composers.count == paneCount)
    let reachableControls: [NSView] = closeButtons + composers
    for control in reachableControls {
        revealOverflowIfNeeded(control)
        #expect(control.bounds.width > 0)
        #expect(control.bounds.height > 0)
        let windowPoint = control.convert(
            NSPoint(x: control.bounds.midX, y: control.bounds.midY),
            to: nil
        )
        let hit = control.window?.contentView?.hitTest(windowPoint)
        if let hit {
            #expect(hit === control || hit.isDescendant(of: control) || control.isDescendant(of: hit))
        }
    }
}

@MainActor
private func chromeIdentifiedViews(_ root: NSView, identifier: String) -> [NSView] {
    var matches: [NSView] = []
    var stack = [root]
    while let view = stack.popLast() {
        if chromeMatchesIdentifier(view, identifier: identifier) {
            matches.append(view)
        }
        stack.append(contentsOf: view.subviews)
    }
    return matches
}

@MainActor
private func chromeMatchesIdentifier(_ view: NSView, identifier: String) -> Bool {
    if view.identifier?.rawValue == identifier { return true }
    if view.accessibilityIdentifier() == identifier { return true }
    let label = view.accessibilityLabel() ?? ""
    if identifier == "mac.session.pane.close",
       label.localizedCaseInsensitiveContains("close"),
       label.localizedCaseInsensitiveContains("pane")
    {
        return true
    }
    if identifier == "mac.session.pane.close",
       (view as? NSButton)?.toolTip?.contains("Close Pane") == true
    {
        return true
    }
    if identifier == "mac.session.pane.close",
       (view.accessibilityHelp() ?? "").localizedCaseInsensitiveContains("Close Pane")
    {
        return true
    }
    if identifier == "mac.session.pane.close",
       let button = view as? NSButton,
       button.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       (button.accessibilityLabel() ?? "").isEmpty
    {
        return true
    }
    return false
}

@MainActor
private func revealOverflowIfNeeded(_ control: NSView) {
    var ancestor: NSView? = control.superview
    while let view = ancestor {
        if let scroll = view as? NSScrollView {
            let target = scroll.documentView ?? scroll.contentView
            let rect = control.convert(control.bounds, to: target)
            target.scrollToVisible(rect)
            control.window?.layoutIfNeeded()
            control.layoutSubtreeIfNeeded()
            return
        }
        ancestor = view.superview
    }
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
