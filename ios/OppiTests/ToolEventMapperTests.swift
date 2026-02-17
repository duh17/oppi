import Testing
import Foundation
@testable import Oppi

@Suite("ToolEventMapper")
struct ToolEventMapperTests {

    // MARK: - Normal sequence

    @MainActor
    @Test func startOutputEndSequenceSharesToolId() {
        let mapper = ToolEventMapper()

        let startEvent = mapper.start(sessionId: "s1", tool: "bash", args: ["command": "ls"])
        guard case .toolStart(_, let startId, let tool, let args) = startEvent else {
            Issue.record("Expected toolStart")
            return
        }
        #expect(tool == "bash")
        #expect(args["command"] == .string("ls"))
        #expect(!startId.isEmpty)

        let outputEvent = mapper.output(sessionId: "s1", output: "file.txt", isError: false)
        guard case .toolOutput(_, let outputId, let output, let isError) = outputEvent else {
            Issue.record("Expected toolOutput")
            return
        }
        #expect(outputId == startId, "output should reuse start's toolEventId")
        #expect(output == "file.txt")
        #expect(!isError)

        let endEvent = mapper.end(sessionId: "s1")
        guard case .toolEnd(_, let endId) = endEvent else {
            Issue.record("Expected toolEnd")
            return
        }
        #expect(endId == startId, "end should reuse start's toolEventId")
    }

    // MARK: - Sequential tools get distinct IDs

    @MainActor
    @Test func sequentialToolsGetDistinctIds() {
        let mapper = ToolEventMapper()

        let start1 = mapper.start(sessionId: "s1", tool: "bash", args: [:])
        guard case .toolStart(_, let id1, _, _) = start1 else {
            Issue.record("Expected toolStart")
            return
        }
        _ = mapper.end(sessionId: "s1")

        let start2 = mapper.start(sessionId: "s1", tool: "read", args: [:])
        guard case .toolStart(_, let id2, _, _) = start2 else {
            Issue.record("Expected toolStart")
            return
        }

        #expect(id1 != id2, "Sequential tools should get distinct IDs")
    }

    // MARK: - Output without start (orphan)

    @MainActor
    @Test func outputWithoutStartGeneratesNewId() {
        let mapper = ToolEventMapper()

        // No start called — output should still produce a valid event
        let event = mapper.output(sessionId: "s1", output: "orphan", isError: true)
        guard case .toolOutput(_, let id, let output, let isError) = event else {
            Issue.record("Expected toolOutput")
            return
        }
        #expect(!id.isEmpty)
        #expect(output == "orphan")
        #expect(isError)
    }

    // MARK: - End without start (orphan)

    @MainActor
    @Test func endWithoutStartGeneratesNewId() {
        let mapper = ToolEventMapper()

        let event = mapper.end(sessionId: "s1")
        guard case .toolEnd(_, let id) = event else {
            Issue.record("Expected toolEnd")
            return
        }
        #expect(!id.isEmpty)
    }

    // MARK: - End clears current ID

    @MainActor
    @Test func endClearsCurrentId() {
        let mapper = ToolEventMapper()

        let start = mapper.start(sessionId: "s1", tool: "bash", args: [:])
        guard case .toolStart(_, let startId, _, _) = start else {
            Issue.record("Expected toolStart")
            return
        }
        _ = mapper.end(sessionId: "s1")

        // After end, output should get a new (different) ID
        let orphanOutput = mapper.output(sessionId: "s1", output: "stray", isError: false)
        guard case .toolOutput(_, let orphanId, _, _) = orphanOutput else {
            Issue.record("Expected toolOutput")
            return
        }
        #expect(orphanId != startId, "After end, new events should get fresh IDs")
    }

    // MARK: - Reset

    @MainActor
    @Test func resetClearsState() {
        let mapper = ToolEventMapper()

        let start = mapper.start(sessionId: "s1", tool: "bash", args: [:])
        guard case .toolStart(_, let startId, _, _) = start else {
            Issue.record("Expected toolStart")
            return
        }

        mapper.reset()

        // After reset, output should get a new ID (not the start's ID)
        let output = mapper.output(sessionId: "s1", output: "after-reset", isError: false)
        guard case .toolOutput(_, let outputId, _, _) = output else {
            Issue.record("Expected toolOutput")
            return
        }
        #expect(outputId != startId, "After reset, should not reuse old toolEventId")
    }

