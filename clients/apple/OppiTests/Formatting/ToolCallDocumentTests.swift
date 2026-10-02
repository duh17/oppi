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
                        hints: .init(fields: ["source": .init(role: "code", language: "javascript")]))
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
        #expect(try doc(args: ["source": "text(1)"], hints: .init(fields: ["source": .init(role: "code", language: "javascript")])).text == "```javascript\ntext(1)\n```")
        #expect(try doc(args: ["x": 1], done: false).text.contains("## Output\n\nWaiting for output…"))
        #expect(ToolCallDocumentBuilder.build(args: nil, inputPresentation: nil, nestedCalls: nil, output: "", rawOutput: "", details: nil, isDone: true) == nil)
    }
    @Test @MainActor func runningEmptyPreviewShowsWaitingInsteadOfStoppedSessionNotice() throws {
        let args: [String: JSONValue] = ["requestId": "waiting-check"]
        let document = try #require(ToolCallDocumentBuilder.build(args: args, inputPresentation: nil, nestedCalls: nil,
            output: "", rawOutput: "", details: nil, isDone: false, previewOnly: true))
        #expect(document.text.contains("## Output\n\nWaiting for output…"))
        #expect(!document.text.contains("Output preview only"))
        #expect(document.rawText?.contains("Output preview only") == false)
        var context = ToolPresentationBuilder.Context(args: args, expandedItemIDs: ["t"], fullOutput: "", isLoadingOutput: false)
        context.previewOnly = true
        let config = ToolPresentationBuilder.build(itemID: "t", tool: "generic_probe", argsSummary: "", outputPreview: "",
            isError: false, isDone: false, context: context)
        guard case .markdown(let rendered, _) = config.expandedContent else { Issue.record("Running document"); return }
        #expect(rendered == document.text)
        #expect(!config.isDone)
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
    @Test(arguments: [
        #"{"content":[],"count":42}"#,
        #"{"type":"doc","content":[{"type":"paragraph"}]}"#,
        #"{"content":[{"type":"text","text":"hello"}],"count":42}"#
    ])
    func nonMCPContentKeepsSiblingFields(_ output: String) throws {
        let text = try doc(output).text
        if output.contains("count") { #expect(text.contains("| count | 42 |")) }
        else { #expect(text.contains("| type | doc |")); #expect(text.contains("paragraph")) }
        #expect(text.contains("**content**"))
    }
    @Test func callArgumentsStayLiteralIncludingBackticks() throws {
        let args: [String: JSONValue] = ["labelId": "480696530943115366", "code": "`one``two`"]
        let calls = NestedToolCalls(calls: [.init(id: "1", name: "lookup", arguments: args, status: "ok")], complete: true)
        let blocks = parseCommonMark(try doc(calls: calls).text)
        guard case .unorderedList(let items) = try #require(blocks.dropFirst().first),
              case .paragraph(let inlines) = try #require(items.first?.first) else { Issue.record("Calls list"); return }
        #expect(inlines.contains(.code(OrderedJSON.from(.object(args)).json())))
    }
    @Test func rawPreviewWordingAndCompleteOutput() throws {
        let output = String(repeating: "result\n", count: 24000)
        let complete = try doc(output)
        #expect(!complete.text.contains("Raw contains the complete"))
        #expect(complete.rawText?.hasSuffix(output) == true)
        let partial = try #require(ToolCallDocumentBuilder.build(args: [:], inputPresentation: nil, nestedCalls: nil,
            output: output, rawOutput: output, details: nil, isDone: true, previewOnly: true, totalBytes: 300000))
        #expect(partial.rawText?.contains("Output preview only (168000 of 300000 bytes)") == true)
        #expect(partial.text.contains("Output preview only (168000 of 300000 bytes)"))
        let tail = try #require(ToolCallDocumentBuilder.build(args: [:], inputPresentation: nil, nestedCalls: nil,
            output: "tail\n", rawOutput: "tail\n", details: nil, isDone: true, previewOnly: true, totalBytes: 4096))
        #expect(tail.text.contains("Output preview only (5 of 4096 bytes)"))
        #expect(tail.rawText?.contains("Output preview only (5 of 4096 bytes)") == true)
        let fallback = ToolContentDescriptorBuilder.build(tool: "find", argsSummary: "", outputPreview: "trace preview",
            isError: false, isDone: true, context: .init())
        guard case .markdown(let d) = fallback.content else { Issue.record("Generic document"); return }
        #expect(d.rawText?.contains("Output preview only") == true)
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
        let hints = ToolInputPresentation(fields: Dictionary(uniqueKeysWithValues: args.keys.map { ($0, .init(role: "code", language: "javascript")) }))
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
        #expect(text.contains("✓ **first**")); #expect(text.contains("999 ms")); #expect(text.contains("1.5 s"))
        #expect(text.contains("10000 bytes")); #expect(text.contains("bad")); #expect(text.contains("… **third**"))
        #expect(text.contains("Some calls not recorded."))
        #expect(text.contains("**3 calls · 1 failed**"))
        #expect(calls.summary == "3 calls · 1 failed")
        #expect(NestedToolCalls(calls: [.init(id: "1", name: "a", status: "running")], complete: true).summary == "1 call · 1 running")
    }
    @Test func longCallListsSayHowManyAreOmitted() throws {
        let many = (0..<300).map { NestedToolCallRecord(id: "\($0)", name: "c\($0)", status: "ok") }
        let text = try doc("ok", calls: .init(calls: many, complete: true)).text
        #expect(text.contains("**300 calls**")); #expect(text.contains("44 more calls"))
        #expect(!text.contains("**c256**")); #expect(text.contains("**c255**"))
    }
    @Test @MainActor func collapsedRowSummarizesNestedCallsUnlessSomethingMoreSpecificOwnsTheTrailingText() {
        var context = ToolPresentationBuilder.Context(args: nil, expandedItemIDs: [], fullOutput: "ok", isLoadingOutput: false)
        context.nestedCalls = .init(calls: [.init(id: "a", name: "x", status: "ok"), .init(id: "b", name: "y", status: "error")], complete: true)
        let config = ToolPresentationBuilder.build(itemID: "t", tool: "arbitrary", argsSummary: "", outputPreview: "", isError: false, isDone: true, context: context)
        #expect(config.trailing == "2 calls · 1 failed")
    }
    @Test func expandedTextWinsAndEmptyOutputRendersDetails() throws {
        let details: JSONValue = .object(["expandedText": "# Human", "presentationFormat": "markdown", "count": 42])
        #expect(try doc("raw", details: details).text == "# Human")
        #expect(try doc("raw", details: .object(["count": 42])).text == "```text\nraw\n```")
        let empty = try doc(details: .object(["count": 42, "status": "saved"]))
        #expect(empty.text.contains("42"))
        #expect(empty.text.contains("saved"))
        #expect(empty.text.contains("| Field | Value |"))
    }

    @Test @MainActor func fullScreenUsesSameDocumentAndRawToggle() throws {
        var context = ToolPresentationBuilder.Context(args: ["source": "text(1)", "unused": .null],
            expandedItemIDs: ["t"], fullOutput: "{\"z\":1}", isLoadingOutput: false)
        context.inputPresentation = .init(fields: ["source": .init(role: "code", language: "javascript")])
        let config = ToolPresentationBuilder.build(itemID: "t", tool: "arbitrary", argsSummary: "",
            outputPreview: "", isError: false, isDone: true, context: context)
        let content = try #require(ToolTimelineRowFullScreenSupport.staticFullScreenContent(
            configuration: config, outputCopyText: nil, terminalStream: nil))
        guard case .markdown(let document, _, _, let raw, _) = content,
              case .markdown(let inline, _) = config.expandedContent else { Issue.record("Markdown reader"); return }
        #expect(document == inline)
        #expect(raw == config.rawMarkdownText)
        let controller = FullScreenCodeViewController(content: content)
        controller.loadViewIfNeeded()
        controller.toggleSourceForTesting()
        guard case .plainText(let rawBody, _) = controller.presentationBodyContentForTesting else { Issue.record("Raw body"); return }
        #expect(rawBody == raw)
        #expect(controller.presentationCopyTextForTesting == rawBody)
        guard case .plainText(let sharedRaw, _) = controller.shareableContentForTesting else { Issue.record("Raw share"); return }
        #expect(sharedRaw == rawBody)
        #expect(rawBody.contains("\"unused\": null"))
        #expect(rawBody.hasSuffix("{\"z\":1}"))
        controller.toggleSourceForTesting()
        guard case .markdown(let rendered, _, _, _, _) = controller.presentationBodyContentForTesting else { Issue.record("Rendered body"); return }
        #expect(rendered == inline)
        #expect(controller.presentationCopyTextForTesting == inline)
        guard case .markdown(let sharedRendered, _) = controller.shareableContentForTesting else { Issue.record("Rendered share"); return }
        #expect(sharedRendered == inline)
        #expect(config.copyOutputText == "{\"z\":1}")
    }

    @Test(arguments: [false, true]) @MainActor func rawReaderLoadsAllSidecarWindowsAndKeepsPreviewWhenUnavailable(_ embeddedBoundary: Bool) async throws {
        let output = String(repeating: "match\n", count: 30000) + "LAST MATCH\n"
        let split = 128 * 1024
        let first = String(decoding: output.utf8.prefix(split), as: UTF8.self)
        let rest = String(decoding: output.utf8.dropFirst(split), as: UTF8.self)
        let source = ToolOutputSidecarWindowSource(loadFirst: {
            .init(text: first, endByteOffset: split, totalBytes: output.utf8.count)
        }, loadNext: { offset in
            #expect(offset == split)
            return .init(text: rest, endByteOffset: output.utf8.count, totalBytes: output.utf8.count)
        })
        var context = ToolPresentationBuilder.Context(args: ["pattern": "match"], expandedItemIDs: ["t"], fullOutput: first, isLoadingOutput: false)
        context.previewOnly = true; context.totalBytes = output.utf8.count
        let tool = embeddedBoundary ? "tool\n\nOutput\n\nidentity" : "grep"
        if embeddedBoundary { context.display = .init(title: "search") }
        var config = ToolPresentationBuilder.build(itemID: "t", tool: tool, argsSummary: "", outputPreview: "", isError: false, isDone: true, context: context)
        guard case .markdown(let rendered, _) = config.expandedContent else { Issue.record("Rendered preview"); return }
        #expect(rendered.contains("Output preview only (\(first.utf8.count) of \(output.utf8.count) bytes)"))
        config.toolOutputSidecarSource = source
        func controller(_ config: ToolTimelineRowConfiguration) throws -> FullScreenCodeViewController {
            let content = try #require(ToolTimelineRowFullScreenSupport.staticFullScreenContent(configuration: config, outputCopyText: nil, terminalStream: nil))
            let vc = FullScreenCodeViewController(content: content)
            vc.loadViewIfNeeded(); vc.toggleSourceForTesting()
            return vc
        }
        let active = try controller(config)
        #expect(active.presentationCopyTextForTesting == config.rawMarkdownText)
        guard case .plainText(let initialShare, _) = active.shareableContentForTesting else { Issue.record("Preview Raw share"); return }
        #expect(initialShare == config.rawMarkdownText)
        let deadline = ContinuousClock.now + .seconds(3)
        var raw = ""
        repeat {
            await Task.yield()
            if case .plainText(let text, _) = active.presentationBodyContentForTesting { raw = text }
        } while !raw.hasSuffix("LAST MATCH\n") && ContinuousClock.now < deadline
        let identity = embeddedBoundary ? "Tool\n\n" + tool + "\n\n" : ""
        let expectedPrefix = identity + "Input\n\n{\n  \"pattern\": \"match\"\n}\n\nOutput\n\n"
        #expect(config.rawMarkdownOutputPrefix == expectedPrefix)
        #expect(raw == expectedPrefix + output)
        #expect(active.presentationCopyTextForTesting == raw)
        guard case .plainText(let completeShare, _) = active.shareableContentForTesting else { Issue.record("Complete Raw share"); return }
        #expect(completeShare == raw)
        config.toolOutputSidecarSource = .init(loadFirst: { nil }, loadNext: { _ in nil })
        let stopped = try controller(config)
        await Task.yield()
        guard case .plainText(let preview, _) = stopped.presentationBodyContentForTesting else { Issue.record("Raw preview"); return }
        #expect(preview.contains("Output preview only"))
        #expect(!preview.contains("LAST MATCH"))
        #expect(stopped.presentationCopyTextForTesting == preview)
        guard case .plainText(let stoppedShare, _) = stopped.shareableContentForTesting else { Issue.record("Unavailable Raw share"); return }
        #expect(stoppedShare == preview)
    }

    @Test func displayHumanizerIsUniversalAndVerbatimTitlesArePreserved() {
        for title in ["getActivityDetail", "get_activity_detail", "get-activity-detail"] {
            #expect(ToolDisplay(title: title, group: "coros").label(fallback: "raw") == "coros · Get activity detail")
        }
        #expect(ToolDisplay(title: "getURLForId").label(fallback: "raw") == "Get url for id")
        #expect(ToolDisplay(title: "Get Activity Detail (COROS)", group: "Coros", verbatim: true).label(fallback: "raw") == "Coros · Get Activity Detail (COROS)")
        #expect(ToolDisplay(title: " ").label(fallback: "mcp__raw__name") == "mcp__raw__name")
    }

    @Test(arguments: [#"{"title":42,"group":false,"verbatim":"future"}"#, #"[]"#, #""invalid""#, #"null"#])
    func malformedDisplayDoesNotRejectProtocolOrNestedRecords(_ value: String) throws {
        let message = try ServerMessage.decode(from: "{\"type\":\"tool_start\",\"tool\":\"raw\",\"args\":{},\"display\":" + value + "}")
        guard case .toolStart(_, _, _, _, _, let display, _, _) = message else { Issue.record("tool start"); return }
        #expect((display?.label(fallback: "raw") ?? "raw") == "raw")
        let data = Data(("{\"id\":\"t\",\"type\":\"toolCall\",\"timestamp\":\"2026-09-30T15:20:00Z\",\"tool\":\"raw\",\"display\":" + value + "}").utf8)
        let trace = try JSONDecoder().decode(TraceEvent.self, from: data)
        #expect((trace.display?.label(fallback: "raw") ?? "raw") == "raw")
        let nestedData = Data(("{\"id\":\"n\",\"name\":\"raw\",\"status\":\"future\",\"display\":" + value + "}").utf8)
        let nested = try JSONDecoder().decode(NestedToolCallRecord.self, from: nestedData)
        #expect((nested.display?.label(fallback: nested.name) ?? nested.name) == "raw")
    }

    @Test @MainActor func displayFactsDriveTitlesCallsAndRawWithoutClientNameParsing() throws {
        let fact = ToolDisplay(title: "getActivityDetail", group: "coros")
        let rawName = "arbitrarily.named.tool"
        var context = ToolPresentationBuilder.Context(args: ["labelId": "123"], expandedItemIDs: [], fullOutput: "ok", isLoadingOutput: false)
        func config(_ context: ToolPresentationBuilder.Context) -> ToolTimelineRowConfiguration {
            ToolPresentationBuilder.build(itemID: "t", tool: rawName, argsSummary: "", outputPreview: "", isError: false, isDone: true, context: context)
        }
        #expect(config(context).title == rawName) // Old server: no guessing from the name.
        context.display = fact
        #expect(config(context).title == "coros · Get activity detail")
        let calls = NestedToolCalls(calls: [.init(id: "n", name: "nested.raw", display: fact, status: "ok")], complete: true)
        let doc = try #require(ToolCallDocumentBuilder.build(args: context.args, inputPresentation: nil, nestedCalls: calls,
            output: "ok", rawOutput: "ok", details: nil, isDone: true, toolName: rawName))
        #expect(doc.text.contains("✓ **coros · Get activity detail**"))
        #expect(!doc.text.contains("nested.raw"))
        #expect(doc.text.contains(rawName)); #expect(doc.rawText?.contains(rawName) == true)
        #expect(doc.rawText?.contains("nested.raw") == true)
        var segmented = ToolPresentationBuilder.Context(args: nil, expandedItemIDs: [], fullOutput: "ok", isLoadingOutput: false,
            callSegments: [.init(text: "native ", style: .bold), .init(text: "payload", style: .accent)])
        segmented.display = fact
        #expect(config(segmented).segmentAttributedTitle?.string == "native payload")
    }

    @Test @MainActor func displayUpdateInvalidatesExistingRowAndClearsWithStore() {
        let reducer = TimelineReducer()
        let correlator = ToolCallCorrelator()
        reducer.process(correlator.start(sessionId: "s", tool: "raw", args: [:], toolCallId: "t"))
        let fact = ToolDisplay(title: "getActivityDetail", group: "coros")
        let previousVersion = reducer.renderVersion
        reducer.processBatch([correlator.update(sessionId: "s", tool: "raw", args: [:], toolCallId: "t", display: fact)])
        #expect(reducer.renderVersion > previousVersion)
        #expect(reducer.toolArgsStore.display(for: "t") == fact)
        #expect(reducer.items.count == 1)
        reducer.toolArgsStore.clearAll()
        #expect(reducer.toolArgsStore.display(for: "t") == nil)
    }

    @Test @MainActor func protocolReducerHistoryAndDescriptorParity() throws {
        let start = try ServerMessage.decode(from: #"{"type":"tool_start","tool":"arbitrary","toolCallId":"t","args":{"source":"text(1)"},"inputPresentation":{"fields":{"source":{"role":"code","language":"javascript"}}},"display":{"title":"getActivityDetail","group":"coros"}}"#)
        let end = try ServerMessage.decode(from: #"{"type":"tool_end","tool":"arbitrary","toolCallId":"t","nestedCalls":{"calls":[{"id":"t/1","name":"nested","status":"future"}],"complete":false}}"#)
        let live = TimelineReducer(); let correlator = ToolCallCorrelator()
        guard case .toolStart(let tool, let args, let id, let segments, let hints, let display, _, _) = start,
              case .toolEnd(_, _, _, _, _, let nested, _, _, _, _) = end else { Issue.record("protocol case"); return }
        live.process(correlator.start(sessionId: "s", tool: tool, args: args, toolCallId: id, callSegments: segments, inputPresentation: hints, display: display))
        live.process(correlator.output(sessionId: "s", output: #"{"z":1,"a":2}"#, isError: false, toolCallId: "t"))
        live.process(correlator.end(sessionId: "s", toolCallId: "t"))
        live.process(correlator.end(sessionId: "s", toolCallId: "t", nestedCalls: nested))
        let history = TimelineReducer()
        history.loadSession([.init(id: "t", type: .toolCall, timestamp: "2026-09-30T15:20:00Z", tool: tool, args: args, inputPresentation: hints, display: display),
                             .init(id: "r", type: .toolResult, timestamp: "2026-09-30T15:20:01Z", output: #"{"z":1,"a":2}"#, toolCallId: "t", nestedCalls: nested)])
        func presentation(_ r: TimelineReducer) -> ToolContentPresentation {
            ToolContentDescriptorBuilder.build(tool: tool, argsSummary: "", outputPreview: "", isError: false, isDone: true,
                context: .init(args: r.toolArgsStore.args(for: "t"), fullOutput: r.toolOutputStore.fullOutput(for: "t"),
                               inputPresentation: r.toolArgsStore.inputPresentation(for: "t"), nestedCalls: r.toolDetailsStore.nestedCalls(for: "t"), display: r.toolArgsStore.display(for: "t")))
        }
        #expect(live.toolArgsStore.display(for: "t")?.label(fallback: tool) == "coros · Get activity detail")
        #expect(presentation(live) == presentation(history))
        #expect(presentation(live).copyOutputText == #"{"z":1,"a":2}"#)
        guard case .markdown(let d) = presentation(live).content else { Issue.record("document descriptor"); return }
        #expect(d.text.contains("```javascript")); #expect(d.text.contains("… **nested**")); #expect(d.rawText != nil)
    }
}
