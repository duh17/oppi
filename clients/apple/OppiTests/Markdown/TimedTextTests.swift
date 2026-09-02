import Foundation
import Testing
@testable import Oppi

@Suite("Timed text sidecar matching and parsers")
struct TimedTextTests {
    @Test("mpv exact matcher keeps same stem, optional language, and allowed extensions")
    func matcherIsMpvExact() {
        let names = [
            "clip.lrc",
            "clip.en.srt",
            "clip.zh-Hans.vtt",
            "clip.ass",
            "clip.ssa",
            "other.lrc",
            "clip-lyrics.lrc",
            "myclip.lrc",
            "clip.txt",
            "clip.lrc.bak",
            "clip.backup.srt",
        ]

        let audio = TimedText.candidates(
            mediaPath: "media/clip.m4a",
            directoryNames: names,
            kind: .audio
        )
        #expect(Set(audio.map(\.fileName)) == [
            "clip.lrc",
            "clip.en.srt",
            "clip.zh-Hans.vtt",
            "clip.ass",
            "clip.ssa",
            "clip.backup.srt",
        ])
        #expect(audio.first { $0.fileName == "clip.lrc" }?.language == nil)
        #expect(audio.first { $0.fileName == "clip.en.srt" }?.language == "en")
        #expect(audio.first { $0.fileName == "clip.zh-Hans.vtt" }?.language == "zh-Hans")
        #expect(audio.first { $0.fileName == "clip.backup.srt" }?.language == "backup")
        #expect(audio.allSatisfy { $0.path.hasPrefix("media/") })
        #expect(!audio.contains { $0.fileName == "clip.txt" })
        #expect(!audio.contains { $0.fileName.hasPrefix("other") })
        #expect(!audio.contains { $0.fileName.contains("lyrics") })

        let video = TimedText.candidates(
            mediaPath: "clip.mp4",
            directoryNames: names,
            kind: .video
        )
        #expect(!video.contains { $0.format == .lrc })
        #expect(Set(video.map(\.fileName)) == [
            "clip.en.srt",
            "clip.zh-Hans.vtt",
            "clip.ass",
            "clip.ssa",
            "clip.backup.srt",
        ])
    }

    @Test("auto-pick prefers bare stem, then device locale, then format priority")
    func pickOrderBareLocaleThenFirst() {
        let bareAndLang = TimedText.candidates(
            mediaPath: "clip.m4a",
            directoryNames: ["clip.lrc", "clip.en.vtt"],
            kind: .audio
        )
        #expect(TimedText.pick(bareAndLang, locale: Locale(identifier: "en-US"))?.fileName == "clip.lrc")

        let audioPriority = TimedText.candidates(
            mediaPath: "clip.m4a",
            directoryNames: ["clip.srt", "clip.vtt", "clip.lrc"],
            kind: .audio
        )
        #expect(TimedText.pick(audioPriority, locale: Locale(identifier: "en"))?.fileName == "clip.lrc")

        let localeZh = TimedText.candidates(
            mediaPath: "clip.mp4",
            directoryNames: ["clip.en.srt", "clip.zh.vtt"],
            kind: .video
        )
        #expect(TimedText.pick(localeZh, locale: Locale(identifier: "zh-Hans"))?.fileName == "clip.zh.vtt")
        #expect(TimedText.pick(localeZh, locale: Locale(identifier: "en-US"))?.fileName == "clip.en.srt")

        let noLocale = TimedText.candidates(
            mediaPath: "clip.mp4",
            directoryNames: ["clip.en.srt", "clip.zh.vtt"],
            kind: .video
        )
        #expect(TimedText.pick(noLocale, locale: Locale(identifier: "ja"))?.fileName == "clip.zh.vtt")
    }

    @Test("session probe uses exact stem.ext in priority order with no language suffix")
    func sessionProbeIsExactStemExtensions() {
        #expect(TimedText.sessionProbePaths(mediaPath: "media/clip.m4a", kind: .audio) == [
            "media/clip.lrc",
            "media/clip.vtt",
            "media/clip.srt",
            "media/clip.ass",
            "media/clip.ssa",
        ])
        #expect(TimedText.sessionProbePaths(mediaPath: "clip.mp4", kind: .video) == [
            "clip.vtt",
            "clip.srt",
            "clip.ass",
            "clip.ssa",
        ])
        #expect(!TimedText.sessionProbePaths(mediaPath: "clip.m4a", kind: .audio).contains { $0.contains(".en.") })
    }

    @Test("LRC parser keeps authored times and skips metadata")
    func parseLRC() {
        let cues = TimedText.parse(
            """
            [ti:Title]
            [ar:Artist]
            [00:12.00]First
            [00:17.20]Second
            [01:02.5]Third
            [00:17.20][00:22.00]Repeated
            """,
            format: .lrc
        )
        #expect(cues.map(\.text) == ["First", "Second", "Third", "Repeated", "Repeated"])
        #expect(cues.map(\.startTime) == [12, 17.2, 62.5, 17.2, 22])
        #expect(cues.allSatisfy { $0.endTime == nil })
        #expect(!cues.contains { $0.text == "Title" })
    }

    @Test("SRT parser uses comma timestamps")
    func parseSRT() {
        let cues = TimedText.parse(
            """
            1
            00:00:01,000 --> 00:00:02,500
            Hello

            2
            00:01:00,250 --> 00:01:01,000
            World
            line two
            """,
            format: .srt
        )
        #expect(cues.count == 2)
        #expect(cues[0].text == "Hello")
        #expect(cues[0].startTime == 1)
        #expect(cues[0].endTime == 2.5)
        #expect(cues[1].text == "World\nline two")
        #expect(cues[1].startTime == 60.25)
        #expect(cues[1].endTime == 61)
    }

    @Test("VTT parser uses dot timestamps and skips NOTE")
    func parseVTT() {
        let cues = TimedText.parse(
            """
            WEBVTT

            NOTE this is ignored

            00:00:00.000 --> 00:00:01.000 align:start
            Hello

            00:00:01.500 --> 00:00:03.000
            <b>World</b>
            """,
            format: .vtt
        )
        #expect(cues.count == 2)
        #expect(cues[0].text == "Hello")
        #expect(cues[0].startTime == 0)
        #expect(cues[0].endTime == 1)
        #expect(cues[1].text == "World")
        #expect(cues[1].startTime == 1.5)
        #expect(cues[1].endTime == 3)
    }

    @Test("ASS/SSA flatten Dialogue start/end and strip override tags")
    func parseASSFlatten() {
        let ass = TimedText.parse(
            """
            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,Hello {\\b1}world{\\b0}!
            Comment: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,ignored
            Dialogue: 0,0:00:05.50,0:00:07.00,Default,,0,0,0,,Line\\Ntwo
            """,
            format: .ass
        )
        #expect(ass.map(\.text) == ["Hello world!", "Line two"])
        #expect(ass[0].startTime == 1)
        #expect(ass[0].endTime == 4)
        #expect(ass[1].startTime == 5.5)
        #expect(ass[1].endTime == 7)

        let ssa = TimedText.parse(
            "Dialogue: Marked=0,0:00:00.10,0:00:01.00,Default,,0,0,0,,SSA {\\i1}text{\\i0}",
            format: .ssa
        )
        #expect(ssa.map(\.text) == ["SSA text"])
        #expect(ssa[0].startTime == 0.1)
        #expect(ssa[0].endTime == 1)
    }

    @Test("parsers never invent start times")
    func neverInventTimes() {
        #expect(TimedText.parse("Just verse text\nSecond line", format: .lrc).isEmpty)
        #expect(TimedText.parse("[ti:Title]\n[ar:Artist]", format: .lrc).isEmpty)
        #expect(TimedText.parse("1\nHello without a timestamp", format: .srt).isEmpty)
        #expect(TimedText.parse("WEBVTT\n\nHello", format: .vtt).isEmpty)
        #expect(TimedText.parse("Dialogue: missing times", format: .ass).isEmpty)

        let untimed = AudioLyrics.lines(from: "Just verse text\nSecond line")
        #expect(untimed.map(\.text) == ["Just verse text", "Second line"])
        #expect(untimed.allSatisfy { $0.startTime == nil })
        #expect(TimedText.lyricsLines(from: TimedText.parse("plain", format: .lrc)).isEmpty)
    }

    @Test("video overlay cue is current only inside authored start/end")
    func currentCueUsesAuthoredRange() {
        let cues = [
            TimedText.Cue(text: "One", startTime: 1, endTime: 3),
            TimedText.Cue(text: "Two", startTime: 3, endTime: 5),
        ]
        #expect(TimedText.currentCue(in: cues, at: 0)?.text == nil)
        #expect(TimedText.currentCue(in: cues, at: 1)?.text == "One")
        #expect(TimedText.currentCue(in: cues, at: 2.9)?.text == "One")
        #expect(TimedText.currentCue(in: cues, at: 3)?.text == "Two")
        #expect(TimedText.currentCue(in: cues, at: 5)?.text == nil)
    }

    @Test("host access never lists or fetches a sidecar")
    func hostNeverLoadsSidecar() async {
        let access = TimedText.Access(
            sourceKind: .host,
            listDirectory: { _ in
                Issue.record("host must not list")
                return ["clip.lrc"]
            },
            fetchFile: { _ in
                Issue.record("host must not fetch sidecar")
                return Data()
            }
        )
        let result = await TimedText.load(
            mediaPath: "/tmp/clip.m4a",
            kind: .audio,
            locale: Locale(identifier: "en"),
            access: access
        )
        #expect(result.tracks.isEmpty)
        #expect(!result.showsLanguageControl)
    }

    @Test("session load probes exact stem.ext and has no language picker")
    func sessionLoadProbesInPriority() async {
        let recorder = TimedTextPathRecorder()
        let files = ["media/clip.vtt": "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHi\n"]
        let access = TimedText.Access(
            sourceKind: .session,
            listDirectory: { _ in
                Issue.record("session must not list")
                return []
            },
            fetchFile: { path in
                recorder.fetched.append(path)
                if let text = files[path] {
                    return Data(text.utf8)
                }
                throw APIError.server(status: 404, message: "missing")
            }
        )
        let result = await TimedText.load(
            mediaPath: "media/clip.m4a",
            kind: .audio,
            locale: Locale(identifier: "zh-Hans"),
            access: access
        )
        #expect(recorder.fetched == ["media/clip.lrc", "media/clip.vtt"])
        #expect(result.tracks.count == 1)
        #expect(result.tracks[0].candidate.fileName == "clip.vtt")
        #expect(result.tracks[0].cues.map(\.text) == ["Hi"])
        #expect(!result.showsLanguageControl)
    }

    @Test("workspace load lists parent, fetches the pick, and offers language control for multiple matches")
    func workspaceLoadListsThenFetches() async {
        let recorder = TimedTextPathRecorder()
        let files = [
            "media/clip.en.srt": "1\n00:00:00,000 --> 00:00:01,000\nEN\n",
            "media/clip.zh.vtt": "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nZH\n",
        ]
        let access = TimedText.Access(
            sourceKind: .workspace,
            listDirectory: { path in
                recorder.listed.append(path)
                return ["clip.en.srt", "clip.zh.vtt", "notes.txt", "other.lrc"]
            },
            fetchFile: { path in
                recorder.fetched.append(path)
                if let text = files[path] {
                    return Data(text.utf8)
                }
                throw APIError.server(status: 404, message: "missing")
            }
        )
        let result = await TimedText.load(
            mediaPath: "media/clip.mp4",
            kind: .video,
            locale: Locale(identifier: "zh-Hans"),
            access: access
        )
        #expect(recorder.listed == ["media/"])
        #expect(result.showsLanguageControl)
        #expect(result.tracks.map(\.candidate.fileName).sorted() == ["clip.en.srt", "clip.zh.vtt"])
        #expect(result.selected?.candidate.fileName == "clip.zh.vtt")
        #expect(result.selected?.cues.map(\.text) == ["ZH"])
        #expect(Set(recorder.fetched) == Set(files.keys))
    }

    @Test("workspace missing sidecar yields no lyrics tracks")
    func workspaceMissingSidecarIsEmpty() async {
        let access = TimedText.Access(
            sourceKind: .workspace,
            listDirectory: { _ in ["clip.m4a", "readme.md"] },
            fetchFile: { _ in
                Issue.record("no sidecar should be fetched")
                return Data()
            }
        )
        let result = await TimedText.load(
            mediaPath: "clip.m4a",
            kind: .audio,
            locale: Locale(identifier: "en"),
            access: access
        )
        #expect(result.tracks.isEmpty)
        #expect(TimedText.parentDirectoryPath(forMediaPath: "clip.m4a") == "")
        #expect(TimedText.parentDirectoryPath(forMediaPath: "media/clip.m4a") == "media/")
        #expect(TimedText.join("media/", fileName: "clip.lrc") == "media/clip.lrc")
        #expect(TimedText.join("", fileName: "clip.lrc") == "clip.lrc")
    }

    @Test("chat workspace media lists language sidecars even when sessionID would collapse media bytes")
    func chatWorkspaceOriginListsLanguageSidecars() async {
        let mediaRoute = MarkdownVideoMediaSourceRoute.resolve(
            filePath: "media/clip.mp4",
            kind: .workspaceFile,
            referenceWorkspaceID: "workspace-a",
            workspaceID: "workspace-a",
            sessionID: "session-a",
            worktreeID: "wt-a"
        )
        #expect(mediaRoute == .session(
            workspaceID: "workspace-a",
            sessionID: "session-a",
            path: "media/clip.mp4"
        ))
        #expect(TimedText.sidecarSourceKind(
            fileKind: .workspaceFile,
            sessionID: "session-a",
            workspaceRuntime: nil
        ) == .workspace)
        #expect(TimedText.sidecarSourceKind(
            fileKind: .hostFile,
            sessionID: "session-a",
            workspaceRuntime: nil
        ) == .host)
        #expect(TimedText.sidecarSourceKind(
            fileKind: .hostFile,
            sessionID: "session-a",
            workspaceRuntime: .sandbox
        ) == .session)

        let recorder = TimedTextPathRecorder()
        let files = [
            "media/clip.en.srt": "1\n00:00:00,000 --> 00:00:01,000\nEN\n",
            "media/clip.zh.vtt": "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nZH\n",
        ]
        let access = TimedText.Access(
            sourceKind: TimedText.sidecarSourceKind(
                fileKind: .workspaceFile,
                sessionID: "session-a",
                workspaceRuntime: nil
            ),
            listDirectory: { path in
                recorder.listed.append(path)
                return ["clip.en.srt", "clip.zh.vtt", "clip.mp4"]
            },
            fetchFile: { path in
                recorder.fetched.append(path)
                if let text = files[path] {
                    return Data(text.utf8)
                }
                throw APIError.server(status: 404, message: "missing")
            }
        )
        let result = await TimedText.load(
            mediaPath: "media/clip.mp4",
            kind: .video,
            locale: Locale(identifier: "en"),
            access: access
        )
        #expect(recorder.listed == ["media/"])
        #expect(!recorder.fetched.contains("media/clip.vtt"))
        #expect(result.showsLanguageControl)
        #expect(Set(result.tracks.map(\.candidate.fileName)) == ["clip.en.srt", "clip.zh.vtt"])
    }

    @Test("locale match does not treat zh-Hans as zh-Hant")
    func localeMatchRequiresPrimaryAndScript() {
        let hansAndHant = TimedText.candidates(
            mediaPath: "clip.mp4",
            directoryNames: ["clip.zh-Hans.vtt", "clip.zh-Hant.vtt"],
            kind: .video
        )
        #expect(TimedText.pick(hansAndHant, locale: Locale(identifier: "zh-Hans"))?.fileName == "clip.zh-Hans.vtt")
        #expect(TimedText.pick(hansAndHant, locale: Locale(identifier: "zh-Hant"))?.fileName == "clip.zh-Hant.vtt")

        let hantAndEnglish = TimedText.candidates(
            mediaPath: "clip.mp4",
            directoryNames: ["clip.zh-Hant.srt", "clip.en.srt"],
            kind: .video
        )
        #expect(TimedText.pick(hantAndEnglish, locale: Locale(identifier: "zh-Hans"))?.fileName == "clip.en.srt")
    }

    @Test("session probe keeps going after empty, undecodable, or zero-cue bodies")
    func sessionProbeSkipsEmptyUndecodableAndZeroCue() async {
        let recorder = TimedTextPathRecorder()
        let files: [String: Data] = [
            "clip.vtt": Data(),
            "clip.srt": Data([0x80]),
            "clip.ass": Data("NOTE only, no dialogue\n".utf8),
            "clip.ssa": Data("Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hi\n".utf8),
        ]
        let access = TimedText.Access(
            sourceKind: .session,
            fetchFile: { path in
                recorder.fetched.append(path)
                if let data = files[path] {
                    return data
                }
                throw APIError.server(status: 404, message: "missing")
            }
        )
        let result = await TimedText.load(
            mediaPath: "clip.mp4",
            kind: .video,
            locale: Locale(identifier: "en"),
            access: access
        )
        #expect(recorder.fetched == ["clip.vtt", "clip.srt", "clip.ass", "clip.ssa"])
        #expect(result.tracks.count == 1)
        #expect(result.tracks[0].candidate.fileName == "clip.ssa")
        #expect(result.tracks[0].cues.map(\.text) == ["Hi"])
    }

    @Test("workspace load drops zero-cue tracks")
    func workspaceDropsZeroCueTracks() async {
        let files = [
            "clip.en.srt": "1\n00:00:00,000 --> 00:00:01,000\n\n",
            "clip.zh.vtt": "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nZH\n",
        ]
        let access = TimedText.Access(
            sourceKind: .workspace,
            listDirectory: { _ in ["clip.en.srt", "clip.zh.vtt"] },
            fetchFile: { path in
                if let text = files[path] {
                    return Data(text.utf8)
                }
                throw APIError.server(status: 404, message: "missing")
            }
        )
        let result = await TimedText.load(
            mediaPath: "clip.mp4",
            kind: .video,
            locale: Locale(identifier: "en"),
            access: access
        )
        #expect(result.tracks.map(\.candidate.fileName) == ["clip.zh.vtt"])
        #expect(!result.showsLanguageControl)
        #expect(result.selected?.cues.map(\.text) == ["ZH"])
    }

    @Test("open-ended cues use the latest startTime at or before now")
    func currentCueUsesLatestStartForNonMonotonicLRC() {
        let cues = [
            TimedText.Cue(text: "First in file", startTime: 5, endTime: nil),
            TimedText.Cue(text: "Later start", startTime: 12, endTime: nil),
            TimedText.Cue(text: "Out of order older", startTime: 8, endTime: nil),
        ]
        #expect(TimedText.currentCue(in: cues, at: 4)?.text == nil)
        #expect(TimedText.currentCue(in: cues, at: 11)?.text == "Out of order older")
        #expect(TimedText.currentCue(in: cues, at: 12)?.text == "Later start")

        let lines = [
            AudioLyrics.Line(text: "First in file", startTime: 5),
            AudioLyrics.Line(text: "Later start", startTime: 12),
            AudioLyrics.Line(text: "Out of order older", startTime: 8),
        ]
        #expect(AudioLyrics.currentIndex(in: lines, at: 4) == nil)
        #expect(AudioLyrics.currentIndex(in: lines, at: 11) == 2)
        #expect(AudioLyrics.currentIndex(in: lines, at: 12) == 1)
    }
}

private final class TimedTextPathRecorder: @unchecked Sendable {
    var listed: [String] = []
    var fetched: [String] = []
}
