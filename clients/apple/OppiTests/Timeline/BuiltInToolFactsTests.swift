import Foundation
import Testing
@testable import Oppi

@Suite("Built-in inspection compatibility")
@MainActor
struct BuiltInToolFactsTests {
    @Test func oldServerBashUsesNativeTerminalAndSharedConsumers() throws {
        let args: [String: JSONValue] = ["command": "echo old-server"]
        let inspection = ToolContentDescriptorBuilder.inspect(tool: "bash", outputPreview: "old-server",
            isDone: true, context: .init(args: args, outputAvailability: .init(complete: false, totalBytes: 20)))
        #expect(inspection.terminalOutput)
        #expect(inspection.glyph == "dollarsign")
        #expect(inspection.commandText == "echo old-server")
        #expect(inspection.outlineSummary(argsSummary: "") == "$ echo old-server")
        #expect(inspection.availability?.complete == false)
        let row = makeRow(tool: "bash", args: args, output: "old-server")
        guard case .bash(let command, let output, _) = row.expandedContent else { Issue.record("Expected native terminal"); return }
        #expect(command == "echo old-server")
        #expect(output == "old-server")
        #expect(row.glyph == "dollarsign")
        let reducer = TimelineReducer()
        reducer.process(.toolStart(sessionId: "s", toolEventId: "t", tool: "bash", args: args))
        let projection = QuietTimelineProjection.make(items: reducer.items, isQuiet: true, isBusy: true,
            expandedTurnIDs: [], toolInspection: { reducer.toolInspection(for: $0) })
        guard case .quietWork(let line) = projection.rows.first else { Issue.record("Expected terminal bucket"); return }
        #expect(line.buckets == [.init(kind: .terminal, count: 1)])
        let manager = LiveActivityManager()
        manager.sync(connectionId: "c", sessions: [makeTestSession(id: "s", status: .busy)])
        manager.recordEvent(connectionId: "c", event: .toolStart(sessionId: "s", toolEventId: "t", tool: "bash", args: args))
        #expect(manager.currentState.primaryLastActivity == inspection.activityLabel)
    }

    @Test func oldServerReadUsesNativeCodeAndRange() {
        let row = makeRow(tool: "read", args: ["path": "Example.swift", "offset": 5, "limit": 2], output: "let value = 1")
        guard case .code(let text, let language, let startLine, let path) = row.expandedContent else { Issue.record("Expected native code"); return }
        #expect(text == "let value = 1")
        #expect(language == .swift)
        #expect(startLine == 5)
        #expect(path == "Example.swift")
        #expect(row.glyph == "magnifyingglass")
    }

    @Test func oldServerWriteKeepsRequestedBytesAndCurrentFileIntent() {
        let row = makeRow(tool: "write", args: ["path": "New.swift", "content": "let value = 1"], output: "Wrote 13 bytes")
        guard case .code(let text, _, _, _) = row.expandedContent else { Issue.record("Expected requested code"); return }
        #expect(text == "let value = 1")
        #expect(row.trailing == nil)
        #expect(row.glyph == "pencil")
        #expect(row.currentFileOpenIntent?.path == "New.swift")
    }

    @Test func oldServerEditKeepsNativeRequestedDiffAndCounts() throws {
        let args: [String: JSONValue] = ["path": "Example.swift", "edits": [["oldText": "let value = 1", "newText": "let value = 2\nlet extra = 3"]]]
        let row = makeRow(tool: "edit", args: args)
        guard case .diff(let lines, let path) = row.expandedContent else { Issue.record("Expected native diff"); return }
        #expect(!lines.isEmpty)
        #expect(path == "Example.swift")
        #expect(row.glyph == "arrow.left.arrow.right")
        #expect(row.editAdded == 2)
        #expect(row.editRemoved == 1)
        #expect(row.trailing == "Requested")
        let reducer = TimelineReducer()
        reducer.process(.toolStart(sessionId: "s", toolEventId: "t", tool: "edit", args: args))
        reducer.process(.toolEnd(sessionId: "s", toolEventId: "t"))
        let projection = QuietTimelineProjection.make(items: reducer.items, isQuiet: true, isBusy: false,
            expandedTurnIDs: [], toolInspection: { reducer.toolInspection(for: $0) })
        guard case .quietWork(let line) = projection.rows.first else { Issue.record("Expected edit bucket"); return }
        #expect(line.workSummary == "Requested edit +2 −1")
    }

