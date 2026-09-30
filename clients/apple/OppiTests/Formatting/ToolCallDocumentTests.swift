import Foundation
import Testing
@testable import Oppi

@Suite("OrderedJSON")
struct OrderedJSONTests {
    @Test func keepsOrderAndNumberLexemes() throws {
        let json = try #require(OrderedJSON.parse(#"{"z":1.00e+02,"a":-0,"m":12345678901234567890}"#))
        #expect(json.json() == #"{"z":1.00e+02,"a":-0,"m":12345678901234567890}"#)
        #expect(json.json(pretty: true).hasPrefix("{\n  \"z\": 1.00e+02"))
    }
    @Test func decodesEscapesAndSurrogates() throws {
        let json = try #require(OrderedJSON.parse(#""\uD83C\uDFC3\n\t\"\\\/\b\f\r""#))
        #expect(json.scalar == "🏃\n\t\"\\/\u{8}\u{c}\r")
        #expect(OrderedJSON.parse(json.json()) == json)
    }
    @Test(arguments: ["", "[1,]", "{\"a\":1,}", "01", "1.", "+1", "1e", "true false", #""\uD800""#, #""\uDC00""#, #""\q""#, "\"unclosed", "\"\n\"", "{a:1}"])
    func rejectsInvalidJSON(_ text: String) { #expect(OrderedJSON.parse(text) == nil) }
    @Test func budgetsSizeAndDepth() {
        #expect(OrderedJSON.parse("\"" + String(repeating: "a", count: 65536) + "\"") == nil)
        #expect(OrderedJSON.parse(String(repeating: "[", count: 66) + "0" + String(repeating: "]", count: 66)) == nil)
        #expect(OrderedJSON.parse("[" + Array(repeating: "0", count: 16_384).joined(separator: ",") + "]") == nil)
    }
}

@Suite("ToolCallDocument")
struct ToolCallDocumentTests {
    private func doc(_ output: String = "", args: [String: JSONValue] = [:], hints: ToolInputPresentation? = nil,
                     calls: NestedToolCalls? = nil, details: JSONValue? = nil, done: Bool = true) throws -> ToolContentDescriptor.Markdown {
        try #require(ToolCallDocumentBuilder.build(args: args, inputPresentation: hints, nestedCalls: calls,
            output: output, rawOutput: output, details: details, isDone: done))
    }
    @Test func inputFormsCodeFirstAndRawKeepsEmptyFields() throws {
        let d = try doc("ok", args: ["z": .number(2), "a": .string("a|b"), "empty": .string(""), "null": .null,
                                     "source": .string("text(1);"), "multi": .string("one\ntwo"), "nested": .array([1])],
                        hints: .init(codeFields: ["source": "javascript"]))
        #expect(d.text.contains("## Input\n\n**source**\n\n```javascript\ntext(1);"))
        #expect(d.text.contains("| a | a\\|b |\n| z | 2 |"))
        #expect(d.text.contains("**multi**\n\n```text\none\ntwo"))
        #expect(d.text.contains("**nested**\n\n```json"))
        #expect(!d.text.contains("empty")); #expect(!d.text.contains("null"))
        #expect(d.rawText?.contains("\"empty\": \"\"") == true)
        #expect(d.rawText?.contains("\"null\": null") == true)
    }
    @Test func sectionLabelsAndPending() throws {
        #expect(try doc("ok").text == "```text\nok\n```")
        #expect(try doc(args: ["source": "text(1)"], hints: .init(codeFields: ["source": "javascript"])).text == "```javascript\ntext(1)\n```")
        #expect(try doc(args: ["x": 1], done: false).text.contains("## Output\n\nWaiting for output…"))
        #expect(ToolCallDocumentBuilder.build(args: nil, inputPresentation: nil, nestedCalls: nil, output: "", rawOutput: "", details: nil, isDone: true) == nil)
    }
    @Test func mcpAndSettledUnwrapRecursively() throws {
        let output = #"[{"status":"fulfilled","value":{"content":[{"type":"text","text":"\"Track Run\\nTime: 50:53\""}],"isError":false}},{"status":"fulfilled","value":{"content":[{"type":"text","text":"{\"z\":1,\"a\":2}"}]}},{"status":"rejected","reason":"failed"}]"#
        let d = try doc(output)
        #expect(d.text.contains("```text\n   Track Run\n   Time: 50:53"))
        #expect(d.text.contains("| z | 1 |\n   | a | 2 |"))
        #expect(d.text.contains("✗ Error")); #expect(d.text.contains("failed"))
        #expect(!d.text.contains("fulfilled")); #expect(!d.text.contains("\\n"))
    }
    @Test func mcpStructuredContentAndMediaError() throws {
        let d = try doc(#"{"content":[{"type":"text","text":"ignored"}],"structuredContent":{"answer":42},"isError":true}"#)
        #expect(d.text.contains("✗ Error")); #expect(d.text.contains("| answer | 42 |")); #expect(!d.text.contains("ignored"))
        let media = try doc(#"{"content":[{"type":"image","mimeType":"image/png"},{"type":"resource_link","name":"Report","uri":"file:///report"},{"type":"resource","resource":{"uri":"file:///note","text":"hello"}}]}"#)
        #expect(media.text.contains("image image/png")); #expect(media.text.contains("Report · file:///report")); #expect(media.text.contains("hello"))
    }
    @Test func preambleAndFirstSeenTableColumns() throws {
        let d = try doc("Script completed\nWall time 1.6 seconds\nOutput:\n\n[{\"z\":1,\"a\":2},{\"a\":3,\"b\":4}]")
        #expect(d.text.hasPrefix("Script completed  \nWall time 1.6 seconds  \nOutput:"))
        #expect(d.text.contains("| z | a | b |\n| --- | --- | --- |\n| 1 | 2 |  |\n|  | 3 | 4 |"))
        #expect(try doc("header\n{invalid}").text.contains("```text"))
    }
    @Test func matrixScalarArraysAndEmptyMarkers() throws {
        #expect(try doc("[[1,2],[3,4]]").text.contains("| 1 | 2 |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |"))
        #expect(try doc("[1,true,null]").text == "- 1\n- true\n- null")
        #expect(try doc("[]").text == "(empty array)")
        #expect(try doc("{}").text == "(empty object)")
    }
    @Test func multilineScalarsRemainBulletItems() throws {
        let blocks = parseCommonMark(try doc(#"["one\ntwo",3,true]"#).text)
        guard case .unorderedList(let items) = try #require(blocks.first) else {
            Issue.record("Scalar arrays must remain bullet lists, including multiline strings")
            return
        }
        #expect(items.count == 3)
        #expect(items[0] == [.codeBlock(language: "text", code: "one\ntwo")])
        #expect(items[1] == [.paragraph([.text("3")])])
        #expect(items[2] == [.paragraph([.text("true")])])
    }
    @Test func misleadingPreambleStartsRemainBoundedAndPreserved() throws {
        let output = "Header\n" + String(repeating: "[\n", count: 15_000) + "invalid"
        let d = try doc(output)
        #expect(parseCommonMark(d.text) == [.codeBlock(language: "text", code: output)])
        #expect(d.rawText?.hasSuffix(output) == true)
        #expect(try doc("Header\n  \n  {\"answer\":42}").text.contains("| answer | 42 |"))
    }
    @Test func inputFieldCapIncludesCodeAndMultilineFields() throws {
        let args = Dictionary(uniqueKeysWithValues: (0..<205).map { (String(format: "field%03d", $0), JSONValue.string("one\ntwo")) })
        let hints = ToolInputPresentation(codeFields: Dictionary(uniqueKeysWithValues: args.keys.map { ($0, "javascript") }))
        let d = try doc(args: args, hints: hints)
        #expect(parseCommonMark(d.text).filter { if case .codeBlock = $0 { return true }; return false }.count == 200)
        #expect(d.text.contains("… 5 more fields"))
        #expect(!d.text.contains("field204"))
        #expect(d.rawText?.contains("field204") == true)
    }
    @Test func presentationMetadataOnlyAppliesToExpandedText() throws {
        let details: JSONValue = .object(["presentationFormat": "terminal"])
        let blocks = parseCommonMark(try doc(#"{"answer":42}"#, details: details).text)
        #expect(blocks == [.table(headers: [[.text("Field")], [.text("Value")]], rows: [[[.text("answer")], [.text("42")]]])])
        let expanded: JSONValue = .object(["presentationFormat": "terminal", "expandedText": #"{"answer":42}"#])
        #expect(parseCommonMark(try doc("ignored", details: expanded).text) == [.codeBlock(language: "text", code: "{\"answer\":42}")])
    }
    @Test func fencesAndInlineEscapes() throws {
        #expect(ToolCallDocumentBuilder.fence("```\ncode", language: "text") == "````text\n```\ncode\n````")
        #expect(try doc(#"{"a|b":"*bold* [link](url)"}"#).text.contains("| a\\|b | \\*bold\\* \\[link\\](url) |"))
    }
    @Test func capsAndRaw() throws {
        let many = "[" + (0..<205).map(String.init).joined(separator: ",") + "]"
        #expect(try doc(many).text.contains("… 5 more"))
        let long = String(repeating: "x", count: 70000)
        let d = try doc(long)
        #expect(d.text.utf8.count < 66000); #expect(d.text.contains("Preview limited to 64 KB"))
        #expect(d.rawText?.hasSuffix(long) == true)
        let deep = #"{"a":{"b":{"c":{"d":{"z":1,"a":2}}}}}"#
        #expect(try doc(deep).text.contains("```json"))
    }
    @Test func nestedCallsStatusSizeDurationsAndErrors() throws {
        let calls = NestedToolCalls(calls: [
            .init(id: "1", name: "first", arguments: ["a": 1], status: "ok", durationMs: 999),
            .init(id: "2", name: "second", argumentsBytes: 10000, status: "error", durationMs: 1528, error: "bad\ninput"),
            .init(id: "3", name: "third", status: "future-status")], complete: false)
        let text = try doc("ok", calls: calls).text
        #expect(text.contains("✓ first")); #expect(text.contains("999 ms")); #expect(text.contains("1.5 s"))
        #expect(text.contains("10000 bytes")); #expect(text.contains("bad")); #expect(text.contains("… third"))
        #expect(text.contains("Some calls not recorded."))
    }
    @Test func expandedTextWinsAndTuiIsOnlyEmptyFallback() throws {
        let details: JSONValue = .object(["expandedText": "# Human", "presentationFormat": "markdown", "tuiRender": .object(["expandedText": "terminal snapshot"])])
        #expect(try doc("raw", details: details).text == "# Human")
        #expect(try doc("raw", details: .object(["tuiRender": .object(["expandedText": "snapshot"])])).text == "```text\nraw\n```")
        #expect(try doc(details: .object(["tuiRender": .object(["expandedText": "\u{1b}[31mfallback"])] )).text == "```text\nfallback\n```")
    }

    @Test @MainActor func fullScreenUsesSameDocumentAndRawToggle() throws {
        var context = ToolPresentationBuilder.Context(args: ["source": "text(1)", "unused": .null],
            expandedItemIDs: ["t"], fullOutput: "{\"z\":1}", isLoadingOutput: false)
        context.inputPresentation = .init(codeFields: ["source": "javascript"])
        let config = ToolPresentationBuilder.build(itemID: "t", tool: "arbitrary", argsSummary: "",
            outputPreview: "", isError: false, isDone: true, context: context)
        let content = try #require(ToolTimelineRowFullScreenSupport.staticFullScreenContent(
            configuration: config, outputCopyText: nil, terminalStream: nil))
        guard case .markdown(let document, _, _, let raw) = content,
              case .markdown(let inline, _) = config.expandedContent else { Issue.record("Markdown reader"); return }
        #expect(document == inline)
        #expect(raw == config.rawMarkdownText)
        let controller = FullScreenCodeViewController(content: content)
        controller.loadViewIfNeeded()
        controller.toggleSourceForTesting()
        guard case .plainText(let rawBody, _) = controller.presentationBodyContentForTesting else { Issue.record("Raw body"); return }
        #expect(rawBody == raw)
        #expect(rawBody.contains("\"unused\": null"))
        #expect(rawBody.hasSuffix("{\"z\":1}"))
        controller.toggleSourceForTesting()
        guard case .markdown(let rendered, _, _, _) = controller.presentationBodyContentForTesting else { Issue.record("Rendered body"); return }
        #expect(rendered == inline)
    }

    @Test @MainActor func protocolReducerHistoryAndDescriptorParity() throws {
        let start = try ServerMessage.decode(from: #"{"type":"tool_start","tool":"arbitrary","toolCallId":"t","args":{"source":"text(1)"},"inputPresentation":{"codeFields":{"source":"javascript"}}}"#)
        let end = try ServerMessage.decode(from: #"{"type":"tool_end","tool":"arbitrary","toolCallId":"t","nestedCalls":{"calls":[{"id":"t/1","name":"nested","status":"future"}],"complete":false}}"#)
        let live = TimelineReducer(); let correlator = ToolCallCorrelator()
        guard case .toolStart(let tool, let args, let id, let segments, let hints) = start,
              case .toolEnd(_, _, _, _, _, let nested) = end else { Issue.record("protocol case"); return }
        live.process(correlator.start(sessionId: "s", tool: tool, args: args, toolCallId: id, callSegments: segments, inputPresentation: hints))
        live.process(correlator.output(sessionId: "s", output: #"{"z":1,"a":2}"#, isError: false, toolCallId: "t"))
        live.process(correlator.end(sessionId: "s", toolCallId: "t"))
        live.process(correlator.end(sessionId: "s", toolCallId: "t", nestedCalls: nested))
        let history = TimelineReducer()
        history.loadSession([.init(id: "t", type: .toolCall, timestamp: "2026-09-30T15:20:00Z", tool: tool, args: args, inputPresentation: hints),
                             .init(id: "r", type: .toolResult, timestamp: "2026-09-30T15:20:01Z", output: #"{"z":1,"a":2}"#, toolCallId: "t", nestedCalls: nested)])
        func presentation(_ r: TimelineReducer) -> ToolContentPresentation {
            ToolContentDescriptorBuilder.build(tool: tool, argsSummary: "", outputPreview: "", isError: false, isDone: true,
                context: .init(args: r.toolArgsStore.args(for: "t"), fullOutput: r.toolOutputStore.fullOutput(for: "t"),
                               inputPresentation: r.toolArgsStore.inputPresentation(for: "t"), nestedCalls: r.toolDetailsStore.nestedCalls(for: "t")))
        }
        #expect(presentation(live) == presentation(history))
        #expect(presentation(live).copyOutputText == #"{"z":1,"a":2}"#)
        guard case .markdown(let d) = presentation(live).content else { Issue.record("document descriptor"); return }
        #expect(d.text.contains("```javascript")); #expect(d.text.contains("… nested")); #expect(d.rawText != nil)
    }
}
