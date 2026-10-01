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
        #expect(line.buckets == [.init(kind: .edit, count: 1, editStats: .init(added: resultPatch ? 1 : 3, removed: 1), requestedStats: !resultPatch)])
        #expect(line.workSummary == (resultPatch ? "edit +1 −1" : "Requested edit +3 −1"))
    }

    @Test func arbitraryInteractionStaysVisibleAndOldServerNamesStayGeneric() throws {
        let reducer = TimelineReducer()
        reducer.process(.toolStart(sessionId: "s", toolEventId: "q", tool: "choose_next", args: [:], outputPresentation: .init(kind: "interactive")))
        let projection = QuietTimelineProjection.make(items: reducer.items, isQuiet: true, isBusy: true,
            expandedTurnIDs: [], toolInspection: { reducer.toolInspection(for: $0) })
        #expect(projection.rows.map(\.id) == ["q"])
        for tool in ["bash", "read", "write", "edit", "ask", "mcp__x__read"] {
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
