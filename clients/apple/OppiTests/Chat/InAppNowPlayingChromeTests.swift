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

    @Test func playingKeepsSystemSearchToolbarItemAndMinimizes() {
        let toolbar = InAppNowPlayingChrome.sessionListToolbar(
            hasActivePlayback: true,
            isSearchPresented: false
        )
        #expect(toolbar.keepsSystemSearchToolbarItem)
        #expect(toolbar.usesMinimizedSearch)
        #expect(toolbar.showsNowPlayingPill)
        #expect(!toolbar.parksNowPlayingNextToCompose)
        #expect(toolbar.pillShowsWaveform)
        #expect(toolbar.avoidsHidingContentWhileSearching)
    }

    @Test func playingSearchParksCompactPlayPauseNextToCompose() {
        let toolbar = InAppNowPlayingChrome.sessionListToolbar(
            hasActivePlayback: true,
            isSearchPresented: true
        )
        #expect(toolbar.keepsSystemSearchToolbarItem)
        #expect(toolbar.usesMinimizedSearch)
        #expect(toolbar.showsNowPlayingPill)
        #expect(toolbar.parksNowPlayingNextToCompose)
        #expect(!toolbar.pillShowsWaveform)
        #expect(toolbar.avoidsHidingContentWhileSearching)
    }

    @Test func idleUsesAutomaticSystemSearchWithoutPill() {
        let toolbar = InAppNowPlayingChrome.sessionListToolbar(
            hasActivePlayback: false,
            isSearchPresented: false
        )
        #expect(toolbar.keepsSystemSearchToolbarItem)
        #expect(!toolbar.usesMinimizedSearch)
        #expect(!toolbar.showsNowPlayingPill)
        #expect(!toolbar.parksNowPlayingNextToCompose)
        #expect(!toolbar.avoidsHidingContentWhileSearching)
    }

    @Test func idleSearchDoesNotShowNowPlaying() {
        let toolbar = InAppNowPlayingChrome.sessionListToolbar(
            hasActivePlayback: false,
            isSearchPresented: true
        )
        #expect(toolbar.keepsSystemSearchToolbarItem)
        #expect(!toolbar.usesMinimizedSearch)
        #expect(!toolbar.showsNowPlayingPill)
        #expect(!toolbar.parksNowPlayingNextToCompose)
    }

    @Test func sessionListPillHidesTitleAndKeepsPlayPauseHit() {
        #expect(!InAppNowPlayingChrome.PillDensity.sessionList.showsTitle)
        #expect(!InAppNowPlayingChrome.PillDensity.sessionList.showsSubtitle)
        #expect(InAppNowPlayingChrome.PillDensity.sessionList.showsWaveform)
        #expect(InAppNowPlayingChrome.PillDensity.sessionList.playPauseHitSize == 44)
        #expect(!InAppNowPlayingChrome.PillDensity.sessionListCompact.showsTitle)
        #expect(!InAppNowPlayingChrome.PillDensity.sessionListCompact.showsSubtitle)
        #expect(!InAppNowPlayingChrome.PillDensity.sessionListCompact.showsWaveform)
        #expect(InAppNowPlayingChrome.PillDensity.sessionListCompact.playPauseHitSize == 44)
        #expect(InAppNowPlayingChrome.PillDensity.chat.showsTitle)
        #expect(!InAppNowPlayingChrome.PillDensity.chat.showsSubtitle)
        #expect(InAppNowPlayingChrome.PillDensity.chat.showsWaveform)
        #expect(InAppNowPlayingChrome.PillDensity.chat.playPauseHitSize == 44)
        #expect(InAppNowPlayingChrome.PillDensity.chat.titleMaxWidth == 180)
    }

    @Test func pausedWaveformBarsAreResting() {
        let paused = AudioPlayerService.waveformLevels(fromMeterLevel: 0.92, isPlaying: false)
        #expect(paused.count == AudioPlayerService.waveformBarCount)
        #expect(paused == Array(repeating: AudioPlayerService.restingWaveformLevel, count: AudioPlayerService.waveformBarCount))

        let playing = AudioPlayerService.waveformLevels(fromMeterLevel: 0.92, isPlaying: true)
        #expect(playing != paused)
        #expect(playing.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func reduceMotionWaveformBarsAreStatic() {
        let quiet = InAppNowPlayingChrome.displayedWaveformLevels(
            snapshot: AudioPlayerService.waveformLevels(fromMeterLevel: 0.2, isPlaying: true),
            isPlaying: true,
            reduceMotion: true
        )
        let loud = InAppNowPlayingChrome.displayedWaveformLevels(
            snapshot: AudioPlayerService.waveformLevels(fromMeterLevel: 0.95, isPlaying: true),
            isPlaying: true,
            reduceMotion: true
        )
        #expect(quiet.count == AudioPlayerService.waveformBarCount)
        #expect(quiet == loud)

        let liveQuiet = InAppNowPlayingChrome.displayedWaveformLevels(
            snapshot: AudioPlayerService.waveformLevels(fromMeterLevel: 0.2, isPlaying: true),
            isPlaying: true,
            reduceMotion: false
        )
        let liveLoud = InAppNowPlayingChrome.displayedWaveformLevels(
            snapshot: AudioPlayerService.waveformLevels(fromMeterLevel: 0.95, isPlaying: true),
            isPlaying: true,
            reduceMotion: false
        )
        #expect(liveQuiet != liveLoud)
    }

    @Test func meterMappingClampsToUnitInterval() {
        #expect(AudioPlayerService.normalizedMeterLevel(fromAveragePower: 0) == 1)
        #expect(AudioPlayerService.normalizedMeterLevel(fromAveragePower: 12) == 1)
        #expect(AudioPlayerService.normalizedMeterLevel(fromAveragePower: -160) == 0)
        #expect(AudioPlayerService.normalizedMeterLevel(fromAveragePower: -.infinity) == 0)
        #expect(AudioPlayerService.normalizedMeterLevel(fromAveragePower: .nan) == 0)

        let mid = AudioPlayerService.normalizedMeterLevel(fromAveragePower: -25)
        #expect(mid > 0 && mid < 1)

        let overflow = AudioPlayerService.waveformLevels(fromMeterLevel: 2.4, isPlaying: true)
        #expect(overflow.count == AudioPlayerService.waveformBarCount)
        #expect(overflow.allSatisfy { $0 >= 0 && $0 <= 1 })

        let underflow = AudioPlayerService.waveformLevels(fromMeterLevel: -1.2, isPlaying: true)
        #expect(underflow.allSatisfy { $0 >= 0 && $0 <= 1 })
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
