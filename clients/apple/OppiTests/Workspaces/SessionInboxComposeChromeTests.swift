import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("Session inbox compose chrome")
struct SessionInboxComposeChromeTests {
    @Test func allSessionsShowsDictationWhenVoiceIsOnAndIdle() {
        #expect(
            SessionInboxComposeChrome.showsDictationShortcut(
                voiceInputEnabled: true,
                hasActivePlayback: false
            )
        )
    }

    @Test func hidesDictationWhenVoiceIsOff() {
        #expect(
            !SessionInboxComposeChrome.showsDictationShortcut(
                voiceInputEnabled: false,
                hasActivePlayback: false
            )
        )
    }

    @Test func workspaceListShowsDictationWhenVoiceIsOnAndIdle() {
        #expect(
            SessionInboxComposeChrome.showsDictationShortcut(
                voiceInputEnabled: true,
                hasActivePlayback: false
            )
        )
    }

    @Test func hidesDictationWhileNowPlayingOwnsTheBar() {
        #expect(
            !SessionInboxComposeChrome.showsDictationShortcut(
                voiceInputEnabled: true,
                hasActivePlayback: true
            )
        )
    }

    @Test func folderIsEnabledWhenAServerIsConnected() {
        #expect(SessionInboxComposeChrome.canOpenFiles(hasServer: true))
        #expect(!SessionInboxComposeChrome.canOpenFiles(hasServer: false))
    }

    @Test func allSessionsFolderOpensHostHomeBrowser() throws {
        let inbox = try appleSource("Oppi/Features/Workspaces/SessionInboxView.swift")
        #expect(inbox.contains("SessionInboxComposeChrome.canOpenFiles(hasServer: activeServerId != nil)"))
        #expect(inbox.contains("FileBrowserNavTarget.hostHome(serverId: activeServerId)"))
        #expect(!inbox.contains("canOpenWorkspaceFiles"))
        #expect(!inbox.contains("guard let workspaceTarget else { return }"))
    }

    @Test func inboxWiresSharedCapsulesInsteadOfCreateNowPencil() throws {
        let inbox = try appleSource("Oppi/Features/Workspaces/SessionInboxView.swift")
        let workspace = try appleSource("Oppi/Features/Workspaces/WorkspaceDetailView.swift")
        let chrome = try appleSource("Oppi/Features/Workspaces/SessionInboxComposeChrome.swift")
        let sheet = try appleSource("Oppi/Features/QuickSession/QuickSessionSheet.swift")
        #expect(inbox.contains("compactQuickSessionBar"))
        #expect(inbox.contains("SessionInboxCompactComposeBar"))
        #expect(inbox.contains("inboxFolderButton"))
        #expect(inbox.contains("pendingQuickSessionStartDictation = true"))
        #expect(workspace.contains("compactQuickSessionBar"))
        #expect(workspace.contains("SessionInboxCompactComposeBar"))
        #expect(workspace.contains("SessionInboxFolderToolbarButton"))
        #expect(workspace.contains("onIncognito"))
        #expect(chrome.contains("Incognito Session"))
        #expect(chrome.contains("workspace.quickSession.dictate"))
        #expect(chrome.contains("workspace.quickSession.start"))
        #expect(chrome.contains("workspace.files.open"))
        #expect(chrome.contains("Dictate Quick Session"))
        #expect(chrome.contains("Start Quick Session"))
        #expect(chrome.contains(SessionInboxComposeChrome.compactBarPlaceholder))
        #expect(!chrome.contains("glassEffect"))
        #expect(!inbox.contains("sharedBackgroundVisibility"))
        #expect(!inbox.contains("dictationQuickSessionButton"))
        #expect(!inbox.contains("square.and.pencil"))
        #expect(!inbox.contains("workspace.newSession"))
        #expect(!workspace.contains("square.and.pencil"))
        #expect(!workspace.contains("workspace.newSession"))
        #expect(!inbox.contains("ToolbarSpacer(.fixed, placement: .bottomBar)"))
        #expect(!workspace.contains("ToolbarSpacer(.fixed, placement: .bottomBar)"))
        #expect(sheet.contains("composerDictationRequestID += 1"))
        #expect(sheet.contains("externalDictationRequestID: composerDictationRequestID"))
        #expect(sheet.contains("afterComposerReady"))
        #expect(!sheet.contains("startInboxDictation"))
        #expect(!sheet.contains(".constant("))
        let pendingRange = try #require(sheet.range(of: "let pendingDictation = navigation.pendingQuickSessionStartDictation"))
        let loadRange = try #require(sheet.range(of: "await composerDraftStore.load()"))
        #expect(pendingRange.lowerBound < loadRange.lowerBound)
        let dismiss = try appleSource("Oppi/App/ContentView.swift")
        #expect(dismiss.contains("pendingQuickSessionStartDictation = false"))
        let bar = try appleSource("Oppi/Features/Chat/Composer/ChatInputBar.swift")
        #expect(bar.contains(".task(id: externalDictationRequestID)"))
        #expect(bar.contains("startExternalDictationIfRequested"))
        #expect(bar.contains("VoiceInputOwner.inboxComposer") || bar.contains("owner: .inboxComposer"))
        #expect(sheet.contains(".onDisappear"))
        #expect(sheet.contains("cancelVoiceInputOnDismiss"))
        #expect(sheet.contains("VoiceInputManager.shared"))
        #expect(!sheet.contains("VoiceInputManager()"))
        let chat = try appleSource("Oppi/Features/Chat/ChatView.swift")
        #expect(chat.contains("VoiceInputManager.shared"))
        #expect(!chat.contains("VoiceInputManager()"))
        let control = try appleSource("Oppi/Features/ControlSessions/GuidedControlSessionComposer.swift")
        #expect(control.contains("VoiceInputManager.shared"))
        #expect(!control.contains("VoiceInputManager()"))
        let preview = try appleSource("Oppi/App/ScreenshotPreviewView.swift")
        #expect(preview.contains("SessionInboxCompactComposeBar"))
        #expect(preview.contains("SessionInboxFolderToolbarButton"))
        #expect(!preview.contains("sharedBackgroundVisibility"))
        #expect(!preview.contains("square.and.pencil"))
    }

    @Test func workspaceStartQuickSessionPassesSelectedWorktreeIdIntoLaunchContext() throws {
        let workspace = try appleSource("Oppi/Features/Workspaces/WorkspaceDetailView.swift")
        let start = try sourceSlice(
            workspace,
            start: "private func startQuickSession(dictate: Bool) {",
            end: "private var workspaceConfigurationButton"
        )
        let context = try sourceSlice(
            start,
            start: "QuickSessionLaunchContext(",
            end: "navigation.showQuickSession"
        )
        #expect(context.contains("worktreeId: selectedWorktreeId"))
        #expect(!context.contains("worktreeId: nil"))
        #expect(!start.contains("worktreeId: nil"))
    }

    @Test func sessionListsKeepFolderOnlyLeadingCapsuleWithoutBottomSearch() throws {
        let inbox = try appleSource("Oppi/Features/Workspaces/SessionInboxView.swift")
        let workspace = try appleSource("Oppi/Features/Workspaces/WorkspaceDetailView.swift")
        let chrome = try appleSource("Oppi/Features/Workspaces/SessionInboxComposeChrome.swift")
        let preview = try appleSource("Oppi/App/ScreenshotPreviewView.swift")
        let nowPlaying = try appleSource("Oppi/Features/Chat/Support/InAppNowPlayingChrome.swift")
        let drawer = "placement: .navigationBarDrawer(displayMode: .automatic)"
        let bottomSearch = "DefaultToolbarItem(kind: .search, placement: .bottomBar)"

        #expect(inbox.contains("inboxFolderButton"))
        #expect(inbox.contains("SessionInboxFolderToolbarButton"))
        #expect(workspace.contains("SessionInboxFolderToolbarButton"))
        #expect(preview.contains("SessionInboxFolderToolbarButton"))
        #expect(chrome.contains("workspace.files.open"))

        for source in [inbox, workspace, preview] {
            #expect(source.contains(drawer))
            #expect(!source.contains(".searchToolbarBehavior(.minimize)"))
            #expect(!source.contains(bottomSearch))
            #expect(!source.contains("keepsSystemSearchToolbarItem"))
        }

        #expect(!chrome.contains("grouped with"))
        #expect(!chrome.contains("system search toolbar item"))
        #expect(!nowPlaying.contains("keepsSystemSearchToolbarItem"))
        #expect(!nowPlaying.contains("Search stays a leading"))
    }

    @Test func disabledFolderUsesUnavailableForegroundInTheSameCapsule() throws {
        let chrome = try appleSource("Oppi/Features/Workspaces/SessionInboxComposeChrome.swift")
        let buttonStart = try #require(chrome.range(of: "struct SessionInboxFolderToolbarButton: View {"))
        let button = String(chrome[buttonStart.lowerBound...])
        #expect(button.contains("isEnabled ? .themeFg : .themeFgDim"))
        #expect(button.contains(".disabled(!isEnabled)"))
        #expect(!button.contains(".foregroundStyle(.themeFg)"))
        #expect(!button.contains(".hidden("))
    }

    @Test func expandsTrailingCapsuleOnPhoneAndCompactPadWhenIdle() {
        #expect(
            SessionInboxComposeChrome.expandsTrailingCapsule(
                horizontalSizeClass: .compact,
                idiom: .phone,
                hasActivePlayback: false
            )
        )
        #expect(
            SessionInboxComposeChrome.expandsTrailingCapsule(
                horizontalSizeClass: .regular,
                idiom: .phone,
                hasActivePlayback: false
            )
        )
        #expect(
            SessionInboxComposeChrome.expandsTrailingCapsule(
                horizontalSizeClass: .compact,
                idiom: .pad,
                hasActivePlayback: false
            )
        )
        #expect(
            SessionInboxComposeChrome.expandsTrailingCapsule(
                horizontalSizeClass: nil,
                idiom: .phone,
                hasActivePlayback: false
            )
        )
    }

    @Test func doesNotExpandTrailingCapsuleOnRegularPad() {
        #expect(
            !SessionInboxComposeChrome.expandsTrailingCapsule(
                horizontalSizeClass: .regular,
                idiom: .pad,
                hasActivePlayback: false
            )
        )
    }

    @Test func doesNotExpandTrailingCapsuleWhileNowPlayingOwnsTheBar() {
        #expect(
            !SessionInboxComposeChrome.expandsTrailingCapsule(
                horizontalSizeClass: .compact,
                idiom: .phone,
                hasActivePlayback: true
            )
        )
        #expect(
            !SessionInboxComposeChrome.expandsTrailingCapsule(
                horizontalSizeClass: .compact,
                idiom: .pad,
                hasActivePlayback: true
            )
        )
        #expect(
            !SessionInboxComposeChrome.expandsTrailingCapsule(
                horizontalSizeClass: .regular,
                idiom: .pad,
                hasActivePlayback: true
            )
        )
    }

    @Test func trailingCapsuleMinWidthUsesReserveAndFloorWhenExpanded() {
        let reserve = SessionInboxComposeChrome.trailingCapsuleFolderReserve
        let floor = SessionInboxComposeChrome.trailingCapsuleMinWidthFloor

        #expect(reserve > 0)
        #expect(floor > 0)
        #expect(
            SessionInboxComposeChrome.trailingCapsuleMinWidth(
                screenWidth: 393,
                expands: true
            ) == max(floor, 393 - reserve)
        )
        #expect(
            SessionInboxComposeChrome.trailingCapsuleMinWidth(
                screenWidth: 320,
                expands: true
            ) == max(floor, 320 - reserve)
        )
        #expect(
            SessionInboxComposeChrome.trailingCapsuleMinWidth(
                screenWidth: floor + reserve - 40,
                expands: true
            ) == floor
        )
        #expect(
            SessionInboxComposeChrome.trailingCapsuleMinWidth(
                screenWidth: 0,
                expands: true
            ) == floor
        )
    }

    @Test func trailingCapsuleMinWidthIsNilWhenNotExpanded() {
        #expect(
            SessionInboxComposeChrome.trailingCapsuleMinWidth(
                screenWidth: 393,
                expands: false
            ) == nil
        )
        #expect(
            SessionInboxComposeChrome.trailingCapsuleMinWidth(
                screenWidth: 1024,
                expands: false
            ) == nil
        )
    }

    @Test func bothSessionListToolbarsUseSharedTrailingCapsulePolicy() throws {
        let chrome = try appleSource("Oppi/Features/Workspaces/SessionInboxComposeChrome.swift")
        let inbox = try appleSource("Oppi/Features/Workspaces/SessionInboxView.swift")
        let workspace = try appleSource("Oppi/Features/Workspaces/WorkspaceDetailView.swift")
        let inboxBar = try sourceSlice(
            inbox,
            start: "private var compactQuickSessionBar: some View {",
            end: "private var inboxIncognitoAction"
        )
        let workspaceBar = try sourceSlice(
            workspace,
            start: "private var compactQuickSessionBar: some View {",
            end: "private func startQuickSession(dictate: Bool)"
        )

        #expect(chrome.contains("static func expandsTrailingCapsule("))
        #expect(chrome.contains("static func trailingCapsuleMinWidth("))
        #expect(chrome.contains("trailingCapsuleFolderReserve"))
        #expect(chrome.contains("trailingCapsuleMinWidthFloor"))
        #expect(chrome.contains("horizontalSizeClass == .regular && idiom == .pad"))
        #expect(chrome.contains("width: minWidth"))
        #expect(!chrome.contains("Spacer(minLength:"))
        #expect(!chrome.contains(".infinity"))
        #expect(inboxBar.contains("hasActivePlayback: sessionListHasActivePlayback"))
        #expect(inboxBar.contains("columnWidth: composeBarColumnWidth"))
        #expect(workspaceBar.contains("hasActivePlayback: connection.audioPlayer.hasActivePlayback"))
        #expect(workspaceBar.contains("columnWidth: composeBarColumnWidth"))
        #expect(inbox.contains("ToolbarSpacer(.flexible, placement: .bottomBar)"))
        #expect(workspace.contains("ToolbarSpacer(.flexible, placement: .bottomBar)"))
        #expect(!inbox.contains("ToolbarSpacer(.fixed, placement: .bottomBar)"))
        #expect(!workspace.contains("ToolbarSpacer(.fixed, placement: .bottomBar)"))
    }
}

