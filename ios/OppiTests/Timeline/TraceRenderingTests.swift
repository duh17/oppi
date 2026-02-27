import Testing
import Foundation
@testable import Oppi

/// Tests that model real-world trace data from pi sessions.
///
/// These tests use actual event patterns observed in production JSONL traces
/// to verify correct rendering. Key patterns:
///
/// 1. The API often emits a leading "\n\n" text block before thinking/tool content
/// 2. A single API response can contain [text, thinking, toolCall] blocks,
///    each becoming a separate TraceEvent
/// 3. Multiple tool calls chain without intervening assistant text
/// 4. Tool results can be large (50KB+ transcripts, base64 images)
/// 5. Some assistant messages are very short status updates ("Fetching transcript...")
@Suite("Real-world Trace Rendering")
struct TraceRenderingTests {

    // MARK: - Helpers

    /// Create a trace event with defaults for unused fields.
    /// Parameter order matches common call-site patterns (toolCallId before output).
    private func traceEvent(
        id: String,
        type: TraceEventType,
        timestamp: String = "2026-02-08T04:07:40.000Z",
        text: String? = nil,
        tool: String? = nil,
        args: [String: JSONValue]? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        output: String? = nil,
        isError: Bool? = nil,
        thinking: String? = nil
    ) -> TraceEvent {
        TraceEvent(
            id: id, type: type, timestamp: timestamp,
            text: text, tool: tool, args: args, output: output,
            toolCallId: toolCallId, toolName: toolName, isError: isError,
            thinking: thinking
        )
    }

    private func itemType(_ item: ChatItem) -> String {
        switch item {
        case .userMessage: return "user"
        case .assistantMessage: return "assistant"
        case .audioClip: return "audio"
        case .thinking: return "thinking"
        case .toolCall(_, let tool, _, _, _, _, _): return "tool(\(tool))"
        case .permission: return "permission"
        case .permissionResolved: return "resolved"
        case .systemEvent: return "system"
        case .error: return "error"
        }
    }

    // MARK: - Whitespace-only assistant messages

    @MainActor
    @Test func whitespaceOnlyAssistantMessagesSkipped() {
        let reducer = TimelineReducer()
        // Pattern from real trace: assistant emits "\n\n" before thinking block
        let events = [
            traceEvent(id: "u1", type: .user, text: "what skills you get"),
            traceEvent(id: "a1-text-0", type: .assistant, text: "\n\n"),
            traceEvent(id: "a1-think-1", type: .thinking, thinking: "Let me list the skills"),
            traceEvent(id: "a1-text-2", type: .assistant, text: "Here are my skills:\n\n1. **searxng**\n2. **fetch**"),
        ]
        reducer.loadSession(events)

        // Should be: user, thinking, assistant (no empty bubble for "\n\n")
        #expect(reducer.items.count == 3)
        guard case .userMessage = reducer.items[0] else {
            Issue.record("Expected userMessage at [0], got \(reducer.items[0])")
            return
        }
        guard case .thinking = reducer.items[1] else {
            Issue.record("Expected thinking at [1], got \(reducer.items[1])")
            return
        }
        guard case .assistantMessage(_, let text, _) = reducer.items[2] else {
            Issue.record("Expected assistantMessage at [2], got \(reducer.items[2])")
            return
        }
        #expect(text.hasPrefix("Here are my skills:"))
    }

    @MainActor
    @Test func emptyStringAssistantMessageSkipped() {
        let reducer = TimelineReducer()
        let events = [
            traceEvent(id: "a1", type: .assistant, text: ""),
            traceEvent(id: "a2", type: .assistant, text: "Real content"),
        ]
        reducer.loadSession(events)

        #expect(reducer.items.count == 1)
        guard case .assistantMessage(_, let text, _) = reducer.items[0] else {
            Issue.record("Expected assistantMessage")
            return
        }
        #expect(text == "Real content")
    }

    @MainActor
    @Test func spacesOnlyAssistantMessageSkipped() {
        let reducer = TimelineReducer()
        let events = [
            traceEvent(id: "a1", type: .assistant, text: "   \n\t\n  "),
            traceEvent(id: "a2", type: .assistant, text: "Actual text"),
        ]
        reducer.loadSession(events)

        #expect(reducer.items.count == 1)
    }

