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

    @Test func allSessionsUsesCompactBarAndWorkspaceKeepsPencil() {
        #expect(
            SessionInboxComposeChrome.usesCompactQuickSessionBar(
                hasSelectedWorkspace: false
            )
        )
        #expect(
            !SessionInboxComposeChrome.usesCompactQuickSessionBar(
                hasSelectedWorkspace: true
            )
        )
    }

    @Test func inboxWiresCompactBarInsteadOfComposeButton() throws {
        let inbox = try appleSource("Oppi/Features/Workspaces/SessionInboxView.swift")
        let chrome = try appleSource("Oppi/Features/Workspaces/SessionInboxComposeChrome.swift")
        let sheet = try appleSource("Oppi/Features/QuickSession/QuickSessionSheet.swift")
        #expect(inbox.contains("compactQuickSessionBar"))
        #expect(inbox.contains("SessionInboxCompactComposeBar"))
        #expect(inbox.contains("pendingQuickSessionStartDictation = true"))
        #expect(inbox.contains("usesCompactQuickSessionBar"))
        #expect(chrome.contains("workspace.quickSession.dictate"))
        #expect(chrome.contains("workspace.quickSession.start"))
        #expect(chrome.contains("Dictate Quick Session"))
        #expect(chrome.contains("Start Quick Session"))
        #expect(chrome.contains(SessionInboxComposeChrome.compactBarPlaceholder))
        #expect(!chrome.contains("glassEffect"))
        #expect(!inbox.contains("sharedBackgroundVisibility"))
        #expect(!inbox.contains("dictationQuickSessionButton"))
        #expect(inbox.contains("square.and.pencil"))
        #expect(inbox.contains("workspace.newSession"))
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
        #expect(pencil.contains("workspace.newSession"))
        #expect(!pencil.contains("workspace.quickSession.start"))
        let dismiss = try appleSource("Oppi/App/ContentView.swift")
        #expect(dismiss.contains("pendingQuickSessionStartDictation = false"))
        let bar = try appleSource("Oppi/Features/Chat/Composer/ChatInputBar.swift")
        #expect(bar.contains(".task(id: externalDictationRequestID)"))
        #expect(bar.contains("startExternalDictationIfRequested"))
        #expect(bar.contains("VoiceInputOwner.inboxComposer") || bar.contains("owner: .inboxComposer"))
        let preview = try appleSource("Oppi/App/ScreenshotPreviewView.swift")
        #expect(preview.contains("SessionInboxCompactComposeBar"))
        #expect(!preview.contains("sharedBackgroundVisibility"))
        #expect(!preview.contains("square.and.pencil"))
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
