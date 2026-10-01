import Foundation
import Testing
@testable import Oppi

@Suite("Tool inspection consumers")
@MainActor
struct ToolInspectionConsumerTests {
    @Test(arguments: ["bash", "run_thing", "mcp__provider__execute"])
    func terminalFactsDriveQuietOutlineAndActivity(tool: String) throws {
        let reducer = TimelineReducer()
        reducer.process(.toolStart(sessionId: "s", toolEventId: "t", tool: tool, args: ["script": "echo hello"],
            inputPresentation: .init(fields: ["script": .init(role: "command", language: "shell")]),
            display: .init(title: "Execute command", verbatim: true), outputPresentation: .init(kind: "terminal")))
        let inspection = try #require(reducer.toolInspection(for: reducer.items[0]))
        #expect(inspection.glyph == "dollarsign")
        #expect(inspection.outlineSummary(argsSummary: "ignored") == "$ echo hello")
        #expect(inspection.activityLabel == "Running Execute command")
        let projection = QuietTimelineProjection.make(items: reducer.items, isQuiet: true, isBusy: true,
            expandedTurnIDs: [], toolInspection: { reducer.toolInspection(for: $0) })
        guard case .quietWork(let line) = projection.rows.first else { Issue.record("Missing work strip"); return }
        #expect(line.buckets == [.init(kind: .terminal, count: 1)])
        let manager = LiveActivityManager()
        manager.sync(connectionId: "c", sessions: [makeTestSession(id: "s", status: .busy)])
        manager.recordEvent(connectionId: "c", event: .toolStart(sessionId: "s", toolEventId: "t", tool: tool,
            args: [:], display: .init(title: "Execute command", verbatim: true), outputPresentation: .init(kind: "terminal")))
        #expect(manager.currentState.primaryTool == "Execute command")
        #expect(manager.currentState.primaryLastActivity == "Running Execute command")
    }

    @Test(arguments: [false, true])
    func selectedDiffStatsAreSharedWithQuietAndOutline(resultPatch: Bool) throws {
        let reducer = TimelineReducer()
        reducer.process(.toolStart(sessionId: "s", toolEventId: "t", tool: "change_document",
            args: ["target": "Sources/Example.swift", "changes": [["oldText": "a", "newText": "b\nc\nd"]]],
            inputPresentation: .init(fields: ["target": .init(role: "filePath"), "changes": .init(role: "edits")]),
            display: .init(title: "Change document", verbatim: true), outputPresentation: .init(kind: "diffOfEdits")))
        reducer.process(.toolEnd(sessionId: "s", toolEventId: "t",
            details: resultPatch ? ["patch": "--- a/Sources/Example.swift\n+++ b/Sources/Example.swift\n@@ -1 +1 @@\n-a\n+b\n"] : nil))
        let inspection = try #require(reducer.toolInspection(for: reducer.items[0], includeOutput: true))
        let stats = try #require(inspection.file?.stats)
        #expect(stats.added == (resultPatch ? 1 : 3))
        #expect(stats.removed == 1)
        #expect(inspection.file?.provenance == (resultPatch ? .result : .requested))
        #expect(inspection.glyph == "arrow.left.arrow.right")
        #expect(inspection.outlineSummary(argsSummary: "") == "Change document Sources/Example.swift")
        let projection = QuietTimelineProjection.make(items: reducer.items, isQuiet: true, isBusy: false,
            expandedTurnIDs: [], toolInspection: { reducer.toolInspection(for: $0) })
        guard case .quietWork(let line) = projection.rows.first else { Issue.record("Missing work strip"); return }
        #expect(line.buckets == [.init(kind: .edit, count: 1, editStats: .init(added: resultPatch ? 1 : 3, removed: 1), statsProvenance: resultPatch ? .result : .requested)])
        #expect(line.workSummary == (resultPatch ? "edit +1 −1" : "Requested edit +3 −1"))
    }