    // MARK: - Session ID passthrough

    @MainActor
    @Test func sessionIdIsPassedThrough() {
        let mapper = ToolEventMapper()

        let start = mapper.start(sessionId: "session-42", tool: "read", args: [:])
        guard case .toolStart(let sid, _, _, _) = start else {
            Issue.record("Expected toolStart")
            return
        }
        #expect(sid == "session-42")

        let output = mapper.output(sessionId: "session-42", output: "data", isError: false)
        guard case .toolOutput(let sid2, _, _, _) = output else {
            Issue.record("Expected toolOutput")
            return
        }
        #expect(sid2 == "session-42")

        let end = mapper.end(sessionId: "session-42")
        guard case .toolEnd(let sid3, _) = end else {
            Issue.record("Expected toolEnd")
            return
        }
        #expect(sid3 == "session-42")
    }

    // MARK: - Args are preserved

    @MainActor
    @Test func argsArePreserved() {
        let mapper = ToolEventMapper()
        let args: [String: JSONValue] = [
            "command": .string("echo hello"),
            "timeout": .number(30),
        ]

        let event = mapper.start(sessionId: "s1", tool: "bash", args: args)
        guard case .toolStart(_, _, _, let resultArgs) = event else {
            Issue.record("Expected toolStart")
            return
        }
        #expect(resultArgs["command"] == .string("echo hello"))
        #expect(resultArgs["timeout"] == .number(30))
    }

    // MARK: - Error output flag

    @MainActor
    @Test func errorOutputFlagIsPreserved() {
        let mapper = ToolEventMapper()
        _ = mapper.start(sessionId: "s1", tool: "bash", args: [:])

        let event = mapper.output(sessionId: "s1", output: "stderr stuff", isError: true)
        guard case .toolOutput(_, _, _, let isError) = event else {
            Issue.record("Expected toolOutput")
            return
        }
        #expect(isError)
    }

    // MARK: - Server-provided toolCallId

    @MainActor
    @Test func serverProvidedToolCallIdIsUsed() {
        let mapper = ToolEventMapper()

        let startEvent = mapper.start(sessionId: "s1", tool: "bash", args: [:], toolCallId: "server-tc-1")
        guard case .toolStart(_, let startId, _, _) = startEvent else {
            Issue.record("Expected toolStart")
            return
        }
        #expect(startId == "server-tc-1", "Should use server-provided toolCallId")

        let outputEvent = mapper.output(sessionId: "s1", output: "data", isError: false, toolCallId: "server-tc-1")
        guard case .toolOutput(_, let outputId, _, _) = outputEvent else {
            Issue.record("Expected toolOutput")
            return
        }
        #expect(outputId == "server-tc-1", "Output should use server-provided toolCallId")

        let endEvent = mapper.end(sessionId: "s1", toolCallId: "server-tc-1")
        guard case .toolEnd(_, let endId) = endEvent else {
            Issue.record("Expected toolEnd")
            return
        }
        #expect(endId == "server-tc-1", "End should use server-provided toolCallId")
    }

    @MainActor
    @Test func outputFallsBackToCurrentToolWhenNoServerToolCallId() {
        let mapper = ToolEventMapper()

        // Start with server-provided ID
        _ = mapper.start(sessionId: "s1", tool: "bash", args: [:], toolCallId: "server-tc-1")

        // Output without server-provided ID falls back to current tool's ID
        let outputEvent = mapper.output(sessionId: "s1", output: "data", isError: false)
        guard case .toolOutput(_, let outputId, _, _) = outputEvent else {
            Issue.record("Expected toolOutput")
            return
        }
        #expect(outputId == "server-tc-1", "Should fall back to current tool's server-provided ID")
    }

    @MainActor
    @Test func noServerIdGeneratesSyntheticUUID() {
        let mapper = ToolEventMapper()

        let startEvent = mapper.start(sessionId: "s1", tool: "bash", args: [:])
        guard case .toolStart(_, let id, _, _) = startEvent else {
            Issue.record("Expected toolStart")
            return
        }
        #expect(!id.isEmpty, "Should generate synthetic UUID when no server ID")
        #expect(id != "server-tc-1", "Should not be a server-style ID")
    }
}
