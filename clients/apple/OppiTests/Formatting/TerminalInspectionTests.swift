import Foundation
import Testing
@testable import Oppi

@Suite("Terminal inspection")
@MainActor
struct TerminalInspectionTests {
    private let input = ToolInputPresentation(fields: ["script": .init(role: "command", language: "shell")])
    private let terminal = ToolOutputPresentation(kind: "terminal")
    private let availability = ToolOutputAvailability(complete: false, totalBytes: 200_000, source: "sidecar")

    private func presentation(_ reducer: TimelineReducer, tool: String, done: Bool) -> ToolContentPresentation {
        ToolContentDescriptorBuilder.build(tool: tool, argsSummary: "", outputPreview: "", isError: false, isDone: done,
            context: .init(args: reducer.toolArgsStore.args(for: "tc"), fullOutput: reducer.toolOutputStore.fullOutput(for: "tc"),
                inputPresentation: reducer.toolArgsStore.inputPresentation(for: "tc"),
                previewOnly: !reducer.toolOutputStore.hasCompleteOutput(for: "tc"),
                totalBytes: reducer.toolOutputStore.outputByteCount(for: "tc"),
                outputPresentation: reducer.toolArgsStore.outputPresentation(for: "tc"),
                outputAvailability: reducer.toolArgsStore.outputAvailability(for: "tc")))
    }

    @Test("partial args, start, deltas, replace tail, end and history use the same inspection", arguments: ["bash", "run_thing"])
    func liveAndHistory(tool: String) throws {
        let reducer = TimelineReducer()
        reducer.process(.toolUpdate(sessionId: "s", toolEventId: "tc", tool: tool, args: ["script": "ec"],
                                    inputPresentation: input, outputPresentation: terminal))
        let partial = presentation(reducer, tool: tool, done: false)
        #expect(partial.inspection.commandText == "ec")
        #expect(partial.inspection.terminalOutput)
        #expect(partial.copyOutputText == nil)
        reducer.process(.toolStart(sessionId: "s", toolEventId: "tc", tool: tool, args: ["script": "echo hello"],
                                   inputPresentation: input, outputPresentation: terminal))
        reducer.process(.toolOutput(.init(sessionId: "s", toolEventId: "tc", output: "hello", isError: false)))
        reducer.process(.toolOutput(.init(sessionId: "s", toolEventId: "tc", output: "\nworld\n", isError: false)))
        #expect(presentation(reducer, tool: tool, done: false).copyOutputText == "hello\nworld\n")
        let tail = String(repeating: "tail line\n", count: 950)
        #expect(tail.utf8.count > 8192)
        reducer.process(.toolOutput(.init(sessionId: "s", toolEventId: "tc", output: tail, isError: false,
                                         mode: .replace, truncated: true, totalBytes: 200_000)))
        reducer.process(.toolEnd(sessionId: "s", toolEventId: "tc", outputPresentation: terminal, outputAvailability: availability))
        let live = presentation(reducer, tool: tool, done: true)
        #expect(live.inspection.raw == tail)
        #expect(live.inspection.previewOnly)
        #expect(live.inspection.totalBytes == 200_000)
        #expect(live.copyCommandText == "echo hello")
        let history = TimelineReducer()
        history.loadSession([
            .init(id: "tc", type: .toolCall, timestamp: "2026-09-30T00:00:00Z", tool: tool,
                  args: ["script": "echo hello"], outputPresentation: terminal, inputPresentation: input),
            .init(id: "result", type: .toolResult, timestamp: "2026-09-30T00:00:01Z", output: tail, toolCallId: "tc", outputPresentation: terminal, outputAvailability: availability)
        ])
        #expect(presentation(history, tool: tool, done: true) == live)
        // A completed sidecar fetch, unlike the Pi result, now holds all bytes.
        history.toolOutputStore.replace(String(repeating: "x", count: 200_000), for: "tc")
        #expect(!presentation(history, tool: tool, done: true).inspection.previewOnly)
    }

