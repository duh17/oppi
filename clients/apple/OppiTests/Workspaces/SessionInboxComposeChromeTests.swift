import Foundation
import SwiftUI
import Testing
@testable import Oppi

@Suite("Session inbox compose chrome")
struct SessionInboxComposeChromeTests {
    @Test func showsDictationWhenIdle() {
        #expect(
            SessionInboxComposeChrome.showsDictationShortcut(
                hasActivePlayback: false
            )
        )
    }

    @Test func hidesDictationWhileNowPlayingOwnsTheBar() {
        #expect(
            !SessionInboxComposeChrome.showsDictationShortcut(
                hasActivePlayback: true
            )
        )
    }

    @Test func folderIsEnabledWhenAServerIsConnected() {
        #expect(SessionInboxComposeChrome.canOpenFiles(hasServer: true))
        #expect(!SessionInboxComposeChrome.canOpenFiles(hasServer: false))
    }

    @Test func disabledFolderUsesUnavailableForegroundInTheSameCapsule() throws {
        let chrome = try appleSource("Oppi/Features/Workspaces/SessionInboxComposeChrome.swift")
        let button = try sourceSlice(
            chrome,
            start: "struct SessionInboxFolderToolbarButton: View {",
            end: "struct SessionInboxNowPlayingRailButton: View {"
        )
        #expect(button.contains("isEnabled ? .themeFg : .themeFgDim"))
        #expect(button.contains(".disabled(!isEnabled)"))
        #expect(!button.contains(".foregroundStyle(.themeFg)"))
        #expect(!button.contains(".hidden("))
    }

    @Test func expandsMessageCapsuleAtCompactOrUnknownWidthWhenIdle() {
        #expect(SessionInboxComposeChrome.expandsMessageCapsule(horizontalSizeClass: .compact, hasActivePlayback: false))
        #expect(SessionInboxComposeChrome.expandsMessageCapsule(horizontalSizeClass: nil, hasActivePlayback: false))
    }

    /// Regular width covers iPad and the iPhone Duo inner display alike.
    @Test func doesNotExpandMessageCapsuleAtRegularWidth() {
        #expect(!SessionInboxComposeChrome.expandsMessageCapsule(horizontalSizeClass: .regular, hasActivePlayback: false))
    }

    @Test func doesNotExpandMessageCapsuleWhileNowPlayingOwnsTheBar() {
        #expect(!SessionInboxComposeChrome.expandsMessageCapsule(horizontalSizeClass: .compact, hasActivePlayback: true))
        #expect(!SessionInboxComposeChrome.expandsMessageCapsule(horizontalSizeClass: .regular, hasActivePlayback: true))
    }

    @Test func messageCapsuleMinWidthUsesReserveAndFloorWhenExpanded() {
        let reserve = SessionInboxComposeChrome.messageCapsuleFolderReserve
        let floor = SessionInboxComposeChrome.messageCapsuleMinWidthFloor

        #expect(reserve > 0)
        #expect(floor > 0)
        #expect(
            SessionInboxComposeChrome.messageCapsuleMinWidth(
                screenWidth: 393,
                expands: true
            ) == max(floor, 393 - reserve)
        )
        #expect(
            SessionInboxComposeChrome.messageCapsuleMinWidth(
                screenWidth: 320,
                expands: true
            ) == max(floor, 320 - reserve)
        )
        #expect(
            SessionInboxComposeChrome.messageCapsuleMinWidth(
                screenWidth: floor + reserve - 40,
                expands: true
            ) == floor
        )
        #expect(
            SessionInboxComposeChrome.messageCapsuleMinWidth(
                screenWidth: 0,
                expands: true
            ) == floor
        )
    }

    @Test func messageCapsuleMinWidthIsNilWhenNotExpanded() {
        #expect(
            SessionInboxComposeChrome.messageCapsuleMinWidth(
                screenWidth: 393,
                expands: false
            ) == nil
        )
        #expect(
            SessionInboxComposeChrome.messageCapsuleMinWidth(
                screenWidth: 1024,
                expands: false
            ) == nil
        )
    }

    @Test func compactComposeBarPlacesMicLeadingLikeChatInput() throws {
        let chrome = try appleSource("Oppi/Features/Workspaces/SessionInboxComposeChrome.swift")
        let bar = try sourceSlice(
            chrome,
            start: "struct SessionInboxCompactComposeBar: View {",
            end: "struct SessionInboxFolderToolbarButton: View {"
        )
        let expanded = try sourceSlice(bar, start: "if let minWidth {", end: "} else {")
        let compact = try sourceSlice(bar, start: "} else {", end: ".accessibilityLabel(\"Start Quick Session\")")
        let expandedMic = try #require(expanded.range(of: "dictationMic"))
        let expandedLabel = try #require(expanded.range(of: "placeholderLabel"))
        let compactMic = try #require(compact.range(of: "dictationMic"))
        let compactLabel = try #require(compact.range(of: "placeholderLabel"))

        #expect(expandedMic.lowerBound < expandedLabel.lowerBound)
        #expect(compactMic.lowerBound < compactLabel.lowerBound)
        #expect(bar.contains(".padding(.leading, showsDictation ? 0 : 16)"))
        #expect(bar.contains(".padding(.trailing, 16)"))
    }
}

