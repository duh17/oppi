import AppKit
import SwiftUI
import Testing
@testable import Oppi

@Suite("Mac session command availability")
struct MacSessionCommandAvailabilityTests {
    @Test func absentOrHiddenSessionDisablesEveryCommand() {
        let hiddenHome = MacSessionCommandAvailability.evaluate(
            input(visible: false, status: .ready, hasDraft: true, canSendMessage: true)
        )
        let noSession = MacSessionCommandAvailability.evaluate(
            input(visible: false, status: nil, hasDraft: false, canSendMessage: false)
        )
        #expect(hiddenHome == .inactive)
        #expect(noSession == .inactive)
        for kind in MacSessionCommandKind.allCases {
            #expect(!hiddenHome.isEnabled(kind))
            #expect(!noSession.isEnabled(kind))
        }
    }

    @Test func idleDraftEnablesSendNotStop() {
        let availability = MacSessionCommandAvailability.evaluate(
            input(visible: true, status: .ready, hasDraft: true, canSendMessage: true)
        )
        #expect(availability.send)
        #expect(!availability.stopTurn)
        #expect(!availability.resume)
        #expect(availability.panels)
    }

    @Test func idleEmptyDisablesSend() {
        let availability = MacSessionCommandAvailability.evaluate(
            input(visible: true, status: .ready, hasDraft: false, canSendMessage: true)
        )
        #expect(!availability.send)
        #expect(!availability.stopTurn)
        #expect(availability.panels)
    }

    @Test func stagedReviewCommentsEnableSendWithoutADraft() {
        var values = input(visible: true, status: .ready, hasDraft: false, canSendMessage: true)
        values.hasStagedReviewComments = true
        let availability = MacSessionCommandAvailability.evaluate(values)
        #expect(availability.send)
        #expect(!availability.stopTurn)
    }

    @Test func busyEmptyEnablesStopTurnNotSend() {
        let availability = MacSessionCommandAvailability.evaluate(
            input(visible: true, status: .busy, hasDraft: false, canSendMessage: true)
        )
        #expect(!availability.send)
        #expect(availability.stopTurn)
        #expect(!availability.resume)
        #expect(MacSessionWindowChrome.composerStopKind() == .abortTurn)
        #expect(MacSessionWindowChrome.composerStopKind() != .stopSessionProcess)
    }

    @Test func busyDraftKeepsSendInsteadOfStop() {
        let availability = MacSessionCommandAvailability.evaluate(
            input(visible: true, status: .busy, hasDraft: true, canSendMessage: true)
        )
        #expect(availability.send)
        #expect(!availability.stopTurn)
    }

    @Test func busyAttachmentsEnableSend() {
        var values = input(visible: true, status: .busy, hasDraft: false, canSendMessage: true)
        values.hasAttachments = true
        let availability = MacSessionCommandAvailability.evaluate(values)
        #expect(availability.send)
        #expect(!availability.stopTurn)
    }

    @Test func askCardsDoNotMorphSendIntoStop() {
        var values = input(visible: true, status: .busy, hasDraft: false, canSendMessage: true)
        values.hasAskRequest = true
        let availability = MacSessionCommandAvailability.evaluate(values)
        #expect(!availability.send)
        #expect(!availability.stopTurn)
        #expect(availability.panels)
    }

    @Test func sendingInFlightDisablesSend() {
        var values = input(visible: true, status: .busy, hasDraft: true, canSendMessage: false)
        values.isSending = true
        let availability = MacSessionCommandAvailability.evaluate(values)
        #expect(!availability.send)
        #expect(!availability.stopTurn)
    }

    @Test func loadingDisablesComposerActionsAndKeepsPanels() {
        var values = input(visible: true, status: .ready, hasDraft: true, canSendMessage: true)
        values.isLoading = true
        let availability = MacSessionCommandAvailability.evaluate(values)
        #expect(!availability.send)
        #expect(!availability.stopTurn)
        #expect(!availability.resume)
        #expect(availability.panels)
    }

    @Test func errorSurfaceDisablesComposerActionsAndKeepsPanels() {
        let availability = MacSessionCommandAvailability.evaluate(
            input(visible: true, status: .error, hasDraft: true, canSendMessage: false)
        )
        #expect(!availability.send)
        #expect(!availability.stopTurn)
        #expect(!availability.resume)
        #expect(availability.panels)
    }

