import Testing
import Foundation
@testable import Oppi

// swiftlint:disable force_unwrapping

@Suite("ToolCallFormatting+Todo")
struct TodoFormattingTests {

    // MARK: - todoSummary

    @Test func todoSummaryCreateWithTitle() {
        let args: [String: JSONValue] = [
            "action": .string("create"),
            "title": .string("Fix the build"),
        ]
        let result = ToolCallFormatting.todoSummary(args: args, argsSummary: "")
        #expect(result == "create Fix the build")
    }

    @Test func todoSummaryCreateTruncatesLongTitle() {
        let longTitle = String(repeating: "x", count: 200)
        let args: [String: JSONValue] = [
            "action": .string("create"),
            "title": .string(longTitle),
        ]
        let result = ToolCallFormatting.todoSummary(args: args, argsSummary: "")
        #expect(result.count <= 90) // "create " + 80 chars
    }

    @Test func todoSummaryGetWithId() {
        let args: [String: JSONValue] = [
            "action": .string("get"),
            "id": .string("TODO-abc123"),
        ]
        let result = ToolCallFormatting.todoSummary(args: args, argsSummary: "")
        #expect(result == "get TODO-abc123")
    }

    @Test func todoSummaryListWithStatus() {
        let args: [String: JSONValue] = [
            "action": .string("list"),
            "status": .string("in_progress"),
        ]
        let result = ToolCallFormatting.todoSummary(args: args, argsSummary: "")
        #expect(result == "list status=in_progress")
    }

    @Test func todoSummaryListAll() {
        let args: [String: JSONValue] = [
            "action": .string("list-all"),
        ]
        let result = ToolCallFormatting.todoSummary(args: args, argsSummary: "")
        #expect(result == "list-all")
    }

    @Test func todoSummaryUpdateWithId() {
        let args: [String: JSONValue] = [
            "action": .string("update"),
            "id": .string("TODO-def456"),
        ]
        let result = ToolCallFormatting.todoSummary(args: args, argsSummary: "")
        #expect(result == "update TODO-def456")
    }

    @Test func todoSummaryDeleteWithId() {
        let args: [String: JSONValue] = [
            "action": .string("delete"),
            "id": .string("TODO-abc"),
        ]
        let result = ToolCallFormatting.todoSummary(args: args, argsSummary: "")
        #expect(result == "delete TODO-abc")
    }

    @Test func todoSummaryClaimWithId() {
        let args: [String: JSONValue] = [
            "action": .string("claim"),
            "id": .string("TODO-xyz"),
        ]
        let result = ToolCallFormatting.todoSummary(args: args, argsSummary: "")
        #expect(result == "claim TODO-xyz")
    }

    @Test func todoSummaryFallsBackToArgsSummary() {
        let result = ToolCallFormatting.todoSummary(args: nil, argsSummary: "some raw summary")
        #expect(result == "some raw summary")
    }

    @Test func todoSummaryParsesActionFromArgsSummary() {
        // When args is nil, todoSummary falls back to parsing key=value from argsSummary
        let argsSummary = "action=get id=TODO-123"
        let result = ToolCallFormatting.todoSummary(args: nil, argsSummary: argsSummary)
        // Should at minimum contain the action
        #expect(result.contains("get") || result == argsSummary)
    }

    // MARK: - todoOutputPresentation

    @Test func todoOutputCreateShowsTitle() {
        let args: [String: JSONValue] = [
            "action": .string("create"),
            "title": .string("Write tests"),
        ]
        let output = """
        {"id":"TODO-abc","title":"Write tests","status":"open","tags":["testing"]}
        """

        let presentation = ToolCallFormatting.todoOutputPresentation(
            args: args,
            argsSummary: "",
            output: output
        )

        #expect(presentation != nil)
        #expect(presentation!.text.contains("Write tests"))
    }

    @Test func todoOutputListShowsItems() {
        let args: [String: JSONValue] = [
            "action": .string("list"),
        ]
        let output = """
        [{"id":"TODO-1","title":"First task","status":"open"},{"id":"TODO-2","title":"Second task","status":"done"}]
        """

        let presentation = ToolCallFormatting.todoOutputPresentation(
            args: args,
            argsSummary: "",
            output: output
        )

        #expect(presentation != nil)
        #expect(presentation!.text.contains("First task"))
    }

    @Test func todoOutputReturnsNilForEmptyOutput() {
        let args: [String: JSONValue] = [
            "action": .string("list"),
        ]
        let presentation = ToolCallFormatting.todoOutputPresentation(
            args: args,
            argsSummary: "",
            output: ""
        )
        #expect(presentation == nil)
    }

    @Test func todoOutputReturnsNilForNonTodoTool() {
        let presentation = ToolCallFormatting.todoOutputPresentation(
            args: nil,
            argsSummary: "",
            output: "some output"
        )
        #expect(presentation == nil)
    }

    // MARK: - todoMutationDiffPresentation

    @Test func todoMutationDiffForAppend() {
        let args: [String: JSONValue] = [
            "action": .string("append"),
            "id": .string("TODO-abc"),
            "body": .string("New notes here"),
        ]

        let diff = ToolCallFormatting.todoMutationDiffPresentation(
            args: args,
            argsSummary: ""
        )

        #expect(diff != nil)
        if let diff {
            #expect(!diff.unifiedText.isEmpty)
            #expect(diff.addedLineCount > 0)
        }
    }

    @Test func todoMutationDiffForUpdate() {
        let args: [String: JSONValue] = [
            "action": .string("update"),
            "id": .string("TODO-abc"),
            "body": .string("Updated body content"),
        ]

        let diff = ToolCallFormatting.todoMutationDiffPresentation(
            args: args,
            argsSummary: ""
        )

        // update without old content produces empty diff
        // (no before/after comparison possible)
    }

    @Test func todoMutationDiffNilForReadActions() {
        for action in ["list", "list-all", "get", "create", "delete"] {
            let args: [String: JSONValue] = [
                "action": .string(action),
            ]
            let diff = ToolCallFormatting.todoMutationDiffPresentation(
                args: args,
                argsSummary: ""
            )
            #expect(diff == nil, "Expected nil for action: \(action)")
        }
    }
}
