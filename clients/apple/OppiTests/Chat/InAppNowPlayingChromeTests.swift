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

    @Test func pillsUseFilenameWithoutWaveformAndKeepPlayPauseHit() throws {
        #expect(InAppNowPlayingChrome.PillDensity.sessionList.showsTitle)
        #expect(InAppNowPlayingChrome.PillDensity.sessionList.playPauseHitSize == 44)
        #expect(InAppNowPlayingChrome.PillDensity.sessionList.stopHitSize == 44)
        #expect(!InAppNowPlayingChrome.PillDensity.sessionListCompact.showsTitle)
        #expect(InAppNowPlayingChrome.PillDensity.sessionListCompact.playPauseHitSize == 44)
        #expect(InAppNowPlayingChrome.PillDensity.sessionListCompact.stopHitSize == 44)
        #expect(InAppNowPlayingChrome.PillDensity.chat.showsTitle)
        #expect(InAppNowPlayingChrome.PillDensity.chat.playPauseHitSize == 44)
        #expect(InAppNowPlayingChrome.PillDensity.chat.stopHitSize == 44)
        #expect(InAppNowPlayingChrome.PillDensity.chat.titleMaxWidth > 180)
        #expect(InAppNowPlayingChrome.PillDensity.chat.visualHeight == ExtensionStripPillMetrics.visualHeight)

        let source = try nowPlayingChromeSource()
        #expect(!source.contains("InAppNowPlayingWaveform"))
        #expect(!source.contains("waveformLevels"))
    }

    @Test func playbackControlsExposeLoadingAsCancel() {
        #expect(AudioPlaybackControlAction.resolve(
            isLoading: true,
            isActive: false,
            isPaused: false
        ) == .cancelLoading)
        #expect(AudioPlaybackControlAction.resolve(
            isLoading: false,
            isActive: true,
            isPaused: false
        ) == .pause)
        #expect(AudioPlaybackControlAction.resolve(
            isLoading: false,
            isActive: true,
            isPaused: true
        ) == .resume)
        #expect(AudioPlaybackControlAction.resolve(
            isLoading: false,
            isActive: false,
            isPaused: false
        ) == .start)
    }

    @Test func loadingControlIncludesAnExplicitCancelGlyph() {
        #expect(AudioLoadingCancelControl.cancelSymbolName == "xmark")
    }

    @Test func selectedLanguageIsIncludedInThePlaybackRequest() {
        let timedText = TimedText.LoadResult(
            tracks: [
                TimedText.Track(
                    candidate: TimedText.Candidate(
                        fileName: "clip.en.srt",
                        path: "clip.en.srt",
                        format: .srt,
                        language: "en"
                    ),
                    cues: []
                ),
                TimedText.Track(
                    candidate: TimedText.Candidate(
                        fileName: "clip.zh.srt",
                        path: "clip.zh.srt",
                        format: .srt,
                        language: "zh"
                    ),
                    cues: []
                ),
            ],
            selectedIndex: 0
        )

        let selected = AudioLyricsPlayerView.selectedTimedTextForPlayback(
            timedText,
            selectedTrackIndex: 1
        )
        #expect(selected?.selectedIndex == 1)
    }

    @Test func pausedStreamsNeverRestartForIncomingChunks() {
        #expect(!AudioPlayerService.shouldStartStreamNode(isPaused: true, isNodePlaying: false))
        #expect(!AudioPlayerService.shouldStartStreamNode(isPaused: false, isNodePlaying: true))
        #expect(AudioPlayerService.shouldStartStreamNode(isPaused: false, isNodePlaying: false))
    }

    @Test func globalPlayerDismissesWhenPlaybackEnds() {
        #expect(InAppNowPlayingChrome.shouldDismissPlayer(hasActivePlayback: false))
        #expect(!InAppNowPlayingChrome.shouldDismissPlayer(hasActivePlayback: true))
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

    @Test func activePlaybackKeepsTimedTextForExpandedAndFullScreenPlayers() {
        let player = AudioPlayerService()
        player._setPlaybackStateForTesting(playing: "file-1", loading: nil)
        let timedText = TimedText.LoadResult(
            tracks: [
                TimedText.Track(
                    candidate: TimedText.Candidate(
                        fileName: "clip.srt",
                        path: "clip.srt",
                        format: .srt,
                        language: nil
                    ),
                    cues: [TimedText.Cue(text: "Follow me", startTime: 0, endTime: 4)]
                ),
            ],
            selectedIndex: 0
        )

        player.setNowPlayingTimedText(timedText, for: "other-item")
        #expect(player.nowPlayingTimedText == .empty)

        player.setNowPlayingTimedText(timedText, for: "file-1")
        #expect(player.nowPlayingTimedText == timedText)

        player.stop()
        #expect(player.nowPlayingTimedText == .empty)
    }

    @Test func serviceOwnedTimedTextLoadSurvivesItsCaller() async {
        let player = AudioPlayerService()
        player._setPlaybackStateForTesting(playing: nil, loading: "file-1")
        let timedText = TimedText.LoadResult(
            tracks: [
                TimedText.Track(
                    candidate: TimedText.Candidate(
                        fileName: "clip.srt",
                        path: "clip.srt",
                        format: .srt,
                        language: nil
                    ),
                    cues: [TimedText.Cue(text: "Still loading", startTime: 0, endTime: 4)]
                ),
            ],
            selectedIndex: 0
        )

        player.loadNowPlayingTimedText(for: "file-1") {
            try? await Task.sleep(for: .milliseconds(20))
            return timedText
        }
        #expect(player.isNowPlayingTimedTextLoading)
        try? await Task.sleep(for: .milliseconds(60))

        #expect(player.nowPlayingTimedText == timedText)
        #expect(!player.isNowPlayingTimedTextLoading)
    }

    @Test func stoppingPlaybackRejectsLateTimedText() async {
        let player = AudioPlayerService()
        player._setPlaybackStateForTesting(playing: nil, loading: "file-1")
        let timedText = TimedText.LoadResult(
            tracks: [
                TimedText.Track(
                    candidate: TimedText.Candidate(
                        fileName: "late.srt",
                        path: "late.srt",
                        format: .srt,
                        language: nil
                    ),
                    cues: [TimedText.Cue(text: "Too late", startTime: 0, endTime: 4)]
                ),
            ],
            selectedIndex: 0
        )

        player.loadNowPlayingTimedText(for: "file-1") {
            try? await Task.sleep(for: .milliseconds(40))
            return timedText
        }
        player.stop()
        try? await Task.sleep(for: .milliseconds(80))

        #expect(player.nowPlayingTimedText == .empty)
        #expect(!player.isNowPlayingTimedTextLoading)
    }

    @Test func adoptedLanguageCancelsTheDefaultTimedTextLoader() async {
        let player = AudioPlayerService()
        player._setPlaybackStateForTesting(playing: nil, loading: "file-1")
        let defaultTimedText = TimedText.LoadResult(
            tracks: [
                TimedText.Track(
                    candidate: TimedText.Candidate(
                        fileName: "clip.en.srt",
                        path: "clip.en.srt",
                        format: .srt,
                        language: "en"
                    ),
                    cues: []
                ),
                TimedText.Track(
                    candidate: TimedText.Candidate(
                        fileName: "clip.zh.srt",
                        path: "clip.zh.srt",
                        format: .srt,
                        language: "zh"
                    ),
                    cues: []
                ),
            ],
            selectedIndex: 0
        )
        var selectedTimedText = defaultTimedText
        selectedTimedText.selectedIndex = 1

        player.loadNowPlayingTimedText(for: "file-1") {
            try? await Task.sleep(for: .milliseconds(40))
            return defaultTimedText
        }
        player.setNowPlayingTimedText(selectedTimedText, for: "file-1")
        try? await Task.sleep(for: .milliseconds(80))

        #expect(player.nowPlayingTimedText.selectedIndex == 1)
        #expect(!player.isNowPlayingTimedTextLoading)
    }

    @Test func queuedMediaCallbacksRejectRetiredPlaybackSessions() throws {
        let source = try audioPlayerServiceSource()
        let identityGuard = "self.mediaPlaybackSession === playbackSession"
        #expect(source.components(separatedBy: identityGuard).count == 3)
    }

    @Test func playPathTitleUsesFileNameNotSessionTitle() throws {
        let session = makeTestSession(
            id: "session-play-path",
            name: "continue 96cbb6f6",
            model: "openai/o4-mini"
        )
        let fileName = "bridge-clip.wav"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try makeSilentWAV().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let filePlayer = AudioPlayerService()
        filePlayer.setSessionContext(session)
        filePlayer.toggleFilePlayback(fileURL: fileURL, itemID: "file-play-1")
        defer { filePlayer.stop() }

        #expect(filePlayer.nowPlayingPresentation?.title == fileName)
        #expect(filePlayer.nowPlayingPresentation?.title != session.displayTitle)

        let mediaURL = try #require(
            URL(string: "https://oppi.local/workspaces/ws/raw/music/voice-memo.wav")
        )
        let queryURL = try #require(
            URL(string: "https://oppi.local/files/raw?path=%2FUsers%2Fchen%2Fchorus.m4a")
        )
        let mediaPlayer = AudioPlayerService()
        mediaPlayer.setSessionContext(session)
        mediaPlayer.toggleMediaPlayback(
            source: AuthenticatedMediaSource(
                url: mediaURL,
                authorizationHeaderValue: "Bearer test",
                tlsCertFingerprint: nil,
                contentTypeHint: "audio/wav",
                sourceFileExtension: "wav"
            ),
            itemID: "media-play-raw"
        )
        #expect(mediaPlayer.nowPlayingPresentation?.title == "voice-memo.wav")
        #expect(mediaPlayer.nowPlayingPresentation?.title != session.displayTitle)
        mediaPlayer.stop()

        mediaPlayer.toggleMediaPlayback(
            source: AuthenticatedMediaSource(
                url: queryURL,
                authorizationHeaderValue: "Bearer test",
                tlsCertFingerprint: nil,
                contentTypeHint: "audio/mp4",
                sourceFileExtension: "m4a"
            ),
            itemID: "media-play-query"
        )
        defer { mediaPlayer.stop() }
        #expect(mediaPlayer.nowPlayingPresentation?.title == "chorus.m4a")
        #expect(mediaPlayer.nowPlayingPresentation?.title != session.displayTitle)
    }

    @Test func expandedSubtitleFollowsTimedTextAtThePlayhead() {
        let timedText = TimedText.LoadResult(
            tracks: [
                TimedText.Track(
                    candidate: TimedText.Candidate(
                        fileName: "lesson.en.srt",
                        path: "lesson.en.srt",
                        format: .srt,
                        language: "en"
                    ),
                    cues: [
                        TimedText.Cue(text: "First line", startTime: 0, endTime: 2),
                        TimedText.Cue(text: "Second line", startTime: 2, endTime: 5),
                    ]
                ),
            ],
            selectedIndex: 0
        )

        #expect(InAppNowPlayingChrome.currentSubtitle(in: timedText, at: 0.5) == "First line")
        #expect(InAppNowPlayingChrome.currentSubtitle(in: timedText, at: 3) == "Second line")
        #expect(InAppNowPlayingChrome.currentSubtitle(in: timedText, at: 6) == nil)
    }

    @Test func subtitlePresentationDistinguishesLoadingGapsAndNoLyrics() {
        let gapTrack = TimedText.LoadResult(
            tracks: [
                TimedText.Track(
                    candidate: TimedText.Candidate(
                        fileName: "lesson.srt",
                        path: "lesson.srt",
                        format: .srt,
                        language: nil
                    ),
                    cues: [TimedText.Cue(text: "A line", startTime: 0, endTime: 2)]
                ),
            ],
            selectedIndex: 0
        )

        #expect(InAppNowPlayingChrome.subtitlePresentation(
            in: .empty,
            at: 0,
            isLoading: true
        ) == .loading)
        #expect(InAppNowPlayingChrome.subtitlePresentation(
            in: .empty,
            at: 0,
            isLoading: false
        ) == .unavailable)
        #expect(InAppNowPlayingChrome.subtitlePresentation(
            in: gapTrack,
            at: 3,
            isLoading: false
        ) == .gap)
        #expect(InAppNowPlayingChrome.subtitlePresentation(
            in: gapTrack,
            at: 1,
            isLoading: false
        ) == .cue("A line"))
    }

    @Test func expandedDrawerUsesTheSharedFullTransport() throws {
        let source = try nowPlayingChromeSource()
        #expect(source.contains("AudioPlaybackTransportControls("))
        #expect(source.contains("density: .drawer"))
    }

    @Test func chatTitleTapExpandsAndDoubleTapOpensFullscreen() {
        #expect(InAppNowPlayingChrome.titleAction(tapCount: 1, expandsOnTap: true) == .expandOrCollapse)
        #expect(InAppNowPlayingChrome.titleAction(tapCount: 2, expandsOnTap: true) == .openFullScreen)
        #expect(InAppNowPlayingChrome.titleAction(tapCount: 1, expandsOnTap: false) == .openFullScreen)
        #expect(InAppNowPlayingChrome.titleAction(tapCount: 3, expandsOnTap: true) == nil)
    }

    @Test func exclusiveTitleGesturesDoNotRunBothActions() throws {
        var expandCount = 0
        var openCount = 0
        func record(_ tapCount: Int) {
            switch InAppNowPlayingChrome.titleAction(tapCount: tapCount, expandsOnTap: true) {
            case .expandOrCollapse:
                expandCount += 1
            case .openFullScreen:
                openCount += 1
            case nil:
                break
            }
        }

        let siblingActions = [1, 2].compactMap {
            InAppNowPlayingChrome.titleAction(tapCount: $0, expandsOnTap: true)
        }
        #expect(Set(siblingActions) == [.expandOrCollapse, .openFullScreen])

        let competing: Set<Int> = [1, 2]
        if competing.contains(2) {
            record(2)
        } else if competing.contains(1) {
            record(1)
        }
        #expect(expandCount == 0)
        #expect(openCount == 1)
        #expect(expandCount + openCount == 1)

        let source = try nowPlayingChromeSource()
        #expect(source.contains("TapGesture(count: 2)"))
        #expect(source.contains(".exclusively(before:"))
        #expect(source.contains("TapGesture(count: 1)"))
        #expect(!source.contains("highPriorityGesture"))
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

    @Test func stopControlIsLabeledIdentifiedAnd44pt() throws {
        let chrome = try nowPlayingChromeSource()
        #expect(chrome.contains("Stop Playback"))
        #expect(chrome.contains("\\(accessibilityPrefix).stop"))
        #expect(chrome.contains("\\(accessibilityPrefix).drawer.stop"))
        #expect(chrome.contains("stopHitSize"))
        #expect(chrome.contains("frame(width: size, height: size)"))

        let lyrics = try audioLyricsPlayerSource()
        #expect(lyrics.contains("InAppNowPlayingStopButton"))
        #expect(lyrics.contains("audioLyrics.stop"))
    }

    @Test func stopEndsActivePlaybackWhilePauseAndDoneDoNot() throws {
        let player = AudioPlayerService()
        player._setPlaybackStateForTesting(playing: "voice-1", loading: nil)
        player.pause()
        #expect(player.hasActivePlayback)
        #expect(player.isPaused)
        player.stop()
        #expect(!player.hasActivePlayback)

        let chrome = try nowPlayingChromeSource()
        let stopButton = try #require(sourceSlice(
            chrome,
            from: "struct InAppNowPlayingStopButton",
            to: "struct InAppNowPlayingPill"
        ))
        #expect(stopButton.contains("audioPlayer.stop()"))
        #expect(!stopButton.contains("audioPlayer.pause()"))
        #expect(stopButton.contains("Stop Playback"))
        #expect(stopButton.contains("xmark"))
        #expect(chrome.contains("case .pause:\n            audioPlayer.pause()"))
        #expect(chrome.contains("case .cancelLoading:\n            audioPlayer.stop()"))

        let lyrics = try audioLyricsPlayerSource()
        let header = try #require(sourceSlice(
            lyrics,
            from: "private var header:",
            to: "private var languageControl"
        ))
        #expect(header.contains("Button(\"Done\") { dismiss() }"))
        #expect(!header.contains("audioPlayer.stop()"))
        #expect(!header.contains("audioPlayer?.stop()"))
        #expect(header.contains("InAppNowPlayingStopButton") || header.contains("audioLyrics.stop"))
    }

    @Test func titlePlayAndStopHitRegionsStayDistinct() throws {
        let chrome = try nowPlayingChromeSource()
        #expect(chrome.contains("overlay(alignment: .leading)"))
        #expect(chrome.contains("overlay(alignment: .trailing)"))
        #expect(chrome.contains("frame(width: density.playPauseHitSize)"))
        #expect(chrome.contains("frame(width: density.stopHitSize)"))
        #expect(chrome.contains("allowsHitTesting(false)"))
        #expect(chrome.contains("TapGesture(count: 2)"))
        #expect(chrome.contains(".exclusively(before:"))
        #expect(chrome.contains("TapGesture(count: 1)"))
        #expect(!chrome.contains("highPriorityGesture"))
    }

    @Test func compactSessionListKeepsPlayAndStopWithoutTitle() throws {
        #expect(!InAppNowPlayingChrome.PillDensity.sessionListCompact.showsTitle)
        #expect(InAppNowPlayingChrome.PillDensity.sessionListCompact.playPauseHitSize == 44)
        let chrome = try nowPlayingChromeSource()
        let toolbar = try #require(sourceSlice(
            chrome,
            from: "private var toolbarPill:",
            to: "private var playPauseButton"
        ))
        #expect(toolbar.contains("playPauseButton"))
        #expect(toolbar.contains("InAppNowPlayingStopButton") || toolbar.contains("stopButton"))
        #expect(toolbar.contains("if density.showsTitle"))
    }

    @Test func loadingCancelStaysOnLeadingPlayControl() throws {
        #expect(AudioLoadingCancelControl.cancelSymbolName == "xmark")
        let chrome = try nowPlayingChromeSource()
        let playPause = try #require(sourceSlice(
            chrome,
            from: "private var playPauseButton:",
            to: "private var controlAccessibilityLabel"
        ))
        #expect(playPause.contains("AudioLoadingCancelControl"))
        #expect(playPause.contains("Cancel Loading") || chrome.contains("case .cancelLoading: return \"Cancel Loading\""))
        #expect(!playPause.contains("Stop Playback"))
    }

    @Test func embeddedLyricsPlayerOmitsStopWhilePresentedPlayerKeepsIt() throws {
        let lyrics = try audioLyricsPlayerSource()
        let header = try #require(sourceSlice(
            lyrics,
            from: "private var header:",
            to: "private var languageControl"
        ))
        #expect(header.contains("InAppNowPlayingStopButton"))
        #expect(header.contains("audioLyrics.stop"))
        #expect(header.contains("if showsCloseButton, let audioPlayer"))
        #expect(!header.contains("if let audioPlayer {"))

        let presenter = try #require(sourceSlice(
            lyrics,
            from: "static func present(",
            to: "struct AudioLyricsPlayerView"
        ))
        #expect(presenter.contains("showsCloseButton: true"))

        let chrome = try nowPlayingChromeSource()
        let screen = try #require(sourceSlice(
            chrome,
            from: "struct InAppNowPlayingPlayerScreen",
            to: "private func dismissIfPlaybackEnded"
        ))
        #expect(!screen.contains("showsCloseButton: false"))
        #expect(!screen.contains("showsStopButton: false"))

        let fileBrowser = try fileBrowserContentSource()
        let audioView = try #require(sourceSlice(
            fileBrowser,
            from: "private func audioView(",
            to: "// MARK: - Loading"
        ))
        #expect(audioView.contains("showsCloseButton: false"))
        #expect(!audioView.contains("showsStopButton: true"))
        #expect(!audioView.contains("InAppNowPlayingStopButton"))
    }
}

