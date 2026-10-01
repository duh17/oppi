import Foundation
import Testing
@testable import Oppi

@Suite("Fact-driven file inspection")
@MainActor
struct ToolFileInspectionTests {
    private func build(_ tool: String, args: [String: JSONValue], input: ToolInputPresentation?, output: ToolOutputPresentation?,
                       text: String = "", details: JSONValue? = nil, done: Bool = true, error: Bool = false) -> ToolContentPresentation {
        ToolContentDescriptorBuilder.build(tool: tool, argsSummary: "misleading summary", outputPreview: text,
            isError: error, isDone: done, context: .init(args: args, details: details, fullOutput: text,
                inputPresentation: input, outputPresentation: output))
    }

    @Test(arguments: ["main.swift", "README.md", "picture.png", "data.csv", "map.json"])
    func readUsesFactsAndExistingFileClassification(path: String) throws {
        let text = path == "map.json" ? "{\"type\":\"FeatureCollection\",\"features\":[]}" : "sample"
        let value = build("inspect_blob", args: ["target": .string(path), "from": .number(42)],
            input: .init(fields: ["target": .init(role: "filePath"), "from": .init(role: "lineOffset")]),
            output: .init(kind: "fileContent", provenance: "result"), text: text)
        guard case .file(let file) = value.content else { Issue.record("Expected native file leaf"); return }
        #expect(file.filePath == path)
        #expect(file.startLine == 42)
        #expect(file.text == text)
        let expected: FileType = switch path {
        case "main.swift": .code(language: .swift)
        case "README.md": .markdown
        case "picture.png": .image
        case "data.csv": .csv
        default: .geojson
        }
        #expect(file.fileType == expected)
        #expect(value.inspection.file?.provenance == .result)
    }

    @Test(arguments: ["write", "put_file"])
    func streamingWriteAndCurrentFileActionAreNameIndependent(tool: String) throws {
        let input = ToolInputPresentation(fields: ["target": .init(role: "filePath"), "payload": .init(role: "fileContent")])
        let output = ToolOutputPresentation(kind: "fileContent", provenance: "requested")
        for done in [false, true] {
            let args: [String: JSONValue] = ["target": .string("docs/out.md"), "payload": .string("# Requested\n")]
            let presentation = build(tool, args: args, input: input, output: output, text: done ? "written" : "", done: done)
            #expect(presentation.inspection.file?.provenance == .requested)
            #expect(presentation.inspection.raw == (done ? "written" : ""))
            guard case .file(let file) = presentation.content else { Issue.record("Expected requested file leaf"); return }
            #expect(file.text == "# Requested\n")
            var context = ToolPresentationBuilder.Context(args: args, expandedItemIDs: ["row"], fullOutput: "written", isLoadingOutput: false,
                callSegments: [.init(text: "Store ", style: .bold), .init(text: "server-selected title", style: .accent)])
            context.inputPresentation = input; context.outputPresentation = output
            let row = ToolPresentationBuilder.build(itemID: "row", tool: tool, argsSummary: "wrong", outputPreview: "written", isError: false, isDone: done, context: context)
            #expect(row.title == "server-selected title")
            #expect(row.toolNamePrefix == "file-mutation")
            #expect(row.trailing == "Requested")
            #expect(row.currentFileOpenIntent?.path == (done ? "docs/out.md" : nil))
        }
    }