@Suite("Quick Session launcher coverage")
struct QuickSessionLauncherCoverageTests {
    private let thread = SessionThreadNavTarget(serverId: "srv", rootSessionId: "root")
    private let chat = WorkspaceSessionNavTarget(serverId: "srv", sessionId: "chat")

    /// A chat after the owning route hides Message. Removing that chat shows it.
    /// A missing owner stays covered: the live path count is not the depth.
    @Test func routeElementsCoverTheLauncherUntilTheChatIsRemoved() {
        let stackCases: [(String, [WorkspaceStackRouteElement], QuickSessionLauncherSurface)] = [
            ("thread + chat", [.sessionThread(thread), .session(chat)], .thread(thread)),
            (
                "utility + thread + chat",
                [.utility(.agents), .sessionThread(thread), .session(chat)],
                .thread(thread)
            ),
        ]
        for (name, covered, surface) in stackCases {
            expectCovered(name, presentation: .stack, stack: covered, surface: surface, covered: true)
            expectCovered(
                "\(name) without chat",
                presentation: .stack,
                stack: Array(covered.dropLast()),
                surface: surface,
                covered: false
            )
        }
        expectCovered(
            "split thread + chat",
            presentation: .split,
            path: [.sessionThread(thread), .session(chat)],
            surface: .thread(thread),
            covered: true
        )
        expectCovered(
            "split thread",
            presentation: .split,
            path: [.sessionThread(thread)],
            surface: .thread(thread),
            covered: false
        )
        expectCovered(
            "split utility + thread + chat",
            presentation: .split,
            detail: .utility(.agents),
            path: [.sessionThread(thread), .session(chat)],
            surface: .thread(thread),
            covered: true
        )
        expectCovered(
            "split utility + thread",
            presentation: .split,
            detail: .utility(.agents),
            path: [.sessionThread(thread)],
            surface: .thread(thread),
            covered: false
        )

        expectCovered(
            "missing thread",
            presentation: .stack,
            stack: [.session(chat)],
            surface: .thread(thread),
            covered: true
        )
        expectCovered(
            "missing split thread",
            presentation: .split,
            path: [.session(chat)],
            surface: .thread(thread),
            covered: true
        )

        expectCovered("all sessions", presentation: .stack, stack: [], surface: .allSessions, covered: false)
        expectCovered(
            "all sessions + chat",
            presentation: .stack,
            stack: [.session(chat)],
            surface: .allSessions,
            covered: true
        )
        expectCovered(
            "all sessions replaced in split",
            presentation: .split,
            detail: .session(chat),
            path: [],
            surface: .allSessions,
            covered: true
        )
        expectCovered(
            "all sessions split root",
            presentation: .split,
            path: [],
            surface: .allSessions,
            covered: false
        )
    }

    private func expectCovered(
        _ name: String,
        presentation: WorkspaceNavigationPresentation,
        stack: [WorkspaceStackRouteElement] = [],
        detail: WorkspaceSplitDetailTarget? = nil,
        path: [WorkspaceSplitDetailPathElement] = [],
        surface: QuickSessionLauncherSurface,
        covered: Bool
    ) {
        #expect(
            QuickSessionLauncherCoverage.isCovered(
                presentation: presentation,
                surface: surface,
                workspaceStack: stack,
                splitDetailTarget: detail,
                splitDetailElements: path
            ) == covered,
            "\(name)"
        )
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
}

@Suite("Quick Session dictation launch")
struct QuickSessionDictationLaunchTests {
    @Test func autoStartsOnlyWhenPendingAndReady() {
        #expect(
            QuickSessionDictationLaunch.shouldAutoStartDictation(
                pendingStart: true,
                isComposerReady: true
            )
        )
        #expect(
            !QuickSessionDictationLaunch.shouldAutoStartDictation(
                pendingStart: false,
                isComposerReady: true
            )
        )
        #expect(
            !QuickSessionDictationLaunch.shouldAutoStartDictation(
                pendingStart: true,
                isComposerReady: false
            )
        )
    }

    @Test func micSkipsTypingFocusAndPencilKeepsIt() {
        #expect(
            QuickSessionDictationLaunch.afterComposerReady(
                pendingStart: true
            ) == .startDictation
        )
        #expect(
            QuickSessionDictationLaunch.afterComposerReady(
                pendingStart: false
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
