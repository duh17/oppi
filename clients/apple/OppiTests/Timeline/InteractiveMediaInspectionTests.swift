import Foundation
import Testing
@testable import Oppi

@Suite("Interactive/media inspection")
@MainActor
struct InteractiveMediaInspectionTests {
    private let interaction = ToolOutputPresentation(kind: "interactive")
    private let args: [String: JSONValue] = ["questions": .array([.object(["id": "q", "question": "Continue?"])])]
    private let answers: JSONValue = ["questions": [["id": "q", "question": "Continue?"]], "answers": ["q": "yes"]]
    private let timestamp = "2026-10-01T00:00:00.000Z"

    @Test(arguments: ["ask", "choose_next"])
    func interactionSettlesOnceAndReloads(tool: String) throws {
        let reducer = TimelineReducer()
        reducer.applyExtensionToolsExpanded(true)
        reducer.process(.toolStart(sessionId: "s", toolEventId: "q", tool: tool, args: args, outputPresentation: interaction))
        #expect(reducer.items.count == 1)
        #expect(!reducer.expandedItemIDs.contains("q"))
        let end = AgentEvent.toolEnd(sessionId: "s", toolEventId: "q", details: answers, outputPresentation: interaction)
        reducer.process(end)
        reducer.process(end)
        #expect(reducer.items.map(\.id) == ["q", "ask-answer-q"])
        #expect(reducer.hasUserMessage(matching: "**Q:** Continue?\n**A:** yes"))
        reducer.loadSession([
            .init(id: "q", type: .toolCall, timestamp: timestamp, tool: tool, args: args, outputPresentation: interaction),
            .init(id: "r", type: .toolResult, timestamp: timestamp, toolCallId: "q", details: answers, outputPresentation: interaction)
        ])
        #expect(reducer.items.map(\.id) == ["q", "ask-answer-q"])
        reducer.process(end)
        #expect(reducer.items.count == 2)
        let presentation = ToolContentDescriptorBuilder.build(tool: tool, argsSummary: "", outputPreview: "", isError: false, isDone: true,
            context: .init(args: args, details: answers, outputPresentation: interaction))
        guard case .markdown(let document) = presentation.content else { Issue.record("Expected inspectable Input/Output"); return }
        #expect(document.text.contains("## Input"))
        #expect(document.text.contains("## Output"))
        #expect(document.text.contains("Continue?"))
    }

    @Test(arguments: ["Ask", "voice_speak", "functions.ask"])
    func oldServerUsesGenericInspection(tool: String) {
        let reducer = TimelineReducer()
        reducer.process(.toolStart(sessionId: "s", toolEventId: "q", tool: tool, args: args))
        reducer.process(.toolEnd(sessionId: "s", toolEventId: "q", details: answers))
        #expect(reducer.items.map(\.id) == ["q"])
        let presentation = ToolContentDescriptorBuilder.build(tool: tool, argsSummary: "", outputPreview: "hello", isError: false, isDone: true,
            context: .init(args: args))
        guard case .markdown = presentation.content else { Issue.record("Expected generic document"); return }
        #expect(ToolContentDescriptorBuilder.glyph(input: nil, output: nil, details: nil) == nil)
    }

