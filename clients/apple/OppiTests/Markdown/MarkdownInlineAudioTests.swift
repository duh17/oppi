import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Markdown inline audio contract")
struct MarkdownInlineAudioTests {
    @Test("bang-wiki audio embeds while ordinary wiki stays a link and video stays video")
    func syntaxAndSourcePolicy() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let segments = FlatSegment.build(
            from: parseCommonMark(
                "![[media/demo.m4a]]\n\n[[media/demo.m4a]]\n\n![[media/demo.mp4]]\n\n![[notes/readme.md]]"
            ),
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL
        )

        let audios = audioEmbeds(in: segments)
        #expect(audios.count == 1)
        #expect(audios.first?.reference.fileCandidatePath == "media/demo.m4a")
        #expect(audios.first?.reference.kind == .workspaceFile)

        let videos = videoEmbeds(in: segments)
        #expect(videos.count == 1)
        #expect(videos.first?.reference.fileCandidatePath == "media/demo.mp4")

        let renderedText = segments.compactMap { segment -> AttributedString? in
            guard case .text(let text) = segment else { return nil }
            return text
        }
        let uniqueLinkTargets = Set(renderedText.flatMap { $0.runs.compactMap(\.link) })
        #expect(uniqueLinkTargets.count == 2)
        #expect(renderedText.map { String($0.characters) }.joined().contains("!"))
    }

    @Test("recognized audio extensions embed and non-audio bang-wiki does not")
    func recognizedAudioExtensions() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let markdown = """
        ![[a.wav]]
        ![[b.mp3]]
        ![[c.m4a]]
        ![[d.aac]]
        ![[e.flac]]
        ![[f.ogg]]
        ![[g.opus]]
        ![[h.caf]]
        ![[notes/readme.md]]
        """
        let segments = FlatSegment.build(
            from: parseCommonMark(markdown),
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL
        )
        #expect(audioEmbeds(in: segments).count == 8)
        #expect(videoEmbeds(in: segments).isEmpty)
    }

    @Test("host files are eligible but remote, HTML audio, and attachment IDs never embed")
    func sourcePolicyRejectsOutsideAuthenticatedFileRoutes() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let markdown = """
        ![[/tmp/demo.m4a]]

        ![[https://example.com/demo.mp3]]

        ![[attachment:stored-audio]]

        <audio src="https://example.com/demo.mp3"></audio>
        """
        let segments = FlatSegment.build(
            from: parseCommonMark(markdown),
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL
        )

        let audios = audioEmbeds(in: segments)
        #expect(audios.count == 1)
        #expect(audios.first?.reference.kind == .hostFile)
        #expect(audios.first?.reference.fileCandidatePath == "/tmp/demo.m4a")
    }

    @Test("audio segments receive stable occurrence identities")
    func segmentIdentityIsStable() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let initial = build("![[one.m4a]] ![[two.wav]]", baseURL: baseURL)
        let appended = build("![[one.m4a]] ![[two.wav]]\n\nTrailing text.", baseURL: baseURL)
        let audioIDs = zip(initial.segments, initial.identities).compactMap { segment, id in
            if case .audio = segment { return id }
            return nil
        }

        #expect(audioIDs.count == 2)
        #expect(Set(audioIDs).count == 2)
        #expect(audioIDs.map(\.kind) == [.audio, .audio])
        #expect(audioIDs.map(\.occurrenceOrdinal) == [0, 1])
        #expect(Array(appended.identities.prefix(initial.identities.count)) == initial.identities)
    }

    @Test("fallback audio geometry is compact, never 16:9, and playback is opt-in")
    func deterministicGeometryAndPlaybackPolicy() {
        #expect(!MarkdownInlineAudioLayout.autoplay)
        #expect(MarkdownInlineAudioLayout.reservedHeight(forWidth: 320) >= 56)
        #expect(MarkdownInlineAudioLayout.reservedHeight(forWidth: 320) <= 72)
        #expect(MarkdownInlineAudioLayout.reservedHeight(forWidth: 369) == MarkdownInlineAudioLayout.reservedHeight(forWidth: 320))
        #expect(MarkdownInlineAudioLayout.reservedHeight(forWidth: .nan) >= 56)
        #expect(MarkdownInlineAudioLayout.reservedHeight(forWidth: 320) != MarkdownInlineVideoLayout.reservedHeight(forWidth: 320))
    }

    @Test("eligible audio references select the same authenticated routes as video")
    func authenticatedMediaRouteSelection() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let workspaceEmbed = try #require(audioEmbeds(in: build("![[media/demo.m4a]]", baseURL: baseURL).segments).first)
        let hostEmbed = try #require(audioEmbeds(in: build("![[/tmp/demo.wav]]", baseURL: baseURL).segments).first)

        #expect(MarkdownVideoMediaSourceRoute.resolve(
            embed: workspaceEmbed,
            workspaceID: "fallback-workspace",
            sessionID: "session-a",
            worktreeID: "worktree-a"
        ) == .session(workspaceID: "workspace-a", sessionID: "session-a", path: "media/demo.m4a"))
        #expect(MarkdownVideoMediaSourceRoute.resolve(
            embed: workspaceEmbed,
            workspaceID: "fallback-workspace",
            sessionID: nil,
            worktreeID: "worktree-a"
        ) == .workspace(workspaceID: "workspace-a", path: "media/demo.m4a", worktreeID: "worktree-a"))
        #expect(MarkdownVideoMediaSourceRoute.resolve(
            embed: hostEmbed,
            workspaceID: "workspace-a",
            sessionID: "session-a",
            worktreeID: nil
        ) == .host(path: "/tmp/demo.wav"))
        #expect(MarkdownVideoMediaSourceRoute.resolve(
            embed: hostEmbed,
            workspaceID: "workspace-a",
            sessionID: "session-a",
            worktreeID: nil,
            workspaceRuntime: .sandbox
        ) == .session(workspaceID: "workspace-a", sessionID: "session-a", path: "/tmp/demo.wav"))
    }

    @Test("untimed transcript splits into verse lines without inventing start times")
    func untimedLyricsHaveNoKaraoke() {
        let newlineLines = AudioLyrics.lines(from: "First verse\n\nSecond verse")
        #expect(newlineLines.map(\.text) == ["First verse", "Second verse"])
        #expect(newlineLines.allSatisfy { $0.startTime == nil })
        #expect(!AudioLyrics.allowsKaraoke(newlineLines))
        #expect(AudioLyrics.currentIndex(in: newlineLines, at: 12) == nil)
        #expect(AudioLyrics.presentationCurrentIndex(in: newlineLines, at: 0) == nil)
        #expect(AudioLyrics.presentationCurrentIndex(in: newlineLines, at: 12) == nil)

        let sentenceLines = AudioLyrics.lines(from: "Got it. I’m reinstalling the iPhone app now.")
        #expect(sentenceLines.count == 2)
        #expect(sentenceLines[0].text == "Got it.")
        #expect(sentenceLines[1].startTime == nil)

        #expect(AudioLyrics.lines(from: "   ").isEmpty)
        #expect(AudioLyrics.lines(from: nil).isEmpty)
    }

    @Test("timed lyric lines can highlight and seek; untimed lines cannot")
    func timedLyricsEnableSeekAndHighlight() {
        let lines = [
            AudioLyrics.Line(text: "One", startTime: 0),
            AudioLyrics.Line(text: "Two", startTime: 4),
            AudioLyrics.Line(text: "Three", startTime: 9),
        ]
        #expect(AudioLyrics.allowsKaraoke(lines))
        #expect(AudioLyrics.currentIndex(in: lines, at: 0) == 0)
        #expect(AudioLyrics.currentIndex(in: lines, at: 4.2) == 1)
        #expect(AudioLyrics.currentIndex(in: lines, at: 20) == 2)
        #expect(AudioLyrics.presentationCurrentIndex(in: lines, at: 4.2) == 1)
        #expect(AudioLyrics.presentationCurrentIndex(in: lines, at: nil) == nil)
        #expect(lines[1].startTime == 4)
    }

    @Test("playback IDs stay unique for the same path in different scopes")
    func playbackIDsIncludeWorkspaceSessionAndWorktree() {
        let path = "media/demo.m4a"
        let workspaceA = AudioPlaybackItemID.markdown(
            embed: MarkdownAudioEmbed(
                reference: ResourceReference(
                    target: path,
                    sourceServerID: "server-a",
                    workspaceID: "workspace-a",
                    sourceSessionID: "session-a",
                    fileCandidatePath: path
                )
            ),
            worktreeID: "wt-a"
        )
        let workspaceB = AudioPlaybackItemID.markdown(
            embed: MarkdownAudioEmbed(
                reference: ResourceReference(
                    target: path,
                    sourceServerID: "server-a",
                    workspaceID: "workspace-b",
                    sourceSessionID: "session-a",
                    fileCandidatePath: path
                )
            ),
            worktreeID: "wt-a"
        )
        let worktreeA = AudioPlaybackItemID.fileBrowser(
            path: path,
            workspaceID: "workspace-a",
            sessionID: "session-a",
            worktreeID: "wt-a"
        )
        let worktreeB = AudioPlaybackItemID.fileBrowser(
            path: path,
            workspaceID: "workspace-a",
            sessionID: "session-a",
            worktreeID: "wt-b"
        )
        let markdownWorktreeA = AudioPlaybackItemID.markdown(
            embed: MarkdownAudioEmbed(
                reference: ResourceReference(
                    target: path,
                    sourceServerID: "server-a",
                    workspaceID: "workspace-a",
                    sourceSessionID: "session-a",
                    fileCandidatePath: path
                )
            ),
            worktreeID: "wt-a"
        )
        let markdownWorktreeB = AudioPlaybackItemID.markdown(
            embed: MarkdownAudioEmbed(
                reference: ResourceReference(
                    target: path,
                    sourceServerID: "server-a",
                    workspaceID: "workspace-a",
                    sourceSessionID: "session-a",
                    fileCandidatePath: path
                )
            ),
            worktreeID: "wt-b"
        )
        #expect(workspaceA != workspaceB)
        #expect(worktreeA != worktreeB)
        #expect(markdownWorktreeA != markdownWorktreeB)
    }

    @MainActor
    @Test("expand autoplay is only for playNow or an already-playing item")
    func expandAutoplayFollowsPlayNowOrActivePlayback() {
        #expect(AudioLyricsPlayerPresenter.shouldAutoplayOnAppear(
            itemID: "voice-1",
            audioPlayer: nil,
            playNow: true
        ))
        #expect(!AudioLyricsPlayerPresenter.shouldAutoplayOnAppear(
            itemID: "voice-1",
            audioPlayer: nil,
            playNow: false
        ))

        let player = AudioPlayerService()
        player._setPlaybackStateForTesting(playing: "voice-1", loading: nil)
        #expect(AudioLyricsPlayerPresenter.shouldAutoplayOnAppear(
            itemID: "voice-1",
            audioPlayer: player,
            playNow: false
        ))
        #expect(!AudioLyricsPlayerPresenter.shouldAutoplayOnAppear(
            itemID: "voice-2",
            audioPlayer: player,
            playNow: false
        ))
        #expect(!MarkdownInlineAudioLayout.autoplay)
    }

    @MainActor
    @Test("markdown audio view reserves compact height and does not autoplay")
    func markdownAudioViewDoesNotAutoplay() throws {
        let baseURL = try #require(URL(string: "https://server.example.com"))
        let embed = try #require(audioEmbeds(in: build(
            "![[clip.m4a]]",
            baseURL: baseURL
        ).segments).first)
        let view = NativeMarkdownAudioView()
        view.apply(
            embed: embed,
            sourceProvider: { _ in throw CocoaError(.fileNoSuchFile) },
            audioPlayer: AudioPlayerService(),
            renderingMode: .live,
            preferredDisplayWidth: 320
        )
        view.frame = CGRect(x: 0, y: 0, width: 320, height: view.reservedHeight)
        view.layoutIfNeeded()

        #expect(view.reservedHeight >= 56)
        #expect(view.reservedHeight <= 72)
        #expect(!MarkdownInlineAudioLayout.autoplay)
    }

    @MainActor
    @Test("full-screen markdown reader invokes the audio source provider")
    func fullScreenReaderGetsAudioSourceProvider() async throws {
        var resolved = 0
        let provider: MarkdownAudioMediaSourceProvider = { _ in
            resolved += 1
            throw CocoaError(.fileNoSuchFile)
        }
        let body = NativeFullScreenMarkdownBody(
            content: "Listen.\n\n![[clip.m4a]]\n\nDone.",
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: try #require(URL(string: "https://server.example.com")),
            makeMarkdownAudioSource: provider,
            audioPlayer: AudioPlayerService()
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        body.layoutIfNeeded()
        let mounted = await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
            timelineFirstView(ofType: NativeMarkdownAudioView.self, in: body) != nil
        }
        #expect(mounted)
        let didResolve = await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
            resolved > 0
        }
        #expect(didResolve)
        #expect(resolved >= 1)
    }

    @MainActor
    @Test("full-screen markdown audio IDs include worktree")
    func fullScreenMarkdownAudioIDsIncludeWorktree() async throws {
        func stripIdentifier(worktreeId: String) async throws -> String {
            let body = NativeFullScreenMarkdownBody(
                content: "Listen.\n\n![[clip.m4a]]\n\nDone.",
                palette: ThemeID.dark.palette,
                reviewCommentSelectionRouter: nil,
                reviewCommentSourceContext: nil,
                serverID: "server-a",
                workspaceID: "workspace-a",
                worktreeId: worktreeId,
                sessionID: "session-a",
                serverBaseURL: try #require(URL(string: "https://server.example.com")),
                makeMarkdownAudioSource: { _ in throw CocoaError(.fileNoSuchFile) },
                audioPlayer: AudioPlayerService()
            )
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 844))
            window.addSubview(body)
            body.frame = window.bounds
            window.makeKeyAndVisible()
            defer { window.isHidden = true }

            body.layoutIfNeeded()
            let mounted = await waitForTimelineCondition(timeoutMs: 2_000) { @MainActor in
                timelineFirstView(ofType: NativeAudioPlayerStripView.self, in: body) != nil
            }
            #expect(mounted)
            let strip = try #require(timelineFirstView(ofType: NativeAudioPlayerStripView.self, in: body))
            return try #require(strip.accessibilityIdentifier)
        }

        let worktreeA = try await stripIdentifier(worktreeId: "wt-a")
        let worktreeB = try await stripIdentifier(worktreeId: "wt-b")
        #expect(worktreeA != worktreeB)
        #expect(worktreeA.contains("wt-a"))
        #expect(worktreeB.contains("wt-b"))
    }

    private func audioEmbeds(in segments: [FlatSegment]) -> [MarkdownAudioEmbed] {
        segments.compactMap { segment in
            guard case .audio(let embed) = segment else { return nil }
            return embed
        }
    }

    private func videoEmbeds(in segments: [FlatSegment]) -> [MarkdownVideoEmbed] {
        segments.compactMap { segment in
            guard case .video(let embed) = segment else { return nil }
            return embed
        }
    }

    private func build(_ markdown: String, baseURL: URL) -> FlatSegment.BuildResult {
        FlatSegment.buildWithSourceLineRanges(
            from: parseCommonMarkLocated(markdown),
            themeID: .dark,
            serverID: "server-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            serverBaseURL: baseURL,
            mergeAdjacentTextSegments: false
        )
    }
}
