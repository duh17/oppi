import Testing
import Foundation
@testable import PiRemote

@Suite("ToolCallFormatting")
struct ToolCallFormattingTests {

    // MARK: - Tool Type Detection

    @Test func isReadTool() {
        #expect(ToolCallFormatting.isReadTool("Read"))
        #expect(ToolCallFormatting.isReadTool("read"))
        #expect(!ToolCallFormatting.isReadTool("Write"))
        #expect(!ToolCallFormatting.isReadTool("bash"))
    }

    @Test func isWriteTool() {
        #expect(ToolCallFormatting.isWriteTool("Write"))
        #expect(ToolCallFormatting.isWriteTool("write"))
        #expect(!ToolCallFormatting.isWriteTool("Read"))
    }

    @Test func isEditTool() {
        #expect(ToolCallFormatting.isEditTool("Edit"))
        #expect(ToolCallFormatting.isEditTool("edit"))
        #expect(!ToolCallFormatting.isEditTool("Write"))
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
        let long = String(repeating: "a", count: 200)
        let args: [String: JSONValue] = ["command": .string(long)]
        let result = ToolCallFormatting.bashCommand(args: args, argsSummary: "")
        #expect(result.count == 120)
    }

    @Test func bashCommandFallbackToSummary() {
        let result = ToolCallFormatting.bashCommand(args: nil, argsSummary: "command: ls -la")
        #expect(result == "ls -la")
    }

    @Test func bashCommandRawSummary() {
        let result = ToolCallFormatting.bashCommand(args: nil, argsSummary: "some arg")
        #expect(result == "some arg")
    }

    // MARK: - Display File Path

    @Test func displayFilePathShortens() {
        let args: [String: JSONValue] = ["path": .string("/Users/chenda/workspace/project/src/main.swift")]
        let result = ToolCallFormatting.displayFilePath(tool: "Read", args: args, argsSummary: "")
        #expect(result.contains("~"))
        #expect(!result.hasPrefix("/Users/chenda"))
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
}