    @Test func oldServerAskSettlesOnceLiveAndAfterReload() throws {
        let args: [String: JSONValue] = ["questions": [["id": "q", "question": "Continue?"]]]
        let answers: JSONValue = ["questions": [["id": "q", "question": "Continue?"]], "answers": ["q": "yes"]]
        let reducer = TimelineReducer()
        reducer.applyExtensionToolsExpanded(true)
        reducer.process(.toolStart(sessionId: "s", toolEventId: "q", tool: "ask", args: args))
        #expect(!reducer.expandedItemIDs.contains("q"))
        let inspection = try #require(reducer.toolInspection(for: reducer.items[0]))
        #expect(inspection.isInteractive)
        #expect(inspection.glyph == "questionmark")
        #expect(makeRow(tool: "ask", args: args).isInteractive)
        let end = AgentEvent.toolEnd(sessionId: "s", toolEventId: "q", details: answers)
        reducer.process(end)
        reducer.process(end)
        #expect(reducer.items.map(\.id) == ["q", "ask-answer-q"])
        reducer.loadSession([
            .init(id: "q", type: .toolCall, timestamp: "2026-10-01T00:00:00Z", tool: "ask", args: args),
            .init(id: "r", type: .toolResult, timestamp: "2026-10-01T00:00:00Z", toolCallId: "q", details: answers)
        ])
        #expect(reducer.items.map(\.id) == ["q", "ask-answer-q"])
    }

    @Test(arguments: ["functions.read", "Read", "put_file", "functions.bash", "BASH", "functions.ask", "codemode"])
    func otherNamesStayGeneric(tool: String) {
        let inspection = ToolContentDescriptorBuilder.inspect(tool: tool,
            context: .init(args: ["path": "Example.swift", "content": "hello", "command": "echo hello"]))
        #expect(inspection.activityKind == .generic)
        #expect(inspection.glyph == nil)
        #expect(inspection.commandText == nil)
        #expect(inspection.file == nil)
        guard case .markdown = inspection.output.first else { Issue.record("Expected generic document"); return }
    }

    @Test(arguments: [false, true])
    func anyProducerFactsSuppressTheFallback(inputOnly: Bool) {
        let inspection = ToolContentDescriptorBuilder.inspect(tool: "bash", context: .init(args: ["command": "echo hello"],
            inputPresentation: inputOnly ? .init(fields: [:]) : nil,
            outputPresentation: inputOnly ? nil : .init(kind: "structured")))
        #expect(!inspection.terminalOutput)
        #expect(inspection.commandText == nil)
        #expect(inspection.glyph == nil)
        #expect(inspection.activityKind == .generic)
    }

    @Test(arguments: ["bash", "ask"])
    func laterProducerFactsReplaceTheCompatibilityView(tool: String) throws {
        let reducer = TimelineReducer()
        reducer.process(.toolStart(sessionId: "s", toolEventId: "t", tool: tool, args: ["command": "echo hello"]))
        #expect(reducer.toolArgsStore.outputPresentation(for: "t") == nil, "Synthetic facts must not become stored producer facts")
        reducer.process(.toolUpdate(sessionId: "s", toolEventId: "t", tool: tool, args: [:], outputPresentation: .init(kind: "structured")))
        let inspection = try #require(reducer.toolInspection(for: reducer.items[0]))
        #expect(inspection.activityKind == .generic)
        #expect(inspection.commandText == nil)
        #expect(!inspection.isInteractive)
        #expect(inspection.outputPresentation?.kind == "structured")
    }

    private func makeRow(tool: String, args: [String: JSONValue], output: String = "") -> ToolTimelineRowConfiguration {
        ToolPresentationBuilder.build(itemID: "t", tool: tool, argsSummary: "", outputPreview: output,
            isError: false, isDone: true,
            context: .init(args: args, expandedItemIDs: ["t"], fullOutput: output, isLoadingOutput: false))
    }
}