    @Test(arguments: ["-42 old\n+42 actual", "-42 old\n+42 actual\n"])
    func editUsesResultDiffForBothLeafAndStatsThenRequestedFallback(resultDiff: String) throws {
        let args: [String: JSONValue] = ["path": .string("main.swift"), "edits": .array([
            .object(["oldText": .string("one"), "newText": .string("two\nthree")])])]
        let facts = try #require(ToolFileFactsFixture.facts("edit"))
        let result: JSONValue = .object(["diff": .string(resultDiff)])
        let completed = build("swap_text", args: args, input: facts.0, output: facts.1, details: result)
        #expect(completed.inspection.file?.provenance == .result)
        #expect(completed.inspection.file?.stats?.added == 1)
        #expect(completed.inspection.file?.stats?.removed == 1)
        guard case .diff(let diff) = completed.content else { Issue.record("Expected result diff"); return }
        #expect(diff.lines.first?.oldLineNumber == 42)
        #expect(diff.lines.last?.text == "actual")
        let requested = build("swap_text", args: args, input: facts.0, output: facts.1)
        #expect(requested.inspection.file?.provenance == .requested)
        #expect(requested.inspection.file?.stats?.added == 2)
        let streaming = build("swap_text", args: ["path": .string("main.swift"), "edits": .array([.object(["newText": .string("par")])])],
            input: facts.0, output: facts.1, done: false)
        guard case .file(let file) = streaming.content else { Issue.record("Expected partial requested preview"); return }
        #expect(file.text == "par")
        #expect(streaming.inspection.file?.provenance == .requested)
        let failed = build("swap_text", args: args, input: facts.0, output: facts.1, text: "No match", details: result, error: true)
        #expect(failed.inspection.file?.stats == nil)
        guard case .markdown(let errorDocument) = failed.content else { Issue.record("Expected error document"); return }
        #expect(errorDocument.text.contains("No match"))
    }

    @Test func malformedResultPatchWithEmptyDisplayDiffFallsBackToRequestedEdits() throws {
        let args: [String: JSONValue] = ["path": .string("main.swift"), "edits": .array([
            .object(["oldText": .string("before"), "newText": .string("requested\nextra")])])]
        let facts = try #require(ToolFileFactsFixture.facts("edit"))
        let details: JSONValue = .object(["patch": .string("not a unified patch"), "diff": .string("")])
        let presentation = build("replace_text", args: args, input: facts.0, output: facts.1, details: details)
        #expect(presentation.inspection.file?.provenance == .requested)
        #expect(presentation.inspection.file?.stats?.added == 2)
        #expect(presentation.inspection.file?.stats?.removed == 1)
        guard case .diff(let diff) = presentation.content else { Issue.record("Expected requested diff"); return }
        #expect(diff.lines.filter { $0.kind == .added }.map(\.text) == ["requested", "extra"])
        var context = ToolPresentationBuilder.Context(args: args, details: details, expandedItemIDs: [], fullOutput: "", isLoadingOutput: false)
        context.inputPresentation = facts.0
        context.outputPresentation = facts.1
        let row = ToolPresentationBuilder.build(itemID: "row", tool: "replace_text", argsSummary: "", outputPreview: "",
            isError: false, isDone: true, context: context)
        #expect(row.trailing == "Requested")
        #expect(row.editAdded == 2)
        #expect(row.editRemoved == 1)
    }

    @Test func emptyDisplayDiffWithoutPatchPreservesAuthoritativeNoChanges() throws {
        let facts = try #require(ToolFileFactsFixture.facts("edit"))
        let presentation = build("replace_text", args: ["path": .string("main.swift"), "edits": .array([
            .object(["oldText": .string("before"), "newText": .string("requested")])])],
            input: facts.0, output: facts.1, details: .object(["diff": .string("")]))
        #expect(presentation.inspection.file?.provenance == .result)
        #expect(presentation.inspection.file?.stats?.added == 0)
        #expect(presentation.inspection.file?.stats?.removed == 0)
    }

    @Test(arguments: ["Read", "functions.read", "functions.write", "functions.edit", "put_file"])
    func undeclaredNamesDegradeToGenericDocument(tool: String) throws {
        let presentation = build(tool, args: ["path": .string("README.md"), "content": .string("# Requested")], input: nil, output: nil, text: "result")
        #expect(presentation.inspection.file == nil)
        guard case .markdown(let document) = presentation.content else { Issue.record("Missing facts must be generic"); return }
        #expect(document.text.contains("Input"))
        #expect(document.text.contains("result"))
    }

