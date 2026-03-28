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

    @Test func normalizedCanonicalizesNamespacedTools() {
        #expect(ToolCallFormatting.normalized("  BASH\n") == "bash")
        #expect(ToolCallFormatting.normalized("functions.read") == "read")
        #expect(ToolCallFormatting.normalized("tools/write") == "write")
        #expect(ToolCallFormatting.normalized("mcp:extensions.lookup") == "lookup")
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
        #expect(ToolCallFormatting.formatBytes(42) == "42 B")
        #expect(ToolCallFormatting.formatBytes(1023) == "1023 B")
    }

    @Test func formatBytesKilobytes() {
        #expect(ToolCallFormatting.formatBytes(1024) == "1.0 KB")
        #expect(ToolCallFormatting.formatBytes(10240) == "10.0 KB")
    }

    @Test func formatBytesMegabytes() {
        #expect(ToolCallFormatting.formatBytes(1048576) == "1.0 MB")
        #expect(ToolCallFormatting.formatBytes(5242880) == "5.0 MB")
    }
}