    @Test func stoppingDisablesSendStopAndResume() {
        let availability = MacSessionCommandAvailability.evaluate(
            input(visible: true, status: .stopping, hasDraft: true, canSendMessage: false)
        )
        #expect(!availability.send)
        #expect(!availability.stopTurn)
        #expect(!availability.resume)
        #expect(availability.panels)
    }

    @Test func stoppedSessionEnablesResume() {
        let availability = MacSessionCommandAvailability.evaluate(
            input(visible: true, status: .stopped, hasDraft: false, canSendMessage: false)
        )
        #expect(!availability.send)
        #expect(!availability.stopTurn)
        #expect(availability.resume)
        #expect(availability.panels)
    }

    @Test func resumeInFlightDisablesResume() {
        var values = input(visible: true, status: .stopped, hasDraft: false, canSendMessage: false)
        values.isResuming = true
        let availability = MacSessionCommandAvailability.evaluate(values)
        #expect(!availability.resume)
        #expect(availability.panels)
    }

    @Test func onlySendUsesCommandReturnAndEscapeStaysUnbound() {
        #expect(MacSessionCommandKind.send.keyboardShortcut == .return)
        #expect(MacSessionCommandKind.send.keyboardShortcutModifiers == .command)
        for kind in MacSessionCommandKind.allCases where kind != .send {
            #expect(kind.keyboardShortcut == nil)
        }
        #expect(MacSessionCommandKind.stopTurn.keyboardShortcut != .escape)
        #expect(MacSessionCommandKind.allCases.map(\.menuTitle) == [
            "Send", "Stop Turn", "Resume", "Files", "Session Outline", "Context",
        ])
    }

    private func input(
        visible: Bool,
        status: SessionStatus?,
        hasDraft: Bool,
        canSendMessage: Bool
    ) -> MacSessionCommandAvailability.Input {
        MacSessionCommandAvailability.Input(
            isSessionVisible: visible,
            status: status,
            isLoading: false,
            hasDraft: hasDraft,
            hasAttachments: false,
            hasStagedReviewComments: false,
            canSendMessage: canSendMessage,
            isSending: false,
            isStoppingTurn: false,
            isResuming: false,
            hasAskRequest: false
        )
    }
}

