import Foundation
import Testing
@testable import Oppi

@Suite("Mac tool timeline chrome")
struct MacToolTimelineChromeTests {
    private let readArgs =
        "path: /Users/chenda/.config/oppi/worktrees/zs1JP9sA/wt_feat-mac-app-PRz1_RnV/clients/apple/OppiMac/Session/MacChatSessionRuntimeAdapter.swift, limit: 80"

    @Test func readHeaderKeepsAUsefulPathInsteadOfTheRawArgumentDump() {
        let title = MacToolTimelineChrome.collapsedHeaderDetail(
            tool: "read",
            argsSummary: readArgs
        )

        #expect(title != nil)
        #expect(title?.contains("MacChatSessionRuntimeAdapter.swift") == true)
        #expect(title?.contains("\n") == false)
        #expect(title != readArgs)
        #expect(title?.hasPrefix("path:") == false)
    }

    @Test func genericToolKeepsItsSingleLineSummaryInTheHeaderWhenExpanded() {
        let args = "pattern: theme, path: clients/apple"

        #expect(MacToolTimelineChrome.headerTitle(
            tool: "grep",
            argsSummary: args,
            isExpanded: false
        ) == "grep \(args)")
        #expect(MacToolTimelineChrome.headerTitle(
            tool: "grep",
            argsSummary: args,
            isExpanded: true
        ) == "grep \(args)")
    }

    @Test func bashKeepsCommandBar() {
        #expect(MacToolTimelineChrome.collapsedHeaderDetail(
            tool: "bash",
            argsSummary: "command: git status --short"
        ) == nil)
    }

    @Test func skillReadUsesCompactTitle() {
        let args = "path: /Users/chenda/.pi/agent/skills/oppi-dev/SKILL.md"
        #expect(
            MacToolTimelineChrome.collapsedHeaderDetail(tool: "read", argsSummary: args)
                == "[skill] oppi-dev"
        )
    }

    @Test func structuredArgsRemainAuthoritativeForCompactHeaderAndLanguage() {
        let args: [String: JSONValue] = [
            "path": .string("/tmp/ActualView.swift"),
        ]

        #expect(
            MacToolTimelineChrome.headerTitle(
                tool: "read",
                args: args,
                argsSummary: "path: /tmp/StaleSummary.txt",
                isExpanded: false
            ) == "/tmp/ActualView.swift"
        )
        #expect(
            MacToolTimelineChrome.languageLabel(
                tool: "read",
                args: args,
                argsSummary: "path: /tmp/StaleSummary.txt",
                content: nil
            ) == "Swift"
        )
    }

    @Test func fileTitleCandidatesPreserveFullBreadcrumbAndFilenameHierarchy() {
        let titles = MacToolTimelineChrome.fileTitleCandidates(
            tool: "edit",
            args: ["path": .string("/workspace/clients/apple/OppiMac/Views/App.swift")],
            argsSummary: "path: stale.swift",
            isExpanded: false
        )

        #expect(titles?.full == "/workspace/clients/apple/OppiMac/Views/App.swift")
        #expect(titles?.breadcrumb == "/w/c/a/O/V/App.swift")
        #expect(titles?.fileName == "App.swift")
    }

    @Test func askAndVoiceTitlesMatchIOSPresentation() {
        let askArgs: [String: JSONValue] = [
            "questions": .array([
                .object(["question": .string("Choose a model")]),
                .object(["question": .string("Choose an effort")]),
            ]),
        ]
        #expect(MacToolTimelineChrome.headerTitle(
            tool: "ask",
            args: askArgs,
            argsSummary: "2 questions",
            isExpanded: false
        ).contains("2"))

        #expect(MacToolTimelineChrome.headerTitle(
            tool: "voice_speak",
            argsSummary: "text: hello",
            isExpanded: false,
            isVoicePresentationResult: true
        ) == "Voice message")
    }

    @Test func documentActionUsesDescriptorSemanticsInsteadOfToolNames() {
        #expect(MacToolTimelineChrome.offersDocumentView(for: .diff(.init(lines: [], path: "App.swift"))))
        #expect(MacToolTimelineChrome.offersDocumentView(for: .code(.init(
            text: "let value = 1",
            language: .swift,
            startLine: 1,
            filePath: "App.swift"
        ))))
        #expect(MacToolTimelineChrome.offersDocumentView(for: .terminal(.init(
            command: "npm test",
            output: "PASS",
            unwrapped: false,
            language: nil
        ))))
        #expect(!MacToolTimelineChrome.offersDocumentView(for: .status(message: "Loading…")))
        #expect(!MacToolTimelineChrome.offersDocumentView(for: nil))
    }

    @Test func languageSymbolsCoverStructuredMediaAndDataKinds() {
        #expect(MacToolTimelineChrome.languageSymbolName("SQL") == "cylinder")
        #expect(MacToolTimelineChrome.languageSymbolName("Image") == "photo.fill")
        #expect(MacToolTimelineChrome.languageSymbolName("Audio") == "waveform")
        #expect(MacToolTimelineChrome.languageSymbolName("Video") == "video.fill")
        #expect(MacToolTimelineChrome.languageSymbolName("⚠︎media") == "exclamationmark.triangle.fill")
    }

    @Test func editTrailingMatchesIOSFallbackAndStatsPrecedence() {
        let running = MacToolTimelineChrome.trailingPresentation(
            tool: "edit",
            args: nil,
            details: nil,
            resultSegments: nil,
            isDone: false,
            isInterrupted: false
        )
        #expect(running.text == "editing")
        #expect(running.added == nil)
        #expect(running.removed == nil)

        let args: [String: JSONValue] = [
            "edits": .array([
                .object([
                    "oldText": .string("let old = true\n"),
                    "newText": .string("let new = true\nlet polished = true\n"),
                ]),
            ]),
        ]
        let completed = MacToolTimelineChrome.trailingPresentation(
            tool: "edit",
            args: args,
            details: nil,
            resultSegments: [StyledSegment(text: "ignored", style: .muted)],
            isDone: true,
            isInterrupted: false
        )
        #expect(completed.added == 2)
        #expect(completed.removed == 1)
        #expect(completed.segments == nil)
        #expect(completed.text == nil)

        let modified = MacToolTimelineChrome.trailingPresentation(
            tool: "edit",
            args: nil,
            details: nil,
            resultSegments: nil,
            isDone: true,
            isInterrupted: false
        )
        #expect(modified.text == "modified")
    }

    @Test func editTrailingFallsBackToStrictResultPatchStats() {
        let details: JSONValue = .object([
            "patch": .string("""
            --- App.swift
            +++ App.swift
            @@ -1,2 +1,3 @@
             let stable = true
            -let old = true
            +let new = true
            +let polished = true
            """),
        ])

        let presentation = MacToolTimelineChrome.trailingPresentation(
            tool: "functions.edit",
            args: nil,
            details: details,
            resultSegments: nil,
            isDone: true,
            isInterrupted: false
        )

        #expect(presentation.added == 2)
        #expect(presentation.removed == 1)
        #expect(presentation.text == nil)
    }

    @Test func interruptedTrailingSuppressesStatsAndReducerResultSegments() {
        let presentation = MacToolTimelineChrome.trailingPresentation(
            tool: "edit",
            args: [
                "edits": .array([
                    .object([
                        "oldText": .string("before"),
                        "newText": .string("after"),
                    ]),
                ]),
            ],
            details: nil,
            resultSegments: [StyledSegment(text: "updated", style: .success)],
            isDone: true,
            isInterrupted: true
        )

        #expect(presentation.text == "Interrupted")
        #expect(presentation.added == nil)
        #expect(presentation.removed == nil)
        #expect(presentation.segments == nil)
    }

    @Test func reducerSegmentsMatchIOSSuppressionAndPrefixRules() {
        let generic = [
            StyledSegment(text: "lookup", style: .bold),
            StyledSegment(text: " current theme", style: .accent),
        ]
        #expect(MacToolTimelineChrome.styledCallSegments(
            tool: "extensions.lookup",
            isExpanded: false,
            isVoicePresentationResult: false,
            segments: generic
        ) == generic)

        let bash = [
            StyledSegment(text: "$", style: .bold),
            StyledSegment(text: "  npm test", style: nil),
        ]
        #expect(MacToolTimelineChrome.styledCallSegments(
            tool: "bash",
            isExpanded: false,
            isVoicePresentationResult: false,
            segments: bash
        ) == [StyledSegment(text: "npm test", style: nil)])
        #expect(MacToolTimelineChrome.styledCallSegments(
            tool: "bash",
            isExpanded: true,
            isVoicePresentationResult: false,
            segments: bash
        ) == nil)

        for tool in ["read", "functions.write", "edit", "ask"] {
            #expect(MacToolTimelineChrome.styledCallSegments(
                tool: tool,
                isExpanded: false,
                isVoicePresentationResult: false,
                segments: generic
            ) == nil)
        }
        #expect(MacToolTimelineChrome.styledCallSegments(
            tool: "voice_speak",
            isExpanded: false,
            isVoicePresentationResult: true,
            segments: generic
        ) == nil)
    }

    @Test func styledSegmentRolesMatchIOSThemeSemantics() {
        #expect(MacToolTimelineChrome.segmentRole(for: nil) == .foreground)
        #expect(MacToolTimelineChrome.segmentRole(for: .bold) == .foreground)
        #expect(MacToolTimelineChrome.segmentRole(for: .muted) == .foregroundDim)
        #expect(MacToolTimelineChrome.segmentRole(for: .dim) == .comment)
        #expect(MacToolTimelineChrome.segmentRole(for: .accent) == .cyan)
        #expect(MacToolTimelineChrome.segmentRole(for: .success) == .green)
        #expect(MacToolTimelineChrome.segmentRole(for: .warning) == .yellow)
        #expect(MacToolTimelineChrome.segmentRole(for: .error) == .red)
    }

    @Test func elapsedTextUsesFrozenValueAndHidesCompletedSubsecondTools() {
        let now = Date(timeIntervalSince1970: 1_800_000_020)
        #expect(MacToolTimelineChrome.elapsedText(
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            elapsedSeconds: nil,
            isDone: false,
            now: now
        ) == "20s")
        #expect(MacToolTimelineChrome.elapsedText(
            startedAt: .distantPast,
            elapsedSeconds: 72,
            isDone: true,
            now: now
        ) == "1m 12s")
        #expect(MacToolTimelineChrome.elapsedText(
            startedAt: now,
            elapsedSeconds: 0,
            isDone: true,
            now: now
        ) == nil)
        #expect(MacToolTimelineChrome.elapsedText(
            startedAt: nil,
            elapsedSeconds: nil,
            isDone: false,
            now: now
        ) == nil)
    }
}
