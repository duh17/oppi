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

    @Test func visibleStripCollectorFindsOnscreenNativeAudioStrip() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let strip = NativeAudioPlayerStripView(frame: CGRect(x: 12, y: 40, width: 296, height: 64))
        strip.apply(
            itemID: "voice-visible",
            title: "Reply",
            durationSeconds: 4,
            audioPlayer: nil,
            showsTitle: true,
            isUnavailable: false,
            onPlay: {},
            onExpand: {}
        )
        root.addSubview(strip)

        let ids = InAppNowPlayingChrome.visibleStripItemIDs(
            in: root,
            unobstructedRect: root.bounds
        )
        #expect(ids == ["voice-visible"])
    }

    @Test func visibleStripCollectorIgnoresCoveredNativeAudioStrip() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let strip = NativeAudioPlayerStripView(frame: CGRect(x: 12, y: 360, width: 296, height: 64))
        strip.apply(
            itemID: "voice-covered",
            title: "Reply",
            durationSeconds: 4,
            audioPlayer: nil,
            showsTitle: true,
            isUnavailable: false,
            onPlay: {},
            onExpand: {}
        )
        root.addSubview(strip)

        let unobstructed = CGRect(x: 0, y: 0, width: 320, height: 300)
        let ids = InAppNowPlayingChrome.visibleStripItemIDs(
            in: root,
            unobstructedRect: unobstructed
        )
        #expect(ids.isEmpty)
    }
}