@Suite("Mac session command focused values", .serialized)
@MainActor
struct MacSessionCommandFocusedValueTests {
    @Test func testHostSessionMenuIsDisabledWithoutAMountedSession() throws {
        NSApp.mainMenu?.update()
        for kind in MacSessionCommandKind.allCases {
            let item = try #require(
                MacAppMenuInspection.item(titled: kind.menuTitle, in: NSApp.mainMenu),
                "missing \(kind.menuTitle)"
            )
            #expect(!item.isEnabled, "\(kind.menuTitle) should be disabled with no mounted session")
        }
    }

    @Test func isolatedPublisherAThenBRoutesToTheCurrentSession() {
        let fixture = IsolatedSessionCommandFixture()
        let probe = MacSessionCommandProbeBox()
        MacSessionCommandHost.run(IsolatedSessionCommandTree(fixture: fixture, probe: probe)) { host, _ in
            MacSessionCommandHost.waitUntil("session A stop") { probe.stopEnabled && !probe.sendEnabled }
            probe.send?.perform()
            probe.stopTurn?.perform()

            fixture.sessionID = "sess-b"
            fixture.sendEnabled = true
            fixture.stopEnabled = false
            host.rootView = IsolatedSessionCommandTree(fixture: fixture, probe: probe)
            MacSessionCommandHost.waitUntil("session B send") {
                probe.sendEnabled && !probe.stopEnabled
            }
            probe.send?.perform()
            probe.stopTurn?.perform()
            probe.files?.perform()
        }

        #expect(fixture.log == ["sess-a stop", "sess-b send", "sess-b files"])
    }

    @Test func unmountingThePublisherDropsStaleActions() {
        let fixture = IsolatedSessionCommandFixture()
        let probe = MacSessionCommandProbeBox()
        MacSessionCommandHost.run(IsolatedSessionCommandTree(fixture: fixture, probe: probe)) { host, _ in
            MacSessionCommandHost.waitUntil("mounted stop") { probe.stopEnabled }
            fixture.isMounted = false
            host.rootView = IsolatedSessionCommandTree(fixture: fixture, probe: probe)
            MacSessionCommandHost.waitUntil("unmounted") { probe.send == nil && probe.stopTurn == nil }
            probe.send?.perform()
            probe.files?.perform()
        }
        #expect(fixture.log == [])
    }

    @Test func productionComposerPublishesSendThenStopAfterSwitchingSessions() {
        let store = MacSessionTraceStore()
        store.select(macCommandTarget(id: "sess-a", status: .ready))
        let probe = MacSessionCommandProbeBox()
        MacSessionCommandHost.run(
            ProductionComposerCommandTree(store: store, draft: "hello", probe: probe),
            size: NSSize(width: 720, height: 280)
        ) { host, _ in
            MacSessionCommandHost.waitUntil("ready draft send") { probe.sendEnabled && !probe.stopEnabled }
            #expect(probe.resumeEnabled == false)

            store.select(macCommandTarget(id: "sess-b", status: .busy))
            host.rootView = ProductionComposerCommandTree(store: store, draft: "", probe: probe)
            MacSessionCommandHost.waitUntil("busy empty stop") { probe.stopEnabled && !probe.sendEnabled }

            store.clearSelection()
            host.rootView = ProductionComposerCommandTree(store: store, draft: "", probe: probe)
            MacSessionCommandHost.waitUntil("cleared session") {
                probe.send == nil && !probe.sendEnabled && !probe.stopEnabled && !probe.resumeEnabled
            }
        }
    }

    @Test func disabledStopTurnDoesNotInvokeItsAction() {
        let fixture = IsolatedSessionCommandFixture()
        fixture.sendEnabled = false
        fixture.stopEnabled = false
        fixture.resumeEnabled = true
        let probe = MacSessionCommandProbeBox()
        MacSessionCommandHost.run(IsolatedSessionCommandTree(fixture: fixture, probe: probe)) { _, _ in
            MacSessionCommandHost.waitUntil("resume") { probe.resumeEnabled }
            probe.stopTurn?.perform()
            probe.resume?.perform()
        }
        #expect(fixture.log == ["sess-a resume"])
        #expect(MacSessionWindowChrome.composerStopKind() == .abortTurn)
    }
}

@MainActor
@Observable
final class IsolatedSessionCommandFixture {
    var sessionID = "sess-a"
    var isMounted = true
    var sendEnabled = false
    var stopEnabled = true
    var resumeEnabled = false
    var panelsEnabled = true
    var log: [String] = []
}

@MainActor
final class MacSessionCommandProbeBox {
    var sendEnabled = false
    var stopEnabled = false
    var resumeEnabled = false
    var filesEnabled = false
    var outlineEnabled = false
    var contextEnabled = false
    var send: MacSessionCommandItem?
    var stopTurn: MacSessionCommandItem?
    var resume: MacSessionCommandItem?
    var files: MacSessionCommandItem?
    var outline: MacSessionCommandItem?
    var context: MacSessionCommandItem?
}

private struct IsolatedSessionCommandTree: View {
    var fixture: IsolatedSessionCommandFixture
    var probe: MacSessionCommandProbeBox

    var body: some View {
        IsolatedSessionCommandPublisher(fixture: fixture)
            .overlay {
                MacSessionCommandFocusProbe(probe: probe)
            }
    }
}

private struct IsolatedSessionCommandPublisher: View {
    var fixture: IsolatedSessionCommandFixture

    var body: some View {
        Group {
            if fixture.isMounted {
                Color.clear
                    .frame(width: 8, height: 8)
                    .focusedSceneValue(\.macSessionSendCommand, item(enabled: fixture.sendEnabled, label: "send"))
                    .focusedSceneValue(\.macSessionStopTurnCommand, item(enabled: fixture.stopEnabled, label: "stop"))
                    .focusedSceneValue(\.macSessionResumeCommand, item(enabled: fixture.resumeEnabled, label: "resume"))
                    .focusedSceneValue(\.macSessionFilesCommand, item(enabled: fixture.panelsEnabled, label: "files"))
                    .focusedSceneValue(\.macSessionOutlineCommand, item(enabled: fixture.panelsEnabled, label: "outline"))
                    .focusedSceneValue(\.macSessionContextCommand, item(enabled: fixture.panelsEnabled, label: "context"))
            } else {
                Color.clear.frame(width: 8, height: 8)
            }
        }
    }