    // MARK: - Tool call with preceding status message

    @MainActor
    @Test func statusMessageBeforeToolCall() {
        // Pattern: assistant says "Fetching transcript..." then starts tool
        let reducer = TimelineReducer()
        let events = [
            traceEvent(id: "u1", type: .user, text: "summarize this video"),
            traceEvent(id: "a1-text-0", type: .assistant, text: "\n\n"),
            traceEvent(id: "a1-think-1", type: .thinking, thinking: "I need to fetch the transcript"),
            traceEvent(id: "a1-tc-2", type: .toolCall, tool: "read",
                       args: ["path": .string("/home/pi/.pi/agent/skills/youtube-transcript/SKILL.md")]),
            traceEvent(id: "tr1", type: .toolResult, toolCallId: "a1-tc-2",
                       toolName: "read", output: "skill content here", isError: false),
            traceEvent(id: "a2-text-0", type: .assistant, text: "Fetching transcript..."),
            traceEvent(id: "a2-tc-1", type: .toolCall, tool: "bash",
                       args: ["command": .string("./transcript.sh url"), "timeout": .string("30")]),
            traceEvent(id: "tr2", type: .toolResult, toolCallId: "a2-tc-1",
                       toolName: "bash", output: "transcript content", isError: false),
        ]
        reducer.loadSession(events)

        let types = reducer.items.map { itemType($0) }
        #expect(types[0] == "user")
        #expect(types[1] == "thinking")
        #expect(types[2] == "tool(read)")
        #expect(types[3] == "assistant")
        #expect(types[4] == "tool(bash)")

        // Verify tool output is linked
        #expect(reducer.toolOutputStore.fullOutput(for: "a1-tc-2") == "skill content here")
        #expect(reducer.toolOutputStore.fullOutput(for: "a2-tc-1") == "transcript content")
    }

    // MARK: - Multi-tool chain without assistant text

    @MainActor
    @Test func chainedToolCallsNoInterveningText() {
        let reducer = TimelineReducer()
        let events = [
            traceEvent(id: "tc1", type: .toolCall, tool: "bash",
                       args: ["command": .string("pip install yt-dlp")]),
            traceEvent(id: "tr1", type: .toolResult, toolCallId: "tc1",
                       output: "installed", isError: false),
            traceEvent(id: "tc2", type: .toolCall, tool: "bash",
                       args: ["command": .string("yt-dlp --print title url")]),
            traceEvent(id: "tr2", type: .toolResult, toolCallId: "tc2",
                       output: "Video Title", isError: false),
            traceEvent(id: "tc3", type: .toolCall, tool: "bash",
                       args: ["command": .string("yt-dlp --write-auto-sub url")]),
            traceEvent(id: "tr3", type: .toolResult, toolCallId: "tc3",
                       output: "subtitles downloaded", isError: false),
        ]
        reducer.loadSession(events)

        #expect(reducer.items.count == 3)
        for item in reducer.items {
            guard case .toolCall = item else {
                Issue.record("Expected all items to be toolCall, got \(item)")
                return
            }
        }

        #expect(reducer.toolOutputStore.fullOutput(for: "tc1") == "installed")
        #expect(reducer.toolOutputStore.fullOutput(for: "tc2") == "Video Title")
        #expect(reducer.toolOutputStore.fullOutput(for: "tc3") == "subtitles downloaded")
    }

    // MARK: - Read tool with structured args

    @MainActor
    @Test func readToolArgsPreserved() {
        let reducer = TimelineReducer()
        let events = [
            traceEvent(id: "tc1", type: .toolCall, tool: "read",
                       args: [
                        "path": .string("/tmp/transcript.txt"),
                        "offset": .number(1362),
                       ]),
            traceEvent(id: "tr1", type: .toolResult, toolCallId: "tc1",
                       output: "line 1362 content...", isError: false),
        ]
        reducer.loadSession(events)

        let args = reducer.toolArgsStore.args(for: "tc1")
        #expect(args?["path"]?.stringValue == "/tmp/transcript.txt")
        #expect(args?["offset"]?.numberValue == 1362)
    }

