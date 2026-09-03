import Testing
import UIKit
@testable import Oppi

@Suite("In-app Now Playing chrome")
@MainActor
struct InAppNowPlayingChromeTests {
    @Test func hidesChatPillWhenPlayingStripIsVisible() {
        #expect(
            !InAppNowPlayingChrome.shouldShowChatPill(
                hasActivePlayback: true,
                playbackItemID: "voice-1",
                visibleStripItemIDs: ["voice-1"]
            )
        )
    }

    @Test func showsChatPillWhenPlayingStripIsNotVisible() {
        #expect(
            InAppNowPlayingChrome.shouldShowChatPill(
                hasActivePlayback: true,
                playbackItemID: "voice-1",
                visibleStripItemIDs: ["other-row"]
            )
        )
    }

    @Test func hidesChatPillWhenIdle() {
        #expect(
            !InAppNowPlayingChrome.shouldShowChatPill(
                hasActivePlayback: false,
                playbackItemID: nil,
                visibleStripItemIDs: []
            )
        )
    }

    @Test func hidesChatPillWhenVoiceStreamPlaybackMatchesVisibleToolStrip() {
        #expect(
            !InAppNowPlayingChrome.shouldShowChatPill(
                hasActivePlayback: true,
                playbackItemID: "audio-stream-tool-voice-1",
                visibleStripItemIDs: ["tool-voice-1"]
            )
        )
        #expect(
            !InAppNowPlayingChrome.shouldShowChatPill(
                hasActivePlayback: true,
                playbackItemID: "stream:tool-voice-1",
                visibleStripItemIDs: ["tool-voice-1"]
            )
        )
    }

    @Test func showsChatPillWhenVoiceStreamPlaybackHasNoMatchingVisibleCell() {
        #expect(
            InAppNowPlayingChrome.shouldShowChatPill(
                hasActivePlayback: true,
                playbackItemID: "audio-stream-tool-voice-1",
                visibleStripItemIDs: ["other-row"]
            )
        )
    }

    @Test func hidesChatPillWhenMarkdownPlaybackItemIsVisible() {
        let embed = MarkdownAudioEmbed(
            reference: ResourceReference(
                target: "clips/reply.wav",
                sourceServerID: "server-1",
                workspaceID: "ws-1",
                sourceSessionID: "session-1",
                fileCandidatePath: "clips/reply.wav"
            )
        )
        let playbackID = AudioPlaybackItemID.markdown(embed: embed, worktreeID: "wt-1")
        #expect(
            !InAppNowPlayingChrome.shouldShowChatPill(
                hasActivePlayback: true,
                playbackItemID: playbackID,
                visibleStripItemIDs: [playbackID]
            )
        )
    }

    @Test func collapsesInboxSearchWhilePlaying() {
        #expect(
            InAppNowPlayingChrome.sessionListToolbar(hasActivePlayback: true)
                == .collapsedSearchWithNowPlaying
        )
    }

    @Test func restoresInboxSearchWhenIdle() {
        #expect(
            InAppNowPlayingChrome.sessionListToolbar(hasActivePlayback: false)
                == .searchField
        )
    }

    @Test func sessionListPillDensityIsTitleOnlyAndNarrowerThanChat() {
        #expect(!InAppNowPlayingChrome.PillDensity.sessionList.showsSubtitle)
        #expect(InAppNowPlayingChrome.PillDensity.sessionList.titleMaxWidth == 120)
        #expect(InAppNowPlayingChrome.PillDensity.sessionList.playPauseHitSize == 44)
        #expect(InAppNowPlayingChrome.PillDensity.chat.showsSubtitle)
        #expect(InAppNowPlayingChrome.PillDensity.chat.titleMaxWidth == 180)
        #expect(InAppNowPlayingChrome.PillDensity.chat.playPauseHitSize == 44)
    }

    @Test func visibleStripCollectorFindsOnscreenNativeAudioStrip() {
        let fixture = nestedAudioStripFixture(
            itemID: "voice-visible",
            stripFrame: CGRect(x: 12, y: 40, width: 296, height: 64)
        )

        let ids = InAppNowPlayingChrome.visibleStripItemIDs(
            from: [fixture.contentView],
            in: fixture.root,
            unobstructedRect: fixture.root.bounds
        )
        #expect(ids == ["voice-visible"])
    }

    @Test func visibleStripCollectorIgnoresCoveredNativeAudioStrip() {
        let fixture = nestedAudioStripFixture(
            itemID: "voice-covered",
            stripFrame: CGRect(x: 12, y: 360, width: 296, height: 64)
        )

        let unobstructed = CGRect(x: 0, y: 0, width: 320, height: 300)
        let ids = InAppNowPlayingChrome.visibleStripItemIDs(
            from: [fixture.contentView],
            in: fixture.root,
            unobstructedRect: unobstructed
        )
        #expect(ids.isEmpty)
    }

    @Test func visibleStripCollectorIgnoresStripIntersectingOnlyBottomOverlapInset() {
        let rootHeight: CGFloat = 400
        let bottomOverlap: CGFloat = 100
        let fixture = nestedAudioStripFixture(
            itemID: "voice-composer-covered",
            rootHeight: rootHeight,
            stripFrame: CGRect(x: 12, y: 320, width: 296, height: 64)
        )
        let unobstructed = fixture.root.bounds.inset(
            by: UIEdgeInsets(top: 0, left: 0, bottom: bottomOverlap, right: 0)
        )

        #expect(fixture.stripFrame.intersects(fixture.root.bounds))
        #expect(!fixture.stripFrame.intersects(unobstructed))

        let ids = InAppNowPlayingChrome.visibleStripItemIDs(
            from: [fixture.contentView],
            in: fixture.root,
            unobstructedRect: unobstructed
        )
        #expect(ids.isEmpty)
    }
}

@MainActor
private struct NestedAudioStripFixture {
    let root: UIView
    let contentView: UIView
    let stripFrame: CGRect
}

@MainActor
private func nestedAudioStripFixture(
    itemID: String,
    rootHeight: CGFloat = 400,
    stripFrame: CGRect
) -> NestedAudioStripFixture {
    let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: rootHeight))
    let cell = UICollectionViewCell(frame: stripFrame)
    cell.contentView.frame = cell.bounds
    let wrapper = UIView(frame: cell.contentView.bounds)
    let strip = NativeAudioPlayerStripView(frame: wrapper.bounds)
    strip.apply(
        itemID: itemID,
        title: "Reply",
        durationSeconds: 4,
        audioPlayer: nil,
        showsTitle: true,
        isUnavailable: false,
        onPlay: {},
        onExpand: {}
    )
    wrapper.addSubview(strip)
    cell.contentView.addSubview(wrapper)
    root.addSubview(cell)
    return NestedAudioStripFixture(
        root: root,
        contentView: cell.contentView,
        stripFrame: stripFrame
    )
}
