import Foundation
import Testing

@testable import Oppi

@Suite("TimelineReducer ask tool handling")
@MainActor
struct TimelineReducerAskTests {

    // MARK: - formatAskAnswers

    @Test("formatAskAnswers with full answers")
    func formatAskAnswersFullAnswers() {
        let details: JSONValue = .object([
            "questions": .array([
                .object(["id": .string("color"), "question": .string("Pick a color")]),
                .object(["id": .string("size"), "question": .string("Pick a size")]),
            ]),
            "answers": .object([
                "color": .string("blue"),
                "size": .string("large"),
            ]),
            "allIgnored": .bool(false),
        ])
        #expect(TimelineReducer.formatAskAnswers(details: details) == "color → blue\nsize → large")
    }

    @Test("formatAskAnswers with skipped question")
    func formatAskAnswersSkipped() {
        let details: JSONValue = .object([
            "questions": .array([
                .object(["id": .string("color"), "question": .string("Pick a color")]),
                .object(["id": .string("size"), "question": .string("Pick a size")]),
            ]),
            "answers": .object(["color": .string("red")]),
            "allIgnored": .bool(false),
        ])
        #expect(TimelineReducer.formatAskAnswers(details: details) == "color → red\nsize → (skipped)")
    }

    @Test("formatAskAnswers with allIgnored returns empty")
    func formatAskAnswersAllIgnored() {
        let details: JSONValue = .object([
            "questions": .array([.object(["id": .string("q1")])]),
            "answers": .object([:]),
            "allIgnored": .bool(true),
        ])
        #expect(TimelineReducer.formatAskAnswers(details: details).isEmpty)
    }

    @Test("formatAskAnswers with multi-select array")
    func formatAskAnswersMultiSelect() {
        let details: JSONValue = .object([
            "questions": .array([.object(["id": .string("tools")])]),
            "answers": .object(["tools": .array([.string("ruff"), .string("mypy")])]),
            "allIgnored": .bool(false),
        ])
        #expect(TimelineReducer.formatAskAnswers(details: details) == "tools → ruff, mypy")
    }

    @Test("formatAskAnswers with nil details returns empty")
    func formatAskAnswersNilDetails() {
        #expect(TimelineReducer.formatAskAnswers(details: nil).isEmpty)
    }

    // MARK: - Ask tool handling in timeline

    @Test("ask toolStart creates tool row")
    func askToolStartCreatesRow() {
        let reducer = TimelineReducer()
        reducer.process(.toolStart(
            sessionId: "s1", toolEventId: "ask-evt-1", tool: "ask",
            args: ["questions": .array([.object(["id": .string("q1")])])],
            callSegments: [StyledSegment(text: "Pick a color", style: .muted)]
        ))
        #expect(reducer.items.contains(where: {
            if case .toolCall(let id, _, _, _, _, _, _) = $0 { return id == "ask-evt-1" }
            return false
        }))
    }

    @Test("ask toolEnd injects user message with answers")
    func askToolEndInjectsUserMessage() {
        let reducer = TimelineReducer()
        reducer.process(.toolStart(
            sessionId: "s1", toolEventId: "ask-evt-1", tool: "ask", args: [:]
        ))
        reducer.process(.toolEnd(
            sessionId: "s1", toolEventId: "ask-evt-1",
            details: .object([
                "questions": .array([.object(["id": .string("approach")])]),
                "answers": .object(["approach": .string("full_rewrite")]),
                "allIgnored": .bool(false),
            ])
        ))
        var foundText: String?
        for item in reducer.items {
            if case .userMessage(let id, let text, _, _) = item, id == "ask-answer-ask-evt-1" {
                foundText = text
            }
        }
        #expect(foundText == "approach → full_rewrite")
    }

    @Test("ask toolOutput is suppressed")
    func askToolOutputSuppressed() {
        let reducer = TimelineReducer()
        reducer.process(.toolStart(
            sessionId: "s1", toolEventId: "ask-evt-1", tool: "ask", args: [:]
        ))
        let countBefore = reducer.items.count
        reducer.process(.toolOutput(.init(
            sessionId: "s1", toolEventId: "ask-evt-1",
            output: "approach: full_rewrite",
            isError: false, mode: .append, truncated: false, totalBytes: nil
        )))
        // Item count shouldn't change (output suppressed)
        #expect(reducer.items.count == countBefore)
    }

    @Test("ask toolEnd marks tool row as done")
    func askToolEndMarksRowDone() {
        let reducer = TimelineReducer()
        reducer.process(.toolStart(
            sessionId: "s1", toolEventId: "ask-evt-1", tool: "ask", args: [:]
        ))
        reducer.process(.toolEnd(
            sessionId: "s1", toolEventId: "ask-evt-1",
            details: .object([
                "questions": .array([.object(["id": .string("q1")])]),
                "answers": .object(["q1": .string("yes")]),
                "allIgnored": .bool(false),
            ])
        ))
        let toolRow = reducer.items.first(where: {
            if case .toolCall(let id, _, _, _, _, _, _) = $0 { return id == "ask-evt-1" }
            return false
        })
        if case .toolCall(_, _, _, _, _, _, let isDone) = toolRow {
            #expect(isDone)
        }
    }

    @Test("non-ask tool not affected by ask handling")
    func nonAskToolUnaffected() {
        let reducer = TimelineReducer()
        reducer.process(.toolStart(
            sessionId: "s1", toolEventId: "bash-1", tool: "bash",
            args: ["command": .string("ls")]
        ))
        reducer.process(.toolEnd(
            sessionId: "s1", toolEventId: "bash-1"
        ))
        #expect(!reducer.items.contains(where: {
            if case .userMessage = $0 { return true }
            return false
        }))
    }
}