    // MARK: - Write tool with file content

    @MainActor
    @Test func writeToolArgsIncludeContent() {
        let reducer = TimelineReducer()
        let fileContent = "# Summary\n\nThis is the report content."
        let events = [
            traceEvent(id: "tc1", type: .toolCall, tool: "write",
                       args: [
                        "path": .string("/work/report.md"),
                        "content": .string(fileContent),
                       ]),
            traceEvent(id: "tr1", type: .toolResult, toolCallId: "tc1",
                       output: "Successfully wrote 38 bytes to /work/report.md", isError: false),
        ]
        reducer.loadSession(events)

        let args = reducer.toolArgsStore.args(for: "tc1")
        #expect(args?["path"]?.stringValue == "/work/report.md")
        #expect(args?["content"]?.stringValue == fileContent)
    }

    // MARK: - Edit tool with oldText/newText

    @MainActor
    @Test func editToolArgsIncludeOldAndNew() {
        let reducer = TimelineReducer()
        let events = [
            traceEvent(id: "tc1", type: .toolCall, tool: "Edit",
                       args: [
                        "path": .string("/work/main.swift"),
                        "oldText": .string("let x = 1"),
                        "newText": .string("let x = 42"),
                       ]),
            traceEvent(id: "tr1", type: .toolResult, toolCallId: "tc1",
                       output: "Replaced text", isError: false),
        ]
        reducer.loadSession(events)

        let args = reducer.toolArgsStore.args(for: "tc1")
        #expect(args?["oldText"]?.stringValue == "let x = 1")
        #expect(args?["newText"]?.stringValue == "let x = 42")
    }

    // MARK: - Large tool output (memory bounded)

    @MainActor
    @Test func largeToolOutputTruncated() {
        let reducer = TimelineReducer()
        let largeOutput = String(repeating: "x", count: ToolOutputStore.perItemCap + 1_024)
        let events = [
            traceEvent(id: "tc1", type: .toolCall, tool: "read",
                       args: ["path": .string("/tmp/big.txt")]),
            traceEvent(id: "tr1", type: .toolResult, toolCallId: "tc1",
                       output: largeOutput, isError: false),
        ]
        reducer.loadSession(events)

        let stored = reducer.toolOutputStore.fullOutput(for: "tc1")
        #expect(stored.count < largeOutput.count, "Output should be truncated to perItemCap")
        #expect(stored.hasSuffix(ToolOutputStore.truncationMarker))
    }

    // MARK: - Error tool result

    @MainActor
    @Test func errorToolResultMarksItem() {
        let reducer = TimelineReducer()
        let events = [
            traceEvent(id: "tc1", type: .toolCall, tool: "bash",
                       args: ["command": .string("rm -rf /")]),
            traceEvent(id: "tr1", type: .toolResult, toolCallId: "tc1",
                       output: "command not found\n\nCommand exited with code 127",
                       isError: true),
        ]
        reducer.loadSession(events)

        guard case .toolCall(_, _, _, _, _, let isError, let isDone) = reducer.items[0] else {
            Issue.record("Expected toolCall")
            return
        }
        #expect(isError)
        #expect(isDone)
    }

    // MARK: - Full conversation flow (youtube summarization)

