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
}

@Suite("Quick Session launcher coverage")
struct QuickSessionLauncherCoverageTests {
    private let thread = SessionThreadNavTarget(serverId: "srv", rootSessionId: "root")
    private let chat = WorkspaceSessionNavTarget(serverId: "srv", sessionId: "chat")

    /// A chat after the owning route hides Message. Removing that chat shows it.
    /// A missing owner stays covered: the live path count is not the depth.
    @Test func routeElementsCoverTheLauncherUntilTheChatIsRemoved() {
        let stackCases: [(String, [WorkspaceStackRouteElement])] = [
            ("thread + chat", [.sessionThread(thread), .session(chat)]),
            ("utility + thread + chat", [.utility(.agents), .sessionThread(thread), .session(chat)]),
        ]
        for (name, covered) in stackCases {
            expectCovered(name, presentation: .stack, stack: covered, covered: true)
            expectCovered(
                "\(name) without chat",
                presentation: .stack,
                stack: Array(covered.dropLast()),
                covered: false
            )
        }
        expectCovered(
            "split thread + chat",
            presentation: .split,
            path: [.sessionThread(thread), .session(chat)],
            covered: true
        )
        expectCovered("split thread", presentation: .split, path: [.sessionThread(thread)], covered: false)

        expectCovered("missing thread", presentation: .stack, stack: [.session(chat)], covered: true)
        expectCovered("missing split thread", presentation: .split, path: [.session(chat)], covered: true)
    }

    private func expectCovered(
        _ name: String,
        presentation: WorkspaceNavigationPresentation,
        stack: [WorkspaceStackRouteElement] = [],
        path: [WorkspaceSplitDetailPathElement] = [],
        covered: Bool
    ) {
        #expect(
            QuickSessionLauncherCoverage.isCovered(
                presentation: presentation,
                thread: thread,
                workspaceStack: stack,
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