private func nowPlayingChromeSource() throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Oppi/Features/Chat/Support/InAppNowPlayingChrome.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func audioLyricsPlayerSource() throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Oppi/Features/Chat/Timeline/Media/AudioLyricsPlayerView.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func fileBrowserContentSource() throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Oppi/Features/FileBrowser/FileBrowserContentView.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func sourceSlice(_ source: String, from start: String, to end: String) -> String? {
    guard let startRange = source.range(of: start) else { return nil }
    let rest = source[startRange.lowerBound...]
    guard let endRange = rest.range(of: end), endRange.lowerBound > rest.startIndex else {
        return String(rest)
    }
    return String(rest[..<endRange.lowerBound])
}

private func audioPlayerServiceSource() throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Oppi/Core/Services/AudioPlayerService.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func makeSilentWAV(sampleRate: Int = 24_000, frames: Int = 2_400) -> Data {
    var data = Data()
    let pcmBytes = frames * 2
    func appendString(_ value: String) { data.append(contentsOf: value.utf8) }
    func appendUInt16(_ value: UInt16) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    func appendUInt32(_ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    appendString("RIFF")
    appendUInt32(UInt32(36 + pcmBytes))
    appendString("WAVE")
    appendString("fmt ")
    appendUInt32(16)
    appendUInt16(1)
    appendUInt16(1)
    appendUInt32(UInt32(sampleRate))
    appendUInt32(UInt32(sampleRate * 2))
    appendUInt16(2)
    appendUInt16(16)
    appendString("data")
    appendUInt32(UInt32(pcmBytes))
    data.append(Data(repeating: 0, count: pcmBytes))
    return data
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
