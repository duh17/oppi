#if DEBUG
import Foundation

/// Shared isolated QA session for Compact turns and Session Outline.
@MainActor
enum ToolInspectionPreviewFixture {
    private struct ToolCase {
        let id: String
        let name: String
        let args: [String: JSONValue]
        let input: ToolInputPresentation?
        let output: ToolOutputPresentation
        let display: ToolDisplay?
    }

    static func makeReducer() -> TimelineReducer {
        let reducer = TimelineReducer()
        reducer.appendUserMessage("Inspect tools using producer facts")
        let cases: [ToolCase] = [
            .init(id: "shell", name: "bash", args: ["command": "printf 'hello from the terminal'"], input: .init(fields: ["command": .init(role: "command", language: "shell")]), output: .init(kind: "terminal"), display: .init(title: "Bash")),
            .init(id: "read", name: "read", args: ["path": "Sources/Example.swift"], input: .init(fields: ["path": .init(role: "filePath")]), output: .init(kind: "fileContent", provenance: "result"), display: .init(title: "Read")),
            .init(id: "write", name: "write", args: ["path": "Sources/New.swift", "content": "let value = 1"], input: .init(fields: ["path": .init(role: "filePath"), "content": .init(role: "fileContent")]), output: .init(kind: "fileContent", provenance: "requested"), display: .init(title: "Write")),
            .init(id: "edit", name: "edit", args: ["path": "Sources/Example.swift", "edits": [["oldText": "a", "newText": "b\nc\nd"]]], input: .init(fields: ["path": .init(role: "filePath"), "edits": .init(role: "edits")]), output: .init(kind: "diffOfEdits"), display: .init(title: "Edit")),
            .init(id: "mcp", name: "mcp__catalog__find_items", args: ["query": "inspect"], input: nil, output: .init(kind: "structured"), display: .init(title: "Find items", group: "Catalog", verbatim: true)),
            .init(id: "code", name: "codemode", args: ["code": "await lookup()"], input: .init(fields: ["code": .init(role: "code", language: "javascript")]), output: .init(kind: "structured"), display: .init(title: "Code mode")),
            .init(id: "ask", name: "choose_next", args: ["questions": [["id": "q", "question": "Continue?"]]], input: nil, output: .init(kind: "interactive"), display: .init(title: "Choose next"))
        ]
        for tool in cases {
            reducer.process(.toolStart(sessionId: "preview", toolEventId: tool.id, tool: tool.name, args: tool.args,
                inputPresentation: tool.input, display: tool.display, outputPresentation: tool.output))
            reducer.process(.toolEnd(sessionId: "preview", toolEventId: tool.id,
                details: tool.id == "edit" ? ["diff": "-1 a\n+1 b"] : nil,
                nestedCalls: tool.id == "code" ? .init(calls: [.init(id: "child", name: "mcp__catalog__lookup", display: .init(title: "Lookup", group: "Catalog"), status: "ok")], complete: true) : nil))
        }
        reducer.process(.compactionEnd(sessionId: "preview", aborted: false, willRetry: false, summary: nil, tokensBefore: 42000))
        return reducer
    }
}
#endif
