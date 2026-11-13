import Testing
@testable import Oppi

@Suite("ToolCallFormatting")
struct ToolCallFormattingTests {
    @Test func filePathReadsCanonicalPathOnly() {
        #expect(ToolCallFormatting.filePath(from: ["path": .string("src/main.swift")]) == "src/main.swift")
        #expect(ToolCallFormatting.filePath(from: ["filePath": .string("legacy")]) == nil)
        #expect(ToolCallFormatting.filePath(from: nil) == nil)
    }
    @Test func breadcrumbAndFileNamePreserveLineRange() {
        #expect(ToolCallFormatting.breadcrumbDisplayPath("~/workspace/oppi/src/main.swift:100-149") == "~/w/o/s/main.swift:100-149")
        #expect(ToolCallFormatting.fileNameDisplayPath("~/workspace/main.swift:100-149") == "main.swift:100-149")
    }
    @Test func parseArgValue() {
        #expect(ToolCallFormatting.parseArgValue("command", from: "command: ls -la, timeout: 30") == "ls -la")
        #expect(ToolCallFormatting.parseArgValue("missing", from: "path: file") == nil)
    }
    @Test func formatBytes() {
        #expect(ToolCallFormatting.formatBytes(42) == "42 B")
        #expect(ToolCallFormatting.formatBytes(1024) == "1.0 KB")
        #expect(ToolCallFormatting.formatBytes(1048576) == "1.0 MB")
    }
    @Test func glyphsUseTranslatedSemanticsNotFileToolNames() {
        #expect(ToolContentDescriptorBuilder.glyph(input: nil, output: .init(kind: "fileContent"), details: nil) == "magnifyingglass")
        #expect(ToolContentDescriptorBuilder.glyph(input: .init(fields: ["bytes": .init(role: "fileContent")]), output: .init(kind: "fileContent"), details: nil) == "pencil")
        #expect(ToolContentDescriptorBuilder.glyph(input: nil, output: .init(kind: "diffOfEdits"), details: nil) == "arrow.left.arrow.right")
        #expect(ToolContentDescriptorBuilder.glyph(input: nil, output: nil, details: nil) == nil)
        #expect(ToolContentDescriptorBuilder.glyph(input: nil, output: .init(kind: "interactive"), details: nil) == "questionmark")
    }
    @Test func askCollapsedTitleUsesQuestionCountOnly() {
        let args: [String: JSONValue] = ["questions": .array([
            .object(["id": .string("scope"), "question": .string("Which scope?")]),
            .object(["id": .string("details"), "question": .string("Which details?")])
        ])]
        #expect(ToolCallFormatting.askCollapsedTitle(args: args, details: nil, argsSummary: "") == "2 questions")
    }
    @Test func askAnswerSummaryMarksChosenOptionSelectedWithoutTaskListSyntax() {
        let details: JSONValue = .object([
            "questions": .array([.object([
                "id": .string("scope"), "question": .string("Which scope should I use?"),
                "options": .array([
                    .object(["value": .string("minimal_patch"), "label": .string("Minimal patch"), "description": .string("Smallest safe change")]),
                    .object(["value": .string("full_refactor"), "label": .string("Full refactor")])
                ])
            ])]),
            "answers": .object(["scope": .string("minimal_patch")]),
            "allIgnored": .bool(false),
        ])
        // The chosen option is a filled radio in bold; no `- [x]`, which the timeline strikes through.
        #expect(ToolCallFormatting.askAnswerSummary(details: details) == "**Q:** Which scope should I use?\n◉ **Minimal patch** — Smallest safe change\n○ Full refactor")
    }

    @Test func askAnswerSummaryMarksEveryChosenOptionOfAMultiSelect() {
        let details: JSONValue = .object([
            "questions": .array([.object([
                "id": .string("checks"), "question": .string("Which checks?"), "multiSelect": .bool(true),
                "options": .array([
                    .object(["value": .string("lint"), "label": .string("Lint")]),
                    .object(["value": .string("unit"), "label": .string("Unit tests")]),
                    .object(["value": .string("e2e"), "label": .string("End-to-end")])
                ])
            ])]),
            "answers": .object(["checks": .array([.string("lint"), .string("e2e")])]),
            "allIgnored": .bool(false),
        ])
        #expect(ToolCallFormatting.askAnswerSummary(details: details) == "**Q:** Which checks?\n☑ **Lint**\n☐ Unit tests\n☑ **End-to-end**")
    }

    @Test func askAnswerSummaryShowsATypedAnswerAndSelectsNoOption() {
        let details: JSONValue = .object([
            "questions": .array([.object([
                "id": .string("branch"), "question": .string("Where should this land?"),
                "options": .array([
                    .object(["value": .string("main"), "label": .string("main")]),
                    .object(["value": .string("feature"), "label": .string("A feature branch")])
                ])
            ])]),
            "answers": .object(["branch": .string("Open a draft PR instead")]),
            "allIgnored": .bool(false),
        ])
        #expect(ToolCallFormatting.askAnswerSummary(details: details) == "**Q:** Where should this land?\n○ main\n○ A feature branch\n**A:** Open a draft PR instead")
    }
}