    @Test(arguments: ["write", "edit", "put_file"])
    func streamedArgumentsCompletionAndHistoryProduceTheSameInspection(tool: String) throws {
        let facts = try #require(ToolFileFactsFixture.facts(tool == "put_file" ? "write" : tool))
        let isEdit = tool == "edit"
        let partial: [String: JSONValue] = isEdit
            ? ["path": .string("main.swift"), "edits": .array([.object(["newText": .string("par")])])]
            : ["path": .string("main.swift"), "content": .string("par")]
        let args: [String: JSONValue] = isEdit
            ? ["path": .string("main.swift"), "edits": .array([.object(["oldText": .string("before"), "newText": .string("requested")])])]
            : ["path": .string("main.swift"), "content": .string("requested")]
        let details: JSONValue? = isEdit ? .object(["diff": .string("-42 before\n+42 actual")]) : nil
        let live = TimelineReducer()
        live.process(.toolUpdate(sessionId: "s", toolEventId: "call", tool: tool, args: partial,
            inputPresentation: facts.0, outputPresentation: facts.1))
        func snapshot(_ reducer: TimelineReducer) throws -> ToolContentPresentation {
            guard case .toolCall(let id, let name, let summary, let preview, _, let error, let done) = try #require(reducer.items.first) else {
                throw NSError(domain: "FileInspection", code: 1)
            }
            return ToolContentDescriptorBuilder.build(tool: name, argsSummary: summary, outputPreview: preview,
                isError: error, isDone: done, context: .init(args: reducer.toolArgsStore.args(for: id),
                    details: reducer.toolDetailsStore.details(for: id), fullOutput: reducer.toolOutputStore.fullOutput(for: id) ?? "",
                    inputPresentation: reducer.toolArgsStore.inputPresentation(for: id),
                    outputPresentation: reducer.toolArgsStore.outputPresentation(for: id)))
        }
        let preview = try snapshot(live)
        #expect(preview.inspection.file?.text == "par")
        #expect(preview.inspection.file?.provenance == .requested)
        live.process(.toolStart(sessionId: "s", toolEventId: "call", tool: tool, args: args,
            inputPresentation: facts.0, outputPresentation: facts.1))
        live.process(.toolOutput(.init(sessionId: "s", toolEventId: "call", output: "completed", isError: false)))
        live.process(.toolEnd(sessionId: "s", toolEventId: "call", details: details, outputPresentation: facts.1,
            outputAvailability: .init(complete: true)))
        let finished = try snapshot(live)
        #expect(finished.inspection.file?.provenance == (isEdit ? .result : .requested))
        if isEdit { #expect(finished.inspection.file?.diff?.last?.text == "actual") }
        let history = TimelineReducer()
        history.loadSession([
            .init(id: "call", type: .toolCall, timestamp: "2026-10-01T00:00:00Z", tool: tool, args: args,
                  outputPresentation: facts.1, inputPresentation: facts.0),
            .init(id: "result", type: .toolResult, timestamp: "2026-10-01T00:00:01Z", output: "completed",
                  toolCallId: "call", toolName: tool, isError: false, details: details,
                  outputPresentation: facts.1, outputAvailability: .init(complete: true)),
        ])
        #expect(try snapshot(history) == finished)
    }

    @Test func tolerantDecodingKeepsGoodFieldsAndUnknownOutputDegrades() throws {
        let input = try JSONDecoder().decode(ToolInputPresentation.self, from: Data("{\"fields\":{\"target\":{\"role\":\"filePath\"},\"future\":{\"role\":17,\"language\":true}}}".utf8))
        #expect(input.fields["target"]?.role == "filePath")
        #expect(input.fields["future"]?.role == "")
        let output = try JSONDecoder().decode(ToolOutputPresentation.self, from: Data("{\"kind\":\"future\",\"provenance\":42}".utf8))
        #expect(build("read", args: [:], input: input, output: output, text: "output").inspection.file == nil)
    }
}
