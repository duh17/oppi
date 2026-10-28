import Foundation
import UIKit
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

/// The Message capsule's state: which width it takes, whether the mic shows, and what each
/// tap runs. The size class comes from a window, as a bar's would.
@Suite("Session inbox Message capsule")
@MainActor
final class SessionInboxMessageCapsuleTests {
    private var retainedWindows: [UIWindow] = []

    private final class Taps {
        var starts = 0
        var dictations = 0
    }

    private func capsule(
        _ content: SessionInboxMessageCapsule.Content,
        sizeClass: UIUserInterfaceSizeClass = .compact,
        taps: Taps = Taps()
    ) -> SessionInboxMessageCapsule {
        let capsule = SessionInboxMessageCapsule(
            content: content,
            onStart: { taps.starts += 1 },
            onDictate: { taps.dictations += 1 }
        )
        // The size class reaches a view through its window, as a bar's would.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 100))
        window.traitOverrides.horizontalSizeClass = sizeClass
        window.addSubview(capsule)
        retainedWindows.append(window)
        return capsule
    }

    @Test func compactWidthTakesTheColumnMinusTheFolderReserveAndRegularWidthFitsItsContent() {
        let content = SessionInboxMessageCapsule.Content(showsDictation: true, columnWidth: 393)
        let reserve = SessionInboxComposeChrome.messageCapsuleFolderReserve

        let compact = capsule(content, sizeClass: .compact)
        #expect(compact.intrinsicContentSize.width == 393 - reserve)
        #expect(compact.intrinsicContentSize.height == SessionInboxComposeChrome.compactBarHitHeight)

        let regular = capsule(content, sizeClass: .regular)
        let natural = regular.intrinsicContentSize.width
        #expect(natural > SessionInboxComposeChrome.compactBarMicWidth)
        #expect(natural < 393 - reserve, "A regular-width capsule hugs its mic and placeholder")
    }

    @Test func nowPlayingSharingTheBarAndDroppedMicShrinkTheCapsule() {
        let idle = SessionInboxMessageCapsule.Content(showsDictation: true, columnWidth: 393)
        let compactWidth = capsule(idle).intrinsicContentSize.width

        var playing = idle
        playing.hasActivePlayback = true
        #expect(capsule(playing).intrinsicContentSize.width < compactWidth, "Now playing keeps the capsule intrinsic")

        var narrow = SessionInboxMessageCapsule.Content(showsDictation: true, columnWidth: 100)
        #expect(
            capsule(narrow).intrinsicContentSize.width == SessionInboxComposeChrome.messageCapsuleMinWidthFloor,
            "The capsule never shrinks below its floor"
        )
        narrow.hasActivePlayback = true
        let withMic = capsule(narrow, sizeClass: .regular).intrinsicContentSize.width
        narrow.showsDictation = false
        let withoutMic = capsule(narrow, sizeClass: .regular).intrinsicContentSize.width
        #expect(withMic - withoutMic == SessionInboxComposeChrome.compactBarMicWidth - 16, "The mic's slot replaces the leading padding")
    }

    @Test func applyingNewContentRemeasuresTheCapsule() {
        let capsule = capsule(SessionInboxMessageCapsule.Content(showsDictation: true, columnWidth: 300))
        let before = capsule.intrinsicContentSize.width
        capsule.apply(SessionInboxMessageCapsule.Content(showsDictation: true, columnWidth: 400), palette: nil)
        #expect(capsule.intrinsicContentSize.width == before + 100)
    }

    @Test func theMicShowsOnlyWhileDictationIsAvailableAndTheCustomActionFollowsIt() {
        let taps = Taps()
        let capsule = capsule(SessionInboxMessageCapsule.Content(showsDictation: true, columnWidth: 393), taps: taps)
        capsule.layoutIfNeeded()
        let mic = capsule.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "workspace.quickSession.dictate" }
        #expect(mic?.isHidden == false)
        #expect(capsule.accessibilityCustomActions?.map(\.name) == ["Dictate Quick Session"])

        // Live Voice owns the microphone: no mic, and no Dictate action to refuse.
        capsule.apply(SessionInboxMessageCapsule.Content(showsDictation: false, columnWidth: 393), palette: nil)
        #expect(mic?.isHidden == true)
        #expect(capsule.accessibilityCustomActions == nil)
    }

    @Test func tapsAndAccessibilityRunTheirOwnActionAndKeepTheIdentifiers() throws {
        let taps = Taps()
        let capsule = capsule(SessionInboxMessageCapsule.Content(showsDictation: true, columnWidth: 393), taps: taps)
        capsule.layoutIfNeeded()

        #expect(capsule.accessibilityIdentifier == "workspace.quickSession.start")
        #expect(capsule.accessibilityLabel == "Start Quick Session")
        #expect(capsule.isAccessibilityElement)

        capsule.sendActions(for: .touchUpInside)
        #expect(taps.starts == 1 && taps.dictations == 0)

        let mic = try #require(capsule.subviews.compactMap { $0 as? UIButton }.first)
        mic.sendActions(for: .touchUpInside)
        #expect(taps.starts == 1 && taps.dictations == 1, "The mic dictates and does not start a plain session")

        let action = try #require(capsule.accessibilityCustomActions?.first)
        _ = action.actionHandler?(action)
        #expect(taps.dictations == 2)
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
