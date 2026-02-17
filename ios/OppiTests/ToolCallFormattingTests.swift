import Testing
import Foundation
@testable import Oppi

@Suite("ToolCallFormatting")
struct ToolCallFormattingTests {

    // MARK: - Tool Type Detection

    @Test func isReadTool() {
        #expect(ToolCallFormatting.isReadTool("Read"))
        #expect(ToolCallFormatting.isReadTool("read"))
        #expect(ToolCallFormatting.isReadTool("functions.read"))
        #expect(ToolCallFormatting.isReadTool("tools/read"))
        #expect(!ToolCallFormatting.isReadTool("Write"))
        #expect(!ToolCallFormatting.isReadTool("bash"))
    }

    @Test func isWriteTool() {
        #expect(ToolCallFormatting.isWriteTool("Write"))
        #expect(ToolCallFormatting.isWriteTool("write"))
        #expect(ToolCallFormatting.isWriteTool("functions.write"))
        #expect(ToolCallFormatting.isWriteTool("tools/write"))
        #expect(!ToolCallFormatting.isWriteTool("Read"))
    }

    @Test func isEditTool() {
        #expect(ToolCallFormatting.isEditTool("Edit"))
        #expect(ToolCallFormatting.isEditTool("edit"))
        #expect(ToolCallFormatting.isEditTool("functions.edit"))
        #expect(!ToolCallFormatting.isEditTool("Write"))
    }

    @Test func isTodoToolRecognizesNamespacedNames() {
        #expect(ToolCallFormatting.isTodoTool("todo"))
        #expect(ToolCallFormatting.isTodoTool("functions.todo"))
        #expect(ToolCallFormatting.isTodoTool("tools/todo"))
        #expect(!ToolCallFormatting.isTodoTool("bash"))
    }

    @Test func normalizedCanonicalizesNamespacedTools() {
        #expect(ToolCallFormatting.normalized("  BASH\n") == "bash")
        #expect(ToolCallFormatting.normalized("functions.read") == "read")
        #expect(ToolCallFormatting.normalized("tools/write") == "write")
        #expect(ToolCallFormatting.normalized("mcp:todo") == "todo")
    }

    // MARK: - Arg Extraction

    @Test func filePathFromStructuredArgs() {
        let args: [String: JSONValue] = ["path": .string("/src/main.swift")]
        #expect(ToolCallFormatting.filePath(from: args) == "/src/main.swift")
    }

    @Test func filePathFromFilePath() {
        let args: [String: JSONValue] = ["file_path": .string("/src/index.ts")]
        #expect(ToolCallFormatting.filePath(from: args) == "/src/index.ts")
    }

    @Test func filePathPrefersPath() {
        let args: [String: JSONValue] = [
            "path": .string("/preferred"),
            "file_path": .string("/fallback"),
        ]
        #expect(ToolCallFormatting.filePath(from: args) == "/preferred")
    }

    @Test func filePathNilWhenMissing() {
        let args: [String: JSONValue] = ["command": .string("ls")]
        #expect(ToolCallFormatting.filePath(from: args) == nil)
    }

    @Test func filePathNilArgs() {
        #expect(ToolCallFormatting.filePath(from: nil) == nil)
    }

    @Test func readStartLineFromOffset() {
        let args: [String: JSONValue] = ["offset": .number(42)]
        #expect(ToolCallFormatting.readStartLine(from: args) == 42)
    }

    @Test func readStartLineDefaultsToOne() {
        let args: [String: JSONValue] = ["path": .string("file.txt")]
        #expect(ToolCallFormatting.readStartLine(from: args) == 1)
    }

    @Test func readStartLineNilArgs() {
        #expect(ToolCallFormatting.readStartLine(from: nil) == 1)
    }

    // MARK: - Bash Command

    @Test func bashCommandFromArgs() {
        let args: [String: JSONValue] = ["command": .string("echo hello")]
        #expect(ToolCallFormatting.bashCommand(args: args, argsSummary: "") == "echo hello")
    }

    @Test func bashCommandTruncatesLong() {
        let long = String(repeating: "a", count: 260)
        let args: [String: JSONValue] = ["command": .string(long)]
        let result = ToolCallFormatting.bashCommand(args: args, argsSummary: "")
        #expect(result.count == 200)
        #expect(result == String(long.prefix(200)))
    }