    @MainActor
    @Test func fullYoutubeSummarizationFlow() {
        let reducer = TimelineReducer()
        let events = [
            traceEvent(id: "u1", type: .user,
                       text: "summarize this https://youtu.be/qwmmWzPnhog"),
            traceEvent(id: "a1-text-0", type: .assistant, text: "\n\n"),
            traceEvent(id: "a1-think-1", type: .thinking,
                       thinking: "I should use the youtube-transcript skill"),
            traceEvent(id: "a1-tc-2", type: .toolCall, tool: "read",
                       args: ["path": .string("/skills/youtube-transcript/SKILL.md")]),
            traceEvent(id: "tr1", type: .toolResult, toolCallId: "a1-tc-2",
                       output: "---\nname: youtube-transcript\n...", isError: false),
            traceEvent(id: "a2-text-0", type: .assistant, text: "Fetching transcript..."),
            traceEvent(id: "a2-tc-1", type: .toolCall, tool: "bash",
                       args: ["command": .string("./transcript.sh url")]),
            traceEvent(id: "tr2", type: .toolResult, toolCallId: "a2-tc-1",
                       output: "(no output)", isError: false),
            traceEvent(id: "a3-think-0", type: .thinking, thinking: "Script failed"),
            traceEvent(id: "a3-tc-1", type: .toolCall, tool: "bash",
                       args: ["command": .string("./transcript.sh url")]),
            traceEvent(id: "tr3", type: .toolResult, toolCallId: "a3-tc-1",
                       output: "Failed to download audio\n", isError: false),
            traceEvent(id: "a4-tc-0", type: .toolCall, tool: "bash",
                       args: ["command": .string("pip install yt-dlp")]),
            traceEvent(id: "tr4", type: .toolResult, toolCallId: "a4-tc-0",
                       output: "Successfully installed yt-dlp", isError: false),
            traceEvent(id: "a5-tc-0", type: .toolCall, tool: "read",
                       args: ["path": .string("/tmp/transcript.txt")]),
            traceEvent(id: "tr5", type: .toolResult, toolCallId: "a5-tc-0",
                       output: "I feel like when I'm using code...", isError: false),
            traceEvent(id: "a6-think-0", type: .thinking, thinking: "Got the transcript"),
            traceEvent(id: "a6-text-1", type: .assistant, text: "Writing summary..."),
            traceEvent(id: "a6-tc-2", type: .toolCall, tool: "write",
                       args: [
                        "path": .string("/work/summary.md"),
                        "content": .string("# Summary\n\nContent here"),
                       ]),
            traceEvent(id: "tr6", type: .toolResult, toolCallId: "a6-tc-2",
                       output: "Successfully wrote 24 bytes", isError: false),
            traceEvent(id: "a7-text-0", type: .assistant,
                       text: "Done! Summary saved to **`/work/summary.md`**"),
        ]
        reducer.loadSession(events)

        let types = reducer.items.map { itemType($0) }
        let expected = [
            "user",
            "thinking",       // a1-think-1
            "tool(read)",     // a1-tc-2
            "assistant",      // "Fetching transcript..."
            "tool(bash)",     // a2-tc-1
            "thinking",       // a3-think-0
            "tool(bash)",     // a3-tc-1
            "tool(bash)",     // a4-tc-0
            "tool(read)",     // a5-tc-0
            "thinking",       // a6-think-0
            "assistant",      // "Writing summary..."
            "tool(write)",    // a6-tc-2
            "assistant",      // "Done! Summary saved..."
        ]
        #expect(types == expected, "No empty bubbles from whitespace-only text")

        // Final message has markdown
        if let last = reducer.items.last,
           case .assistantMessage(_, let text, _) = last {
            #expect(text.contains("**`/work/summary.md`**"))
        }
    }

    // MARK: - Weather query flow