    private func item(enabled: Bool, label: String) -> MacSessionCommandItem? {
        let sessionID = fixture.sessionID
        return MacSessionCommandItem(enabled: enabled) {
            fixture.log.append("\(sessionID) \(label)")
        }
    }
}

private struct ProductionComposerCommandTree: View {
    let store: MacSessionTraceStore
    let draft: String
    var probe: MacSessionCommandProbeBox
    @FocusState private var focus: KeybindingFocus?

    var body: some View {
        MacSessionComposerBar(
            store: store,
            sessionFocus: $focus,
            initialDraft: draft
        )
        .id(store.selectedTarget?.sessionId)
        .environment(\.theme, AppTheme.dark)
        .environment(\.themeID, ThemeID.dark)
        .preferredColorScheme(.dark)
        .overlay {
            MacSessionCommandFocusProbe(probe: probe)
        }
    }
}

private struct MacSessionCommandFocusProbe: View {
    var probe: MacSessionCommandProbeBox
    @FocusedValue(\.macSessionSendCommand) private var send
    @FocusedValue(\.macSessionStopTurnCommand) private var stopTurn
    @FocusedValue(\.macSessionResumeCommand) private var resume
    @FocusedValue(\.macSessionFilesCommand) private var files
    @FocusedValue(\.macSessionOutlineCommand) private var outline
    @FocusedValue(\.macSessionContextCommand) private var context

    var body: some View {
        let _ = capture()
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityIdentifier("mac.test.sessionCommandProbe")
    }

    private func capture() {
        probe.send = send
        probe.stopTurn = stopTurn
        probe.resume = resume
        probe.files = files
        probe.outline = outline
        probe.context = context
        probe.sendEnabled = send?.enabled ?? false
        probe.stopEnabled = stopTurn?.enabled ?? false
        probe.resumeEnabled = resume?.enabled ?? false
        probe.filesEnabled = files?.enabled ?? false
        probe.outlineEnabled = outline?.enabled ?? false
        probe.contextEnabled = context?.enabled ?? false
    }
}

enum MacSessionCommandHost {
    @MainActor
    static func run<Content: View>(
        _ root: Content,
        size: NSSize = NSSize(width: 640, height: 220),
        work: (NSHostingView<Content>, NSWindow) -> Void
    ) {
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Oppi Session Command Fixture"
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        work(host, window)
    }

    @MainActor
    static func waitUntil(_ description: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(condition(), "Timed out waiting for \(description)")
    }
}

func macCommandTarget(id: String, status: SessionStatus) -> MacSelectedSessionTarget {
    let session = Session(
        id: id,
        workspaceId: "ws-command",
        workspaceName: "Oppi",
        name: "Command \(id)",
        status: status,
        createdAt: Date(timeIntervalSince1970: 1),
        lastActivity: Date(timeIntervalSince1970: 2),
        messageCount: 1,
        tokens: TokenUsage(input: 0, output: 0),
        cost: 0
    )
    return MacSelectedSessionTarget(
        workspaceId: "ws-command",
        sessionId: session.id,
        summary: SessionSummary(from: session)
    )
}

enum MacAppMenuInspection {
    @MainActor
    static func itemTitles(in menu: NSMenu?) -> [String] {
        guard let menu else { return [] }
        return menu.items.flatMap { item -> [String] in
            [item.title] + itemTitles(in: item.submenu)
        }
    }

    @MainActor
    static func item(titled title: String, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.title == title {
                return item
            }
            if let nested = Self.item(titled: title, in: item.submenu) {
                return nested
            }
        }
        return nil
    }

    @MainActor
    static func settingsItem(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        if let byShortcut = commandCommaItem(in: menu) {
            return byShortcut
        }
        for item in menu.items {
            if normalizedTitle(item.title).hasPrefix("Settings") {
                return item
            }
            if let nested = settingsItem(in: item.submenu) {
                return nested
            }
        }
        return nil
    }

    @MainActor
    private static func commandCommaItem(in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.keyEquivalent == ",",
               item.keyEquivalentModifierMask.contains(.command) {
                return item
            }
            if let submenu = item.submenu, let nested = commandCommaItem(in: submenu) {
                return nested
            }
        }
        return nil
    }

    static func normalizedTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "...", with: "…")
    }
}