    @Test("Pi truncation marks an appended result incomplete without a transport tail")
    func resultCompletenessOverridesAppend() {
        let reducer = TimelineReducer()
        reducer.process(.toolStart(sessionId: "s", toolEventId: "tc", tool: "run_thing", args: [:], outputPresentation: terminal))
        reducer.process(.toolOutput(.init(sessionId: "s", toolEventId: "tc", output: "preview", isError: false)))
        #expect(reducer.toolOutputStore.hasCompleteOutput(for: "tc"))
        reducer.process(.toolEnd(sessionId: "s", toolEventId: "tc", outputAvailability: availability))
        #expect(reducer.toolOutputStore.hasPreviewOnlyOutput(for: "tc"))
        #expect(reducer.toolOutputStore.outputByteCount(for: "tc") == 200_000)
    }

    @Test("undeclared aliases and future producer kinds remain generic", arguments: [nil, ToolOutputPresentation(kind: "future")])
    func oldServerAliasAndUnknownProducerKind(fact: ToolOutputPresentation?) {
        let tool = fact == nil ? "functions.bash" : "bash"
        let result = ToolContentDescriptorBuilder.build(tool: tool, argsSummary: "command: echo hi", outputPreview: "hi",
            isError: false, isDone: true, context: .init(args: ["command": "echo hi"], outputPresentation: fact))
        guard case .markdown(let document) = result.content else { Issue.record("Expected generic document"); return }
        #expect(document.text.contains("echo hi"))
        #expect(document.text.contains("hi"))
        #expect(result.copyCommandText == nil)
        #expect(!result.inspection.terminalOutput)
        var context = ToolPresentationBuilder.Context(args: ["command": "echo hi"], expandedItemIDs: ["tc"], fullOutput: "hi", isLoadingOutput: false,
            callSegments: [.init(text: "$ ", style: .bold), .init(text: "echo hi", style: .accent)])
        context.outputPresentation = fact
        let config = ToolPresentationBuilder.build(itemID: "tc", tool: tool, argsSummary: "", outputPreview: "hi", isError: false, isDone: true, context: context)
        #expect(config.glyph == nil)
        #expect(config.segmentAttributedTitle?.string == "$ echo hi")
        guard case .notebook(let cell) = config.expandedContent else { Issue.record("Expected generic cell, not command panel"); return }
        #expect(cell.sources.first?.code == "command: echo hi")
        #expect(cell.output == .stdout("hi"))
    }

    @Test("structured result override clears terminal glyph and panel but retains dollar summary text")
    func structuredResultOverride() throws {
        let reducer = TimelineReducer()
        let segments: [StyledSegment] = [.init(text: "$ ", style: .bold), .init(text: "Producer summary", style: .accent)]
        reducer.process(.toolStart(sessionId: "s", toolEventId: "tc", tool: "bash", args: ["script": "echo hello"],
            callSegments: segments, inputPresentation: input, outputPresentation: terminal))
        let details: JSONValue = .object(["expandedText": .string("Structured result"), "presentationFormat": .string("markdown"),
            "outputPresentation": .object(["kind": .string("structured")])])
        reducer.process(.toolEnd(sessionId: "s", toolEventId: "tc", details: details,
            outputPresentation: .init(kind: "structured")))
        var context = ToolPresentationBuilder.Context(args: reducer.toolArgsStore.args(for: "tc"), details: details,
            expandedItemIDs: ["tc"], fullOutput: "", isLoadingOutput: false,
            callSegments: reducer.toolSegmentStore.callSegments(for: "tc"))
        context.inputPresentation = reducer.toolArgsStore.inputPresentation(for: "tc")
        context.outputPresentation = reducer.toolArgsStore.outputPresentation(for: "tc")
        let config = ToolPresentationBuilder.build(itemID: "tc", tool: "bash", argsSummary: "", outputPreview: "", isError: false, isDone: true, context: context)
        #expect(config.glyph == nil)
        #expect(config.segmentAttributedTitle?.string == "$ Producer summary")
        guard case .notebook(let cell) = config.expandedContent else { Issue.record("Expected generic cell, not command panel"); return }
        #expect(cell.output == .rich("Structured result"))
    }