    @Test(arguments: [false, true])
    func mediaKeepsInputAndCalls(audio: Bool) {
        let details: JSONValue = audio
            ? ["kind": "audio_presentation", "text": "Hello", "audio": ["kind": "audio", "id": "audio-1", "mimeType": "audio/wav"]]
            : ["image": ["kind": "image", "id": "image-1", "mimeType": "image/png"]]
        let calls = NestedToolCalls(calls: [.init(id: "c", name: "raw", display: .init(title: "Lookup", verbatim: true), status: "ok")], complete: true)
        let result = ToolContentDescriptorBuilder.build(tool: "arbitrary", argsSummary: "", outputPreview: "Hello", isError: false, isDone: true,
            context: .init(args: ["prompt": "Draw a cat"], details: details, nestedCalls: calls))
        #expect(result.inspection.input.first?.name == "prompt")
        #expect(result.inspection.calls == calls)
        #expect(result.inspection.supplement?.text.contains("## Input") == true)
        #expect(result.inspection.supplement?.text.contains("## Calls") == true)
        #expect(result.inspection.supplement?.text.contains("Lookup") == true)
        guard case .media(let media) = result.content else { Issue.record("Expected native media"); return }
        if audio { #expect(media.audio?.attachmentId == "audio-1") } else { #expect(media.attachments.map(\.id) == ["image-1"]) }
    }

    @Test func fileMediaKeepsInputAndCalls() {
        let result = ToolContentDescriptorBuilder.build(tool: "fetch_picture", argsSummary: "", outputPreview: "Image result", isError: false, isDone: true,
            context: .init(args: ["path": "image.png"],
                inputPresentation: .init(fields: ["path": .init(role: "filePath")]),
                nestedCalls: .init(calls: [.init(id: "c", name: "lookup", status: "ok")], complete: true),
                outputPresentation: .init(kind: "fileContent", provenance: "result")))
        guard case .file(let file) = result.content else { Issue.record("Expected native file media"); return }
        #expect(file.fileType == .image)
        #expect(result.inspection.supplement?.text.contains("image.png") != true)
        #expect(result.inspection.supplement?.text.contains("## Input") != true)
        #expect(result.inspection.supplement?.text.contains("## Calls") == true)
    }

    @Test func imageReadDoesNotRepeatHeaderPath() {
        let path = "/Users/chenda/workspace/oppi/.internal/release-notes/artifacts/build-53-whats-new-light-v2.png"
        let result = ToolContentDescriptorBuilder.build(tool: "read", argsSummary: "", outputPreview: "Read image file [image/png]",
            isError: false, isDone: true,
            context: .init(args: ["path": .string(path)], fullOutput: "Read image file [image/png]"))
        guard case .file(let file) = result.content else { Issue.record("Expected image read"); return }
        #expect(file.fileType == .image)
        #expect(file.filePath == path)
        #expect(result.inspection.supplement == nil)
    }

    @Test func imageReadKeepsInputThatIsNotTheHeaderPath() {
        let result = ToolContentDescriptorBuilder.build(tool: "fetch_picture", argsSummary: "", outputPreview: "Image result",
            isError: false, isDone: true,
            context: .init(args: ["path": .string("image.png"), "page": .number(2)],
                inputPresentation: .init(fields: ["path": .init(role: "filePath")]),
                outputPresentation: .init(kind: "fileContent", provenance: "result")))
        let text = result.inspection.supplement?.text ?? ""
        #expect(text.contains("page"))
        #expect(text.contains("2"))
        #expect(!text.contains("image.png"))
    }

    @Test(arguments: [false, true])
    func nestedInterleavingIsOneRowAndCanonicalAfterReload(batched: Bool) throws {
        let reducer = TimelineReducer()
        let coalescer = DeltaCoalescer()
        coalescer.onFlush = { reducer.processBatch($0) }
        func send(_ event: AgentEvent) {
            if batched { coalescer.receive(event) } else { reducer.process(event) }
        }
        send(.toolStart(sessionId: "s", toolEventId: "p", tool: "codemode", args: ["code": "await a(); await b()" ]))
        send(.toolStart(sessionId: "s", toolEventId: "a", tool: "mcp__alpha__a", args: ["query": "first"], display: .init(title: "First call", verbatim: true), parentToolCallId: "p"))
        send(.toolStart(sessionId: "s", toolEventId: "b", tool: "mcp__beta__b", args: [:], parentToolCallId: "p"))
        send(.toolUpdate(sessionId: "s", toolEventId: "a", tool: "mcp__alpha__a", args: ["query": "updated"], parentToolCallId: "p"))
        send(.toolOutput(.init(sessionId: "s", toolEventId: "b", output: "child output", isError: false, parentToolCallId: "p")))
        coalescer.flushNow()
        #expect(reducer.items.map(\.id) == ["p"])
        #expect(reducer.toolDetailsStore.nestedCalls(for: "p")?.calls.map(\.status) == ["running", "running"])
        #expect(reducer.toolDetailsStore.nestedCalls(for: "p")?.calls.first?.arguments?["query"] == "updated")
        #expect(reducer.toolOutputStore.fullOutput(for: "b").isEmpty)
        send(.toolEnd(sessionId: "s", toolEventId: "b", isError: true, parentToolCallId: "p"))
        send(.toolEnd(sessionId: "s", toolEventId: "a", parentToolCallId: "p"))
        coalescer.flushNow()
        let live = try #require(reducer.toolDetailsStore.nestedCalls(for: "p"))
        #expect(live.calls.map(\.status) == ["ok", "error"])
        #expect(live.calls.allSatisfy { $0.durationMs != nil })
        let canonical = NestedToolCalls(calls: [
            .init(id: "a", name: "mcp__alpha__a", display: .init(title: "First call", verbatim: true), arguments: ["query": "updated"], status: "ok", durationMs: 15),
            .init(id: "b", name: "mcp__beta__b", status: "error", durationMs: 20, error: "Unavailable")
        ], complete: true)
        send(.toolEnd(sessionId: "s", toolEventId: "p", nestedCalls: canonical))
        // Plausible replay: a child start/output arrive after parent completion.
        send(.toolStart(sessionId: "s", toolEventId: "a", tool: "mcp__alpha__a", args: [:], parentToolCallId: "p"))
        coalescer.flushNow()
        #expect(reducer.items.map(\.id) == ["p"])
        #expect(reducer.toolDetailsStore.nestedCalls(for: "p") == canonical)
        reducer.loadSession([
            .init(id: "p", type: .toolCall, timestamp: timestamp, tool: "codemode", args: ["code": "await a(); await b()"]),
            .init(id: "r", type: .toolResult, timestamp: timestamp, toolCallId: "p", nestedCalls: canonical)
        ])
        #expect(reducer.items.map(\.id) == ["p"])
        #expect(reducer.toolDetailsStore.nestedCalls(for: "p") == canonical)
    }

    @Test func grandchildBeforeIntermediateStartIsRehomed() throws {
        let reducer = TimelineReducer()
        reducer.process(.toolStart(sessionId: "s", toolEventId: "root", tool: "runner", args: [:]))
        reducer.process(.toolStart(sessionId: "s", toolEventId: "grandchild", tool: "lookup", args: [:], parentToolCallId: "middle"))
        reducer.process(.toolEnd(sessionId: "s", toolEventId: "grandchild", parentToolCallId: "middle"))
        reducer.process(.toolStart(sessionId: "s", toolEventId: "middle", tool: "runner", args: [:], parentToolCallId: "root"))
        let calls = try #require(reducer.toolDetailsStore.nestedCalls(for: "root"))
        #expect(Set(calls.calls.map(\.id)) == ["middle", "grandchild"])
        #expect(calls.calls.first { $0.id == "grandchild" }?.status == "ok")
        #expect(reducer.items.map(\.id) == ["root"])
    }

    @Test func droppedLiveCallsRemainIncompleteAfterParentEnd() throws {
        let reducer = TimelineReducer()
        reducer.process(.toolStart(sessionId: "s", toolEventId: "root", tool: "runner", args: [:]))
        for index in 0..<257 {
            reducer.process(.toolStart(sessionId: "s", toolEventId: "c-\(index)", tool: "lookup", args: [:], parentToolCallId: "root"))
        }
        reducer.process(.toolEnd(sessionId: "s", toolEventId: "root"))
        let calls = try #require(reducer.toolDetailsStore.nestedCalls(for: "root"))
        #expect(calls.calls.count == 256)
        #expect(!calls.complete)
    }

    @Test func tolerantParentDecodingAndLegacyCorrelatorRemainSafe() throws {
        let decoded = try ServerMessage.decode(from: #"{"type":"tool_start","tool":"raw","toolCallId":"c","parentToolCallId":"p","args":{}}"#)
        guard case .toolStart(_, _, _, _, _, _, _, let parent) = decoded else { Issue.record("Expected start"); return }
        #expect(parent == "p")
        let malformed = try ServerMessage.decode(from: #"{"type":"tool_end","tool":"raw","parentToolCallId":42}"#)
        guard case .toolEnd(_, _, _, _, _, _, _, _, let missing, _) = malformed else { Issue.record("Expected end"); return }
        #expect(missing == nil)
        let correlator = ToolCallCorrelator()
        _ = correlator.start(sessionId: "s", tool: "parent", args: [:], toolCallId: "p")
        _ = correlator.start(sessionId: "s", tool: "child", args: [:], toolCallId: "c", parentToolCallId: "p")
        _ = correlator.end(sessionId: "s", toolCallId: "c", parentToolCallId: "p")
        guard case .toolOutput(let fallback) = correlator.output(sessionId: "s", output: "parent", isError: false) else { Issue.record("Expected output"); return }
        #expect(fallback.toolEventId == "p")
    }
}