@Suite("Session inbox search scope")
struct SessionInboxSearchScopeTests {
    @Test func allSessionsSearchOmitsWorkspaceId() {
        #expect(SessionInboxSearchScope.workspaceId(scopedTo: nil) == nil)
        #expect(SessionInboxSearchScope.workspaceId(scopedTo: "") == nil)
        #expect(SessionInboxSearchScope.workspaceId(scopedTo: "   ") == nil)
    }

    @Test func workspaceListSearchKeepsWorkspaceId() {
        #expect(SessionInboxSearchScope.workspaceId(scopedTo: "ws-1") == "ws-1")
        #expect(SessionInboxSearchScope.workspaceId(scopedTo: "  ws-1  ") == "ws-1")
    }

    @Test func workspaceScopeChangeRefreshesTheCurrentSearch() throws {
        let inbox = try appleSource("Oppi/Features/Workspaces/SessionInboxView.swift")
        let observer = try sourceSlice(
            inbox,
            start: ".onChange(of: selectedWorkspace?.workspace.id)",
            end: ".toolbar { toolbarContent }"
        )
        #expect(observer.contains("refreshSearch()"))
        let refresh = try sourceSlice(inbox, start: "private func refreshSearch()", end: "private var")
        #expect(refresh.contains("query: searchText"))
        #expect(refresh.contains("scopedTo: selectedWorkspace?.workspace.id"))
    }

    @Test func listsPassSearchScopeIntoTheStore() throws {
        let inbox = try appleSource("Oppi/Features/Workspaces/SessionInboxView.swift")
        let workspace = try appleSource("Oppi/Features/Workspaces/WorkspaceDetailView.swift")
        #expect(inbox.contains("SessionInboxSearchScope.workspaceId("))
        #expect(inbox.contains("scopedTo: selectedWorkspace?.workspace.id"))
        #expect(workspace.contains("SessionInboxSearchScope.workspaceId(scopedTo: workspace.id)"))
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

private func sourceSlice(_ source: String, start: String, end: String) throws -> String {
    guard let startRange = source.range(of: start) else {
        Issue.record("Missing source start \(start)")
        throw SourceSliceError.missingMarker(start)
    }
    guard let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
        Issue.record("Missing source end \(end)")
        throw SourceSliceError.missingMarker(end)
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

private enum SourceSliceError: Error {
    case missingMarker(String)
}
