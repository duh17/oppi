import Foundation
import Testing
@testable import Oppi

@Suite("Session inbox compose chrome")
struct SessionInboxComposeChromeTests {
    @Test func allSessionsShowsDictationWhenVoiceIsOnAndIdle() {
        #expect(
            SessionInboxComposeChrome.showsDictationShortcut(
                voiceInputEnabled: true,
                hasSelectedWorkspace: false,
                hasActivePlayback: false
            )
        )
    }

    @Test func hidesDictationWhenVoiceIsOff() {
        #expect(
            !SessionInboxComposeChrome.showsDictationShortcut(
                voiceInputEnabled: false,
                hasSelectedWorkspace: false,
                hasActivePlayback: false
            )
        )
    }

    @Test func hidesDictationOnWorkspaceScopedInbox() {
        #expect(
            !SessionInboxComposeChrome.showsDictationShortcut(
                voiceInputEnabled: true,
                hasSelectedWorkspace: true,
                hasActivePlayback: false
            )
        )
    }

    @Test func hidesDictationWhileNowPlayingOwnsTheBar() {
        #expect(
            !SessionInboxComposeChrome.showsDictationShortcut(
                voiceInputEnabled: true,
                hasSelectedWorkspace: false,
                hasActivePlayback: true
            )
        )
    }

    @Test func inboxWiresDictationShortcutNextToCompose() throws {
        let inbox = try appleSource("Oppi/Features/Workspaces/SessionInboxView.swift")
        let sheet = try appleSource("Oppi/Features/QuickSession/QuickSessionSheet.swift")
        #expect(inbox.contains("workspace.quickSession.dictate"))
        #expect(inbox.contains("pendingQuickSessionStartDictation = true"))
        #expect(inbox.contains("dictationQuickSessionButton"))
        #expect(inbox.contains("Dictate Quick Session"))
        #expect(sheet.contains("composerDictationRequestID += 1"))
        #expect(sheet.contains("externalDictationRequestID: composerDictationRequestID"))
        #expect(sheet.contains("afterComposerReady"))
        #expect(!sheet.contains("startInboxDictation"))
        #expect(!sheet.contains(".constant("))
        let pendingRange = try #require(sheet.range(of: "let pendingDictation = navigation.pendingQuickSessionStartDictation"))
        let loadRange = try #require(sheet.range(of: "await composerDraftStore.load()"))
        #expect(pendingRange.lowerBound < loadRange.lowerBound)
        let pencil = inbox.range(of: "private var newSessionButton")
            .map { inbox[$0.lowerBound...] }
            .map(String.init) ?? ""
        #expect(!pencil.contains("pendingQuickSessionStartDictation"))
        let dismiss = try appleSource("Oppi/App/ContentView.swift")
        #expect(dismiss.contains("pendingQuickSessionStartDictation = false"))
        let bar = try appleSource("Oppi/Features/Chat/Composer/ChatInputBar.swift")
        #expect(bar.contains(".task(id: externalDictationRequestID)"))
        #expect(bar.contains("startExternalDictationIfRequested"))
        #expect(bar.contains("VoiceInputOwner.inboxComposer") || bar.contains("owner: .inboxComposer"))
    }
}

@Suite("Quick Session dictation launch")
struct QuickSessionDictationLaunchTests {
    @Test func autoStartsOnlyWhenPendingReadyAndEnabled() {
        #expect(
            QuickSessionDictationLaunch.shouldAutoStartDictation(
                pendingStart: true,
                voiceInputEnabled: true,
                isComposerReady: true
            )
        )
        #expect(
            !QuickSessionDictationLaunch.shouldAutoStartDictation(
                pendingStart: false,
                voiceInputEnabled: true,
                isComposerReady: true
            )
        )
        #expect(
            !QuickSessionDictationLaunch.shouldAutoStartDictation(
                pendingStart: true,
                voiceInputEnabled: false,
                isComposerReady: true
            )
        )
        #expect(
            !QuickSessionDictationLaunch.shouldAutoStartDictation(
                pendingStart: true,
                voiceInputEnabled: true,
                isComposerReady: false
            )
        )
    }

    @Test func micSkipsTypingFocusAndPencilKeepsIt() {
        #expect(
            QuickSessionDictationLaunch.afterComposerReady(
                pendingStart: true,
                voiceInputEnabled: true
            ) == .startDictation
        )
        #expect(
            QuickSessionDictationLaunch.afterComposerReady(
                pendingStart: false,
                voiceInputEnabled: true
            ) == .focusForTyping
        )
        #expect(
            QuickSessionDictationLaunch.afterComposerReady(
                pendingStart: true,
                voiceInputEnabled: false
            ) == .focusForTyping
        )
    }
}

private func appleSource(_ relativePath: String) throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: relativePath)
    return try String(contentsOf: sourceURL, encoding: .utf8)
}