    @Test func bashCommandFallbackToSummary() {
        let result = ToolCallFormatting.bashCommand(args: nil, argsSummary: "command: ls -la")
        #expect(result == "ls -la")
    }

    @Test func bashCommandStripsQuotedSummary() {
        let result = ToolCallFormatting.bashCommand(args: nil, argsSummary: "command: 'ls -la'")
        #expect(result == "ls -la")
    }

    @Test func bashCommandStripsDanglingTrailingQuote() {
        let result = ToolCallFormatting.bashCommand(args: nil, argsSummary: "command: ls -la'")
        #expect(result == "ls -la")
    }

    @Test func bashCommandRawSummary() {
        let result = ToolCallFormatting.bashCommand(args: nil, argsSummary: "some arg")
        #expect(result == "some arg")
    }

    // MARK: - Todo Summary

    @Test func todoSummaryGetWithID() {
        let args: [String: JSONValue] = [
            "action": .string("get"),
            "id": .string("TODO-218e1364"),
        ]
        let result = ToolCallFormatting.todoSummary(args: args, argsSummary: "")
        #expect(result == "get TODO-218e1364")
    }

    @Test func todoSummaryCreateWithTitle() {
        let args: [String: JSONValue] = [
            "action": .string("create"),
            "title": .string("iOS syntax highlighting follow-up"),
        ]
        let result = ToolCallFormatting.todoSummary(args: args, argsSummary: "")
        #expect(result == "create iOS syntax highlighting follow-up")
    }

    @Test func todoSummaryListWithStatus() {
        let args: [String: JSONValue] = [
            "action": .string("list"),
            "status": .string("open"),
        ]
        let result = ToolCallFormatting.todoSummary(args: args, argsSummary: "")
        #expect(result == "list status=open")
    }

    @Test func todoSummaryFallbackToArgsSummary() {
        let result = ToolCallFormatting.todoSummary(args: nil, argsSummary: "action: list-all")
        #expect(result == "list-all")
    }

    @Test func todoOutputPresentationFormatsSectionedList() {
        let output = """
        {
          "assigned": [
            {
              "id": "TODO-a1",
              "title": "Ship host-mode gate fixes",
              "status": "in_progress"
            }
          ],
          "open": [
            {
              "id": "TODO-b2",
              "title": "Write migration notes",
              "status": "open"
            }
          ],
          "closed": []
        }
        """

        let presentation = ToolCallFormatting.todoOutputPresentation(
            args: ["action": .string("list-all")],
            argsSummary: "",
            output: output
        )

        #expect(presentation?.usesMarkdown == true)
        #expect(presentation?.trailing == "1 assigned · 1 open")
        #expect(presentation?.text.contains("### Assigned (1)") == true)
        #expect(presentation?.text.contains("TODO-a1") == true)
        #expect(presentation?.text.contains("### Open (1)") == true)
    }

    @Test func todoOutputPresentationFormatsSingleItemAndKeepsMarkdownBody() {
        let output = """
        {
          "id": "TODO-abc123",
          "title": "Polish todo output renderer",
          "tags": ["ios", "chat"],
          "status": "in_progress",
          "created_at": "2026-02-12T08:30:00.000Z",
          "body": "## Acceptance\\n- list output is readable\\n- markdown body renders"
        }
        """

        let presentation = ToolCallFormatting.todoOutputPresentation(
            args: ["action": .string("get")],
            argsSummary: "",
            output: output
        )

        #expect(presentation?.usesMarkdown == true)
        #expect(presentation?.trailing == "in-progress")
        #expect(presentation?.text.contains("todo get") == true)
        #expect(presentation?.text.contains("## Acceptance") == true)
        #expect(presentation?.text.contains("Tags:") == true)
    }

    @Test func todoOutputPresentationReturnsNilForNonJSONText() {
        let presentation = ToolCallFormatting.todoOutputPresentation(
            args: ["action": .string("claim")],
            argsSummary: "",
            output: "claimed"
        )

        #expect(presentation == nil)
    }