    @Test("arbitrary tool paints the same command panel, segments and terminal as bash")
    func arbitraryNamePaintsIdentically() throws {
        var context = ToolPresentationBuilder.Context(args: ["script": "'quoted'\nnext"], expandedItemIDs: ["tc"],
            fullOutput: "line\n", isLoadingOutput: false, callSegments: [.init(text: "$ ", style: .bold), .init(text: "Server summary", style: .accent)])
        context.inputPresentation = input
        context.outputPresentation = terminal
        let configs = ["bash", "run_thing"].map { tool in
            ToolPresentationBuilder.build(itemID: "tc", tool: tool, argsSummary: "ignored", outputPreview: "", isError: false, isDone: false, context: context)
        }
        for config in configs {
            #expect(config.toolNamePrefix == "$")
            #expect(config.glyph == "dollarsign")
            #expect(config.segmentAttributedTitle?.string == "Server summary")
            guard case .bash(let command, let output, let unwrapped) = config.expandedContent else { Issue.record("Expected terminal painter"); return }
            #expect(command == "'quoted'\nnext")
            #expect(output == "line\n")
            #expect(unwrapped)
        }
        #expect(configs[0].title == configs[1].title)
    }

    @Test("live availability survives decode, correlation and coalescing; final inline output matches history", arguments: [false, true])
    func livePreviewSourceHandoff(batched: Bool) throws {
        let reducer = TimelineReducer()
        let coalescer = DeltaCoalescer()
        coalescer.onFlush = { events in
            if batched { reducer.processBatch(events) }
            else { for event in events { reducer.process(event) } }
        }
        let correlator = ToolCallCorrelator()
        coalescer.receive(correlator.start(sessionId: "s", tool: "run_thing", args: ["script": "emit fixture"], toolCallId: "tc",
            inputPresentation: input, outputPresentation: terminal))
        let json = #"{"type":"tool_output","toolCallId":"tc","output":"tail","mode":"replace","truncated":true,"totalBytes":20480,"outputAvailability":{"complete":false,"totalBytes":20480,"source":"sidecar"}}"#
        let message = try ServerMessage.decode(from: json)
        guard case .toolOutput(let text, let error, let id, let mode, let truncated, let bytes, let details, let source, _, _) = message else {
            Issue.record("Expected preview output"); return
        }
        coalescer.receive(correlator.output(sessionId: "s", output: text, isError: error, toolCallId: id, mode: mode,
            truncated: truncated, totalBytes: bytes, details: details, outputAvailability: source))
        // Consecutive replacement coalescing must retain optional source facts.
        coalescer.receive(correlator.output(sessionId: "s", output: "latest tail", isError: false, toolCallId: "tc", mode: .replace,
            truncated: true, totalBytes: bytes))
        coalescer.flushNow()
        #expect(reducer.toolArgsStore.outputAvailability(for: "tc")?.hasSidecar == true)
        #expect(reducer.toolOutputStore.hasPreviewOnlyOutput(for: "tc"))
        let full = String(repeating: "x", count: 20 * 1024)
        let complete = ToolOutputAvailability(complete: true)
        coalescer.receive(correlator.output(sessionId: "s", output: full, isError: false, toolCallId: "tc", mode: .replace,
            outputAvailability: complete))
        coalescer.receive(correlator.end(sessionId: "s", toolCallId: "tc", outputAvailability: complete))
        #expect(reducer.toolOutputStore.fullOutput(for: "tc") == full)
        #expect(!reducer.toolOutputStore.hasPreviewOnlyOutput(for: "tc"))
        #expect(reducer.toolArgsStore.outputAvailability(for: "tc") == complete)
    }

    @Test("wire facts tolerate missing, malformed and future values")
    func tolerantCodable() throws {
        let data = Data(#"{"type":"tool_start","tool":"run_thing","args":{},"inputPresentation":{"fields":{"script":{"role":"command","language":"shell"}}},"outputPresentation":{"kind":"terminal"}}"#.utf8)
        let message = try ServerMessage.decode(from: String(decoding: data, as: UTF8.self))
        guard case .toolStart(_, _, _, _, let fields, _, let kind, _) = message else { Issue.record("Expected start"); return }
        #expect(fields == input)
        #expect(kind == terminal)
        let decoder = JSONDecoder()
        #expect(try decoder.decode(ToolOutputPresentation.self, from: Data(#"{"kind":7}"#.utf8)).kind == "")
        #expect(try decoder.decode(ToolInputPresentation.self, from: Data(#"{"fields":7}"#.utf8)).fields.isEmpty)
        let malformed = try decoder.decode(ToolOutputAvailability.self, from: Data(#"{"complete":"yes","totalBytes":-1,"source":"future"}"#.utf8))
        #expect(!malformed.complete && malformed.totalBytes == nil && !malformed.hasSidecar)
        #expect(try decoder.decode(ToolOutputAvailability.self, from: JSONEncoder().encode(availability)) == availability)
    }
}