    @MainActor
    @Test func weatherQueryWithToolFailures() {
        let reducer = TimelineReducer()
        let events = [
            traceEvent(id: "u1", type: .user, text: "what's the weather tomorrow?"),
            traceEvent(id: "tc1", type: .toolCall, tool: "read",
                       args: ["path": .string("/skills/weather/SKILL.md")]),
            traceEvent(id: "tr1", type: .toolResult, toolCallId: "tc1",
                       output: "skill docs...", isError: false),
            traceEvent(id: "tc2", type: .toolCall, tool: "bash",
                       args: ["command": .string("forecast.sh seattle")]),
            traceEvent(id: "tr2", type: .toolResult, toolCallId: "tc2",
                       output: "Kypu API not reachable", isError: true),
            traceEvent(id: "t1-think", type: .thinking,
                       thinking: "Kypu is down, use API directly"),
            traceEvent(id: "tc3", type: .toolCall, tool: "bash",
                       args: ["command": .string("curl api.open-meteo.com/...")]),
            traceEvent(id: "tr3", type: .toolResult, toolCallId: "tc3",
                       output: "{\"daily\":{\"temp\":[48]}}", isError: false),
            traceEvent(id: "t2-think", type: .thinking, thinking: "Parse the data"),
            traceEvent(id: "a1-text", type: .assistant,
                       text: "Here's **tomorrow's forecast**:\n\n| | |\n|---|---|\n| Temp | 48F |"),
        ]
        reducer.loadSession(events)

        let types = reducer.items.map { itemType($0) }
        #expect(types == [
            "user", "tool(read)", "tool(bash)", "thinking",
            "tool(bash)", "thinking", "assistant",
        ])

        // Error tool has isError flag
        if case .toolCall(_, _, _, _, _, let isError, _) = reducer.items[2] {
            #expect(isError)
        }
    }

    // MARK: - Research flow (many tool calls)

    @MainActor
    @Test func researchFlowManySearches() {
        let reducer = TimelineReducer()
        var events: [TraceEvent] = [
            traceEvent(id: "u1", type: .user, text: "research ios best practices"),
            traceEvent(id: "a0-text", type: .assistant, text: "\n\n"),
            traceEvent(id: "a0-think", type: .thinking, thinking: "Planning research"),
            traceEvent(id: "a0-text2", type: .assistant, text: "Starting deep research..."),
        ]

        for i in 1...5 {
            events.append(traceEvent(id: "tc-s\(i)", type: .toolCall, tool: "bash",
                                     args: ["command": .string("search 'topic \(i)'")]))
            events.append(traceEvent(id: "tr-s\(i)", type: .toolResult, toolCallId: "tc-s\(i)",
                                     output: "1. Result A\n2. Result B", isError: false))
        }

        events.append(traceEvent(id: "a-status", type: .assistant, text: "Compiling report..."))
        events.append(traceEvent(id: "tc-write", type: .toolCall, tool: "write",
                                 args: ["path": .string("/work/report.md"),
                                        "content": .string("# Report\n\nContent")]))
        events.append(traceEvent(id: "tr-write", type: .toolResult, toolCallId: "tc-write",
                                 output: "Successfully wrote 20 bytes", isError: false))
        events.append(traceEvent(id: "a-final", type: .assistant,
                                 text: "Done. Report saved to **`/work/report.md`**"))

        reducer.loadSession(events)

        let types = reducer.items.map { itemType($0) }
        #expect(types[0] == "user")
        #expect(types[1] == "thinking")
        #expect(types[2] == "assistant") // "Starting deep research..."

        let bashCount = types.filter { $0 == "tool(bash)" }.count
        #expect(bashCount == 5)

        let lastThree = Array(types.suffix(3))
        #expect(lastThree == ["assistant", "tool(write)", "assistant"])
    }

    // MARK: - Markdown rendering

    @Test func parseCodeBlocksRealAssistantMessage() {
        let text = """
        Here's how to set it up:

        ```swift
        let config = Config()
        config.timeout = 30
        ```

        Then run the command:

        ```bash
        swift build
        ```

        That should work!
        """

        let blocks = parseCodeBlocks(text)

        #expect(blocks.count == 5)
        // Prose blocks include trailing newline before code fence
        if case .markdown(let prose) = blocks[0] {
            #expect(prose.trimmingCharacters(in: .whitespacesAndNewlines) == "Here's how to set it up:")
        }
        if case .codeBlock(let lang, let code, let complete) = blocks[1] {
            #expect(lang == "swift")
            #expect(code.contains("Config()"))
            #expect(complete)
        }
        if case .markdown(let prose) = blocks[2] {
            #expect(prose.trimmingCharacters(in: .whitespacesAndNewlines) == "Then run the command:")
        }
        if case .codeBlock(let lang, _, let complete) = blocks[3] {
            #expect(lang == "bash")
            #expect(complete)
        }
    }

    @Test func parseCodeBlocksMarkdownTable() {
        let text = """
        Here's the forecast:

        | | |
        |---|---|
        | Temp | 48F |
        | Rain | 40% |
        """
        let blocks = parseCodeBlocks(text)
        #expect(blocks.count == 2)
        #expect(blocks[0] == .markdown("Here's the forecast:\n"))
        #expect(blocks[1] == .table(headers: ["", ""], rows: [["Temp", "48F"], ["Rain", "40%"]]))
    }

    @Test func parseCodeBlocksBoldAndLinks() {
        let text = "Saved to **`/work/report.md`**\n\nSee [docs](https://example.com) for details."
        let blocks = parseCodeBlocks(text)
        #expect(blocks.count == 1)
        #expect(blocks[0] == .markdown(text))
    }

    // MARK: - Streaming then trace reload

    @MainActor
    @Test func streamingThenTraceReloadProducesCleanTimeline() {
        let reducer = TimelineReducer()

        reducer.process(.agentStart(sessionId: "s1"))
        reducer.process(.textDelta(sessionId: "s1", delta: "Hello"))
        reducer.process(.agentEnd(sessionId: "s1"))

        let events = [
            traceEvent(id: "u1", type: .user, text: "hi"),
            traceEvent(id: "a1", type: .assistant, text: "Hello"),
        ]
        reducer.loadSession(events)

        #expect(reducer.items.count == 2)
        #expect(reducer.streamingAssistantID == nil)
    }

    // MARK: - SVG write tool

    @MainActor
    @Test func writeToolWithSVGContent() {
        let reducer = TimelineReducer()
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><circle cx=\"50\" cy=\"50\" r=\"40\"/></svg>"
        let events = [
            traceEvent(id: "tc1", type: .toolCall, tool: "write",
                       args: ["path": .string("/work/art.svg"), "content": .string(svg)]),
            traceEvent(id: "tr1", type: .toolResult, toolCallId: "tc1",
                       output: "Wrote 80 bytes", isError: false),
        ]
        reducer.loadSession(events)

        let args = reducer.toolArgsStore.args(for: "tc1")
        #expect(args?["content"]?.stringValue == svg)
        #expect(args?["path"]?.stringValue == "/work/art.svg")
    }

    // MARK: - Orphan tool result

    @MainActor
    @Test func orphanToolResultStored() {
        let reducer = TimelineReducer()
        let events = [
            traceEvent(id: "tr1", type: .toolResult, toolCallId: "missing-tc",
                       output: "some output", isError: false),
        ]
        reducer.loadSession(events)

        #expect(reducer.items.isEmpty)
        #expect(reducer.toolOutputStore.fullOutput(for: "missing-tc") == "some output")
    }

    // MARK: - Compaction

    @MainActor
    @Test func compactionBetweenMessages() {
        let reducer = TimelineReducer()
        let events = [
            traceEvent(id: "u1", type: .user, text: "first question"),
            traceEvent(id: "a1", type: .assistant, text: "first answer"),
            traceEvent(id: "c1", type: .compaction),
            traceEvent(id: "u2", type: .user, text: "second question"),
            traceEvent(id: "a2", type: .assistant, text: "second answer"),
        ]
        reducer.loadSession(events)

        let types = reducer.items.map { itemType($0) }
        #expect(types == ["user", "assistant", "system", "user", "assistant"])

        guard case .systemEvent(_, let msg) = reducer.items[2] else {
            Issue.record("Expected system event for compaction")
            return
        }
        #expect(msg == "Context compacted")
    }

    // MARK: - Multiple thinking blocks

    @MainActor
    @Test func multipleThinkingBlocksAcrossTurns() {
        let reducer = TimelineReducer()
        let events = [
            traceEvent(id: "u1", type: .user, text: "hard question"),
            traceEvent(id: "t1", type: .thinking, thinking: "First thought"),
            traceEvent(id: "a1", type: .assistant, text: "Let me search."),
            traceEvent(id: "tc1", type: .toolCall, tool: "bash",
                       args: ["command": .string("search query")]),
            traceEvent(id: "tr1", type: .toolResult, toolCallId: "tc1",
                       output: "results", isError: false),
            traceEvent(id: "t2", type: .thinking, thinking: "Based on results..."),
            traceEvent(id: "a2", type: .assistant, text: "The answer is X."),
        ]
        reducer.loadSession(events)

        let types = reducer.items.map { itemType($0) }
        #expect(types == [
            "user", "thinking", "assistant", "tool(bash)", "thinking", "assistant",
        ])
    }

    // MARK: - Partial trace preferred over REST

    @MainActor
    @Test func partialTraceBetterThanREST() {
        // Scenario: JSONL partially missing (server restart). Trace has
        // some turns with tool calls. REST has ALL turns but as flat text.
        // The trace path should always be preferred because it preserves
        // tool call structure for the turns it has.

        let reducer = TimelineReducer()

        // Simulate what loadSession produces (partial trace — 2 of 5 turns)
        let traceEvents = [
            traceEvent(id: "u1", type: .user, text: "check weather"),
            traceEvent(id: "t1", type: .thinking, thinking: "Let me look up the weather"),
            traceEvent(id: "tc1", type: .toolCall, tool: "bash",
                       args: ["command": .string("curl weather-api.com")]),
            traceEvent(id: "tr1", type: .toolResult, toolCallId: "tc1",
                       output: "{\"temp\": 48}", isError: false),
            traceEvent(id: "a1", type: .assistant, text: "It's 48F today."),
        ]
        reducer.loadSession(traceEvents)

        let traceTypes = reducer.items.map { itemType($0) }
        #expect(traceTypes == ["user", "thinking", "tool(bash)", "assistant"])
        // Tool output linked
        #expect(reducer.toolOutputStore.fullOutput(for: "tc1") == "{\"temp\": 48}")
        // Args stored for smart header rendering
        let args = reducer.toolArgsStore.args(for: "tc1")
        #expect(args?["command"]?.stringValue == "curl weather-api.com")

        // Trace preserves structure that flat text-only messages would lose:
        // thinking blocks, tool call rows with headers/output, structured args.
        // This is why trace is the only history path — no REST fallback.
        #expect(traceTypes.count == 4, "Trace has thinking + tool + assistant structure")
    }

    // MARK: - ToolCallFormatting

    @Test func toolCallFormattingBashCommand() {
        let args: [String: JSONValue] = ["command": .string("echo hello world")]
        let result = ToolCallFormatting.bashCommand(args: args, argsSummary: "command: echo hello world")
        #expect(result == "echo hello world")
    }

    @Test func toolCallFormattingFilePathWithRange() {
        let args: [String: JSONValue] = [
            "path": .string("/work/src/main.swift"),
            "offset": .number(100),
            "limit": .number(50),
        ]
        let display = ToolCallFormatting.displayFilePath(tool: "read", args: args, argsSummary: "")
        #expect(display.contains("main.swift"))
        #expect(display.contains(":100"))
        #expect(display.contains("-149"))
    }

    @Test func toolCallFormattingFormatBytes() {
        #expect(ToolCallFormatting.formatBytes(500) == "500B")
        #expect(ToolCallFormatting.formatBytes(2048) == "2KB")
        #expect(ToolCallFormatting.formatBytes(1_500_000) == "1.4MB")
    }

    @Test func toolCallFormattingParseArgValue() {
        let summary = "command: ls -la, timeout: 30"
        #expect(ToolCallFormatting.parseArgValue("command", from: summary) == "ls -la")
        #expect(ToolCallFormatting.parseArgValue("timeout", from: summary) == "30")
        #expect(ToolCallFormatting.parseArgValue("missing", from: summary) == nil)
    }

    @Test func toolCallFormattingReadStartLine() {
        let args: [String: JSONValue] = ["offset": .number(42)]
        #expect(ToolCallFormatting.readStartLine(from: args) == 42)
        #expect(ToolCallFormatting.readStartLine(from: nil) == 1)
        #expect(ToolCallFormatting.readStartLine(from: [:]) == 1)
    }

    @Test func toolCallFormattingToolTypeDetection() {
        #expect(ToolCallFormatting.isReadTool("Read"))
        #expect(ToolCallFormatting.isReadTool("read"))
        #expect(!ToolCallFormatting.isReadTool("bash"))

        #expect(ToolCallFormatting.isWriteTool("Write"))
        #expect(ToolCallFormatting.isWriteTool("write"))
        #expect(!ToolCallFormatting.isWriteTool("bash"))

        #expect(ToolCallFormatting.isEditTool("Edit"))
        #expect(ToolCallFormatting.isEditTool("edit"))
        #expect(!ToolCallFormatting.isEditTool("bash"))
    }
}