    @Test(arguments: [0, 1, 2])
    func quietStatsDiscloseMixedRequestedAndResultProvenance(resultCount: Int) throws {
        let reducer = TimelineReducer()
        for index in 0..<2 {
            let id = "edit-\(index)"
            reducer.process(.toolStart(sessionId: "s", toolEventId: id, tool: "edit",
                args: ["path": "Example.swift", "edits": [["oldText": "a", "newText": "b"]]]))
            reducer.process(.toolEnd(sessionId: "s", toolEventId: id,
                details: index < resultCount ? ["diff": "- 1 a\n+ 1 b"] : nil))
        }
        let projection = QuietTimelineProjection.make(items: reducer.items, isQuiet: true, isBusy: false,
            expandedTurnIDs: [], toolInspection: { reducer.toolInspection(for: $0) },
            isInteractiveTool: { reducer.isInteractiveTool($0) })
        guard case .quietWork(let line) = projection.rows.first else { Issue.record("Missing work strip"); return }
        #expect(line.workSummary == [
            "Requested edit +2 −2", "edit (includes Requested) +2 −2", "edit +2 −2"
        ][resultCount])
    }

    @Test func quietVisibilityUsesFactsAndResolvesEachFoldedToolOnce() {
        let reducer = TimelineReducer()
        reducer.process(.toolStart(sessionId: "s", toolEventId: "t", tool: "edit",
            args: ["path": "Example.swift", "edits": [["oldText": "a", "newText": "b"]]]))
        reducer.process(.toolStart(sessionId: "s", toolEventId: "q", tool: "ask", args: [:]))
        var resolvedIDs: [String] = []
        let projection = QuietTimelineProjection.make(items: reducer.items, isQuiet: true, isBusy: true,
            expandedTurnIDs: [], toolInspection: { item in
                resolvedIDs.append(item.id)
                return reducer.toolInspection(for: item)
            }, isInteractiveTool: { reducer.isInteractiveTool($0) })
        #expect(projection.rows.map(\.id) == ["quiet-work-line:t", "q"])
        #expect(resolvedIDs == ["t"], "Interaction visibility must not build content or resolve a folded tool twice")
    }

    @Test func summaryInspectionDefersFileBytesAndTypesButKeepsFacts() throws {
        let reducer = TimelineReducer()
        let content = "{\"type\":\"FeatureCollection\",\"features\":[]}"
        reducer.process(.toolStart(sessionId: "s", toolEventId: "t", tool: "write",
            args: ["path": "map.json", "content": .string(content)]))
        let item = try #require(reducer.items.first)
        let summary = try #require(reducer.toolInspection(for: item))
        #expect(summary.file?.path == "map.json")
        #expect(summary.file?.operation == .mutation)
        #expect(summary.file?.provenance == .requested)
        #expect(summary.file?.text == "")
        #expect(summary.file?.fileType == nil)
        #expect(summary.output.isEmpty)
        #expect(reducer.resolvedToolOutputPresentation(for: "t")?.kind == "fileContent")
        let rendered = try #require(reducer.toolInspection(for: item, includeOutput: true))
        #expect(rendered.file?.text == content)
        #expect(rendered.file?.fileType == .geojson)
        #expect(rendered.copyOutputText == content)
        #expect(!rendered.output.isEmpty)
    }

    @Test(arguments: ["bash", "read", "write", "edit"])
    func outlineKeepsProducerSummaryWhenBoundedArgumentsAreAbsent(tool: String) {
        let inspection = ToolContentDescriptorBuilder.inspect(tool: tool, context: .init(), includeOutput: false)
        #expect(inspection.outlineSummary(argsSummary: "", fallback: "$ ls -la / retained path") == "$ ls -la / retained path")
    }

    @Test func outlineDisplayPathKeepsCanonicalFilePathUntouched() throws {
        let inspection = ToolContentDescriptorBuilder.inspect(tool: "read",
            context: .init(args: ["path": "/Users/example/workspace/Example.swift"]),
            includeOutput: false, includeFileContent: false)
        let path = try #require(inspection.file?.path)
        #expect(inspection.outlineSummary(argsSummary: "", displayPath: path.shortenedPath)
            == "read ~/workspace/Example.swift")
        #expect(inspection.file?.path == "/Users/example/workspace/Example.swift")
    }

    @Test func arbitraryInteractionStaysVisibleAndNonBuiltInNamesStayGeneric() throws {
        let reducer = TimelineReducer()
        reducer.process(.toolStart(sessionId: "s", toolEventId: "q", tool: "choose_next", args: [:], outputPresentation: .init(kind: "interactive")))
        let projection = QuietTimelineProjection.make(items: reducer.items, isQuiet: true, isBusy: true,
            expandedTurnIDs: [], toolInspection: { reducer.toolInspection(for: $0) })
        #expect(projection.rows.map(\.id) == ["q"])
        for tool in ["functions.read", "Read", "put_file", "functions.ask", "mcp__x__read"] {
            let inspection = ToolContentDescriptorBuilder.inspect(tool: tool,
                context: .init(args: ["command": "not a command fact", "path": "file.swift"]), includeOutput: false)
            #expect(inspection.activityKind == .generic)
            #expect(inspection.glyph == nil)
            #expect(inspection.file == nil)
            #expect(inspection.commandText == nil)
            #expect(!inspection.isInteractive)
        }
    }

    @Test(arguments: [false, true])
    func callsSummaryUsesTheInspectionEnvelope(expanded: Bool) throws {
        let calls = NestedToolCalls(calls: [
            .init(id: "ok", name: "first", status: "ok"),
            .init(id: "failed", name: "second", status: "error", error: "Rejected"),
            .init(id: "running", name: "third", status: "running")
        ], complete: false)
        let inspection = ToolContentDescriptorBuilder.inspect(tool: "compose",
            context: .init(args: [:], nestedCalls: calls), includeOutput: expanded)
        var context = ToolPresentationBuilder.Context(args: [:], expandedItemIDs: expanded ? ["root"] : [],
            fullOutput: "", isLoadingOutput: false)
        context.inspection = inspection
        // The supplied envelope is authoritative even if the legacy context is stale.
        context.nestedCalls = .init(calls: [.init(id: "old", name: "old", status: "ok")], complete: true)
        let row = ToolPresentationBuilder.build(itemID: "root", tool: "compose", argsSummary: "",
            outputPreview: "", isError: false, isDone: false, context: context)
        #expect(row.trailing == "3 calls · 1 failed · 1 running")
        if expanded {
            guard case .markdown(let document) = inspection.output.first else {
                Issue.record("Expected the Calls document"); return
            }
            #expect(document.text.contains("**3 calls · 1 failed · 1 running**"))
            #expect(document.text.contains("Some calls not recorded."))
        }
    }

    @Test(arguments: [false, true])
    func fileRolesDriveSummariesAndGlyphs(requested: Bool) {
        let inspection = ToolContentDescriptorBuilder.inspect(tool: "arbitrary_file_tool",
            context: .init(args: ["target": "example.swift", "bytes": "hello"],
                inputPresentation: .init(fields: ["target": .init(role: "filePath"), "bytes": .init(role: "fileContent")]),
                display: .init(title: "File operation", verbatim: true),
                outputPresentation: .init(kind: "fileContent", provenance: requested ? "requested" : "result")), includeOutput: false)
        #expect(inspection.activityKind == (requested ? .fileMutation : .fileContent))
        #expect(inspection.outlineSummary(argsSummary: "") == "File operation example.swift")
        #expect(inspection.activityLabel == "Running File operation")
    }
}