    @Test func todoAppendDiffPresentationUsesAddedLinesOnly() {
        let args: [String: JSONValue] = [
            "action": .string("append"),
            "body": .string("First line\n- bullet item\n```swift\nprint(\"hi\")\n```")
        ]

        let presentation = ToolCallFormatting.todoAppendDiffPresentation(args: args, argsSummary: "")

        #expect(presentation?.addedLineCount == 5)
        #expect(
            presentation?.diffLines.allSatisfy { line in
                switch line.kind {
                case .added: return true
                case .context, .removed: return false
                }
            } == true
        )
        #expect(presentation?.preview == "First line\n- bullet item")
        #expect(presentation?.unifiedText.contains("+ print(\"hi\")") == true)
    }

    @Test func todoAppendDiffPresentationReturnsNilForNonAppendAction() {
        let args: [String: JSONValue] = [
            "action": .string("get"),
            "body": .string("ignored")
        ]

        let presentation = ToolCallFormatting.todoAppendDiffPresentation(args: args, argsSummary: "")
        #expect(presentation == nil)
    }

    @Test func todoMutationDiffPresentationFormatsUpdatePayloadAsDiff() {
        let args: [String: JSONValue] = [
            "action": .string("update"),
            "id": .string("TODO-463187a1"),
            "status": .string("closed"),
            "title": .string("Refine auto-follow scrolling during streaming"),
            "tags": .array([.string("ios"), .string("chat-ui")]),
            "body": .string("Done.\nValidated on simulator and device.")
        ]

        let presentation = ToolCallFormatting.todoMutationDiffPresentation(args: args, argsSummary: "")

        #expect(presentation?.addedLineCount == 6)
        #expect(presentation?.removedLineCount == 0)
        #expect(presentation?.preview == "title: Refine auto-follow scrolling during streaming\nstatus: closed")
        #expect(presentation?.unifiedText.contains("+ status: closed") == true)
        #expect(presentation?.unifiedText.contains("+ tags: ios, chat-ui") == true)
        #expect(presentation?.unifiedText.contains("+ body:") == true)
    }

    @Test func todoMutationDiffPresentationMarksClearedBodyAsRemoval() {
        let args: [String: JSONValue] = [
            "action": .string("update"),
            "id": .string("TODO-463187a1"),
            "body": .string("   ")
        ]

        let presentation = ToolCallFormatting.todoMutationDiffPresentation(args: args, argsSummary: "")

        #expect(presentation?.addedLineCount == 0)
        #expect(presentation?.removedLineCount == 1)
        #expect(
            presentation?.diffLines.first.map { line in
                switch line.kind {
                case .removed:
                    return true
                case .added, .context:
                    return false
                }
            } == true
        )
        #expect(presentation?.unifiedText.contains("- body: <cleared>") == true)
    }

    // MARK: - Display File Path

    @Test func displayFilePathShowsTailComponents() {
        let args: [String: JSONValue] = ["path": .string("/Users/dev/workspace/project/src/main.swift")]
        let result = ToolCallFormatting.displayFilePath(tool: "Read", args: args, argsSummary: "")
        #expect(result == "src/main.swift")
    }

    @Test func displayFilePathWithLineRange() {
        let args: [String: JSONValue] = [
            "path": .string("file.swift"),
            "offset": .number(10),
            "limit": .number(20),
        ]
        let result = ToolCallFormatting.displayFilePath(tool: "Read", args: args, argsSummary: "")
        #expect(result.contains(":10-29"))
    }

    @Test func displayFilePathWithLineRangeForNamespacedReadTool() {
        let args: [String: JSONValue] = [
            "path": .string("file.swift"),
            "offset": .number(5),
            "limit": .number(3),
        ]
        let result = ToolCallFormatting.displayFilePath(tool: "functions.read", args: args, argsSummary: "")
        #expect(result.contains(":5-7"))
    }

    @Test func displayFilePathShowsTailAndLineRangeForAbsolutePath() {
        let args: [String: JSONValue] = [
            "path": .string("/Users/dev/workspace/myproject/ios/Oppi/Features/Chat/ToolTimelineRowContent.swift"),
            "offset": .number(1),
            "limit": .number(120),
        ]
        let result = ToolCallFormatting.displayFilePath(tool: "Read", args: args, argsSummary: "")
        #expect(result == "Chat/ToolTimelineRowContent.swift:1-120")
    }

    @Test func displayFilePathOffsetOnly() {
        let args: [String: JSONValue] = [
            "path": .string("file.swift"),
            "offset": .number(50),
        ]
        let result = ToolCallFormatting.displayFilePath(tool: "Read", args: args, argsSummary: "")
        #expect(result.contains(":50"))
        #expect(!result.contains("-"))
    }

    @Test func displayFilePathNoRangeForWrite() {
        let args: [String: JSONValue] = [
            "path": .string("file.swift"),
            "offset": .number(10),
            "limit": .number(20),
        ]
        let result = ToolCallFormatting.displayFilePath(tool: "Write", args: args, argsSummary: "")
        #expect(!result.contains(":10"))
    }

    @Test func displayFilePathFallsBackToSummary() {
        let result = ToolCallFormatting.displayFilePath(tool: "Read", args: nil, argsSummary: "some summary")
        #expect(result == "some summary")
    }

    // MARK: - Parse Arg Value

    @Test func parseArgValueSimple() {
        let result = ToolCallFormatting.parseArgValue("path", from: "path: /src/main.swift")
        #expect(result == "/src/main.swift")
    }

    @Test func parseArgValueWithComma() {
        let result = ToolCallFormatting.parseArgValue("path", from: "path: /src/main.swift, offset: 10")
        #expect(result == "/src/main.swift")
    }

    @Test func parseArgValueMissing() {
        let result = ToolCallFormatting.parseArgValue("missing", from: "path: /src/main.swift")
        #expect(result == nil)
    }

    // MARK: - Edit Diff Stats

    @Test func editDiffStatsCountsReplacements() {
        let args: [String: JSONValue] = [
            "oldText": .string("let value = 1\n"),
            "newText": .string("let value = 2\n"),
        ]

        let stats = ToolCallFormatting.editDiffStats(from: args)
        #expect(stats?.added == 1)
        #expect(stats?.removed == 1)
    }

    @Test func editDiffStatsCountsInsertionsAndDeletions() {
        let args: [String: JSONValue] = [
            "oldText": .string("a\nb\nc\n"),
            "newText": .string("a\nb\n"),
        ]

        let stats = ToolCallFormatting.editDiffStats(from: args)
        #expect(stats?.added == 0)
        #expect(stats?.removed == 1)
    }

    @Test func editDiffStatsUsesLCSAndDoesNotOvercountShiftedInsertions() {
        let args: [String: JSONValue] = [
            "oldText": .string("a\nb\nc\nd\n"),
            "newText": .string("a\ninserted\nb\nc\nd\n"),
        ]

        let stats = ToolCallFormatting.editDiffStats(from: args)
        #expect(stats?.added == 1)
        #expect(stats?.removed == 0)
    }

    @Test func editOldAndNewTextSupportsAliasKeys() {
        let args: [String: JSONValue] = [
            "beforeText": .string("old"),
            "after": .string("new"),
        ]

        let pair = ToolCallFormatting.editOldAndNewText(from: args)
        #expect(pair?.oldText == "old")
        #expect(pair?.newText == "new")
    }

    @Test func editDiffStatsSupportsSnakeCaseVariants() {
        let args: [String: JSONValue] = [
            "old_text": .string("a\nb\n"),
            "new_text": .string("a\nb\nc\n"),
        ]

        let stats = ToolCallFormatting.editDiffStats(from: args)
        #expect(stats?.added == 1)
        #expect(stats?.removed == 0)
    }

    @Test func editDiffStatsNilWhenArgsMissing() {
        #expect(ToolCallFormatting.editDiffStats(from: nil) == nil)
        #expect(ToolCallFormatting.editDiffStats(from: ["oldText": .string("a")]) == nil)
    }

    // MARK: - Format Bytes

    @Test func formatBytesSmall() {
        #expect(ToolCallFormatting.formatBytes(42) == "42B")
        #expect(ToolCallFormatting.formatBytes(1023) == "1023B")
    }

    @Test func formatBytesKilobytes() {
        #expect(ToolCallFormatting.formatBytes(1024) == "1KB")
        #expect(ToolCallFormatting.formatBytes(10240) == "10KB")
    }

    @Test func formatBytesMegabytes() {
        #expect(ToolCallFormatting.formatBytes(1048576) == "1.0MB")
        #expect(ToolCallFormatting.formatBytes(5242880) == "5.0MB")
    }

    // MARK: - Remember / Recall

    @Test func rememberSummaryShowsFirstLine() {
        let args: [String: JSONValue] = [
            "text": .string("Important discovery\nMore details"),
        ]
        let result = ToolCallFormatting.rememberSummary(args: args, argsSummary: "")
        #expect(result == "Important discovery")
    }

    @Test func rememberSummaryTruncatesLong() {
        let longText = String(repeating: "a", count: 200)
        let args: [String: JSONValue] = ["text": .string(longText)]
        let result = ToolCallFormatting.rememberSummary(args: args, argsSummary: "")
        #expect(result.count == 80)
    }

    @Test func rememberSummaryFallsBackToArgsSummary() {
        let result = ToolCallFormatting.rememberSummary(args: nil, argsSummary: "text: fallback value")
        #expect(result == "fallback value")
    }

    @Test func rememberTrailingShowsTags() {
        let args: [String: JSONValue] = [
            "tags": .array([.string("oppi"), .string("ios"), .string("bug")]),
        ]
        #expect(ToolCallFormatting.rememberTrailing(args: args) == "oppi, ios, bug")
    }

    @Test func rememberTrailingNilWhenNoTags() {
        let args: [String: JSONValue] = ["text": .string("hello")]
        #expect(ToolCallFormatting.rememberTrailing(args: args) == nil)
    }

    @Test func rememberTrailingTruncatesAtThreeTags() {
        let args: [String: JSONValue] = [
            "tags": .array([.string("a"), .string("b"), .string("c"), .string("d")]),
        ]
        #expect(ToolCallFormatting.rememberTrailing(args: args) == "a, b, c")
    }

    @Test func recallSummaryShowsQuery() {
        let args: [String: JSONValue] = ["query": .string("architecture")]
        let result = ToolCallFormatting.recallSummary(args: args, argsSummary: "")
        #expect(result == "\"architecture\"")
    }

    @Test func recallSummaryIncludesScopeAndDays() {
        let args: [String: JSONValue] = [
            "query": .string("test"),
            "scope": .string("journal"),
            "days": .number(7),
        ]
        let result = ToolCallFormatting.recallSummary(args: args, argsSummary: "")
        #expect(result == "\"test\" journal 7d")
    }

    @Test func recallSummaryOmitsDefaultScope() {
        let args: [String: JSONValue] = [
            "query": .string("test"),
            "scope": .string("all"),
        ]
        let result = ToolCallFormatting.recallSummary(args: args, argsSummary: "")
        #expect(result == "\"test\"")
    }

    @Test func recallTrailingCountsMatches() {
        let output = """
        [2/3] journal/2026-02-16:45  ## First
          path: /path/a
        [1/3] journal/2026-02-15:10  ## Second
          path: /path/b
        """
        #expect(ToolCallFormatting.recallTrailing(output: output) == "2 matches")
    }

    @Test func recallTrailingSingleMatch() {
        let output = """
        [1/1] journal/2026-02-16:10  ## Only result
          path: /path/a
        """
        #expect(ToolCallFormatting.recallTrailing(output: output) == "1 match")
    }

    @Test func recallTrailingNoMatches() {
        let output = "No matches for \"foo\" in all (last 30 days)."
        #expect(ToolCallFormatting.recallTrailing(output: output) == "0 matches")
    }

    @Test func recallTrailingEmptyOutput() {
        #expect(ToolCallFormatting.recallTrailing(output: "") == nil)
    }

    @Test func isRememberTool() {
        #expect(ToolCallFormatting.isRememberTool("remember") == true)
        #expect(ToolCallFormatting.isRememberTool("functions.remember") == true)
        #expect(ToolCallFormatting.isRememberTool("recall") == false)
    }

    @Test func isRecallTool() {
        #expect(ToolCallFormatting.isRecallTool("recall") == true)
        #expect(ToolCallFormatting.isRecallTool("tools/recall") == true)
        #expect(ToolCallFormatting.isRecallTool("remember") == false)
    }
}
