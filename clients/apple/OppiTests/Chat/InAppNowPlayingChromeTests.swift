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

    @Test func nowPlayingTitleUsesFileNameNotSessionTitle() {
        #expect(
            AudioPlayerService.nowPlayingDisplayTitle(
                fileURL: URL(fileURLWithPath: "/tmp/clips/continue-96cbb6f6.wav")
            ) == "continue-96cbb6f6.wav"
        )
        #expect(
            AudioPlayerService.nowPlayingDisplayTitle(
                mediaURL: URL(string: "https://oppi.local/workspaces/ws/raw/music/bridge.m4a")
            ) == "bridge.m4a"
        )
        #expect(
            AudioPlayerService.nowPlayingDisplayTitle(
                mediaURL: URL(string: "https://oppi.local/files/raw?path=%2FUsers%2Fchen%2Fvoice-memo.wav")
            ) == "voice-memo.wav"
        )
        #expect(
            AudioPlayerService.nowPlayingDisplayTitle(embedName: "lyrics/chorus.mp3") == "chorus.mp3"
        )
        #expect(AudioPlayerService.nowPlayingDisplayTitle() == "Voice reply")
        #expect(AudioPlayerService.nowPlayingDisplayTitle(embedName: "   ") == "Voice reply")
        #expect(
            AudioPlayerService.nowPlayingDisplayTitle(
                mediaURL: URL(string: "https://oppi.local/sessions/abc/attachments/96cbb6f6-rest")
            ) == "Voice reply"
        )
    }

    @Test func nowPlayingPresentationFallsBackToVoiceReplyInsteadOfSessionTitle() {
        let player = AudioPlayerService()
        player.setSessionContext(
            makeTestSession(
                id: "96cbb6f6-rest-of-session",
                name: "continue 96cbb6f6…",
                model: "openai/o4-mini"
            )
        )
        player._setPlaybackStateForTesting(playing: "voice-1", loading: nil)

        let presentation = player.nowPlayingPresentation
        #expect(presentation?.sessionID == "96cbb6f6-rest-of-session")
        #expect(presentation?.title == "Voice reply")
        #expect(presentation?.subtitle == "o4-mini")
    }

    @Test func nowPlayingPresentationUsesStoredFileName() {
        let player = AudioPlayerService()
        player.setSessionContext(
            makeTestSession(
                id: "session-file",
                name: "continue 96cbb6f6",
                model: "openai/o4-mini"
            )
        )
        player._setPlaybackStateForTesting(playing: "file-1", loading: nil)
        player._setNowPlayingItemTitleForTesting("bridge.m4a")

        #expect(player.nowPlayingPresentation?.title == "bridge.m4a")
    }

    @Test func envelopeFromSamplesFollowsActualPeaks() {
        var samples = [Float](repeating: 0, count: 70)
        for index in 30..<40 {
            samples[index] = 0.95
        }
        let levels = AudioPlayerService.envelopeLevels(fromSamples: samples)

        #expect(levels.count == AudioPlayerService.waveformBarCount)
        #expect(levels.allSatisfy { $0 >= 0 && $0 <= 1 })
        let peakIndex = levels.enumerated().max { $0.element < $1.element }?.offset
        #expect(peakIndex == 3)
        #expect(levels[3] > levels[0])
        #expect(levels[3] > levels[6])
    }

    @Test func playheadWindowTracksTheCurrentAudioSlice() {
        var envelope = [Float](repeating: 0.05, count: 100)
        for index in 50..<60 {
            envelope[index] = 0.9
        }

        let loud = AudioPlayerService.playheadEnvelopeWindow(
            envelope: envelope,
            currentTime: 5.5,
            duration: 10,
            windowDuration: 1
        )
        let quiet = AudioPlayerService.playheadEnvelopeWindow(
            envelope: envelope,
            currentTime: 0.4,
            duration: 10,
            windowDuration: 1
        )

        #expect(loud.count == AudioPlayerService.waveformBarCount)
        #expect(quiet.count == AudioPlayerService.waveformBarCount)
        #expect((loud.max() ?? 0) > (quiet.max() ?? 0))
    }

    @Test func pausedWaveformFreezesCurrentEnvelope() {
        let snapshot: [Float] = [0.2, 0.4, 0.8, 1, 0.7, 0.3, 0.18]
        let expectedRest = Array(
            repeating: AudioPlayerService.restingWaveformLevel,
            count: AudioPlayerService.waveformBarCount
        )
        let paused = InAppNowPlayingChrome.displayedWaveformLevels(
            snapshot: snapshot,
            isPlaying: false,
            isPaused: true,
            reduceMotion: false
        )
        let pausedReduceMotion = InAppNowPlayingChrome.displayedWaveformLevels(
            snapshot: snapshot,
            isPlaying: false,
            isPaused: true,
            reduceMotion: true
        )
        let idle = InAppNowPlayingChrome.displayedWaveformLevels(
            snapshot: snapshot,
            isPlaying: false,
            isPaused: false,
            reduceMotion: false
        )

        #expect(AudioPlayerService.waveformBarCount == 7)
        #expect(paused == snapshot)
        #expect(pausedReduceMotion == snapshot)
        #expect(idle == expectedRest)
    }

    @Test func displayedWaveformDoesNotAddSineMotion() {
        let snapshot: [Float] = [0.22, 0.31, 0.74, 0.95, 0.66, 0.28, 0.19]
        let first = InAppNowPlayingChrome.displayedWaveformLevels(
            snapshot: snapshot,
            isPlaying: true,
            isPaused: false,
            reduceMotion: false
        )
        let later = InAppNowPlayingChrome.displayedWaveformLevels(
            snapshot: snapshot,
            isPlaying: true,
            isPaused: false,
            reduceMotion: false
        )
        let reduced = InAppNowPlayingChrome.displayedWaveformLevels(
            snapshot: snapshot,
            isPlaying: true,
            isPaused: false,
            reduceMotion: true
        )

        #expect(first == snapshot)
        #expect(later == snapshot)
        #expect(reduced == snapshot)
        #expect(first == later)
    }

    @Test func reduceMotionWithoutEnvelopeUsesStaticSilhouette() {
        let empty: [Float] = []
        let reduced = InAppNowPlayingChrome.displayedWaveformLevels(
            snapshot: empty,
            isPlaying: true,
            isPaused: false,
            reduceMotion: true
        )
        #expect(reduced == InAppNowPlayingChrome.reducedMotionPlayingLevels)
        #expect(Set(reduced).count >= 4)
    }

    @Test func chatTitleTapExpandsAndDoubleTapOpensFullscreen() {
        #expect(InAppNowPlayingChrome.titleAction(tapCount: 1, expandsOnTap: true) == .expandOrCollapse)
        #expect(InAppNowPlayingChrome.titleAction(tapCount: 2, expandsOnTap: true) == .openFullScreen)
        #expect(InAppNowPlayingChrome.titleAction(tapCount: 1, expandsOnTap: false) == .openFullScreen)
        #expect(InAppNowPlayingChrome.titleAction(tapCount: 3, expandsOnTap: true) == nil)
    }

    @Test func meterMappingClampsToUnitInterval() {
        #expect(AudioPlayerService.normalizedMeterLevel(fromAveragePower: 0) == 1)
        #expect(AudioPlayerService.normalizedMeterLevel(fromAveragePower: 12) == 1)
        #expect(AudioPlayerService.normalizedMeterLevel(fromAveragePower: -160) == 0)
        #expect(AudioPlayerService.normalizedMeterLevel(fromAveragePower: -.infinity) == 0)
        #expect(AudioPlayerService.normalizedMeterLevel(fromAveragePower: .nan) == 0)

        let mid = AudioPlayerService.normalizedMeterLevel(fromAveragePower: -25)
        #expect(mid > 0 && mid < 1)

        let overflow = AudioPlayerService.envelopeLevels(fromSamples: [2.4, -1.2, 0.5])
        #expect(overflow.count == AudioPlayerService.waveformBarCount)
        #expect(overflow.allSatisfy { $0 >= 0 && $0 <= 1 })
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
