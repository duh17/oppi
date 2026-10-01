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
    @Test func askAnswerSummaryRendersOptionsWithSelectedLabelChecked() {
        let details: JSONValue = .object([
            "questions": .array([.object([
                "id": .string("scope"), "question": .string("Which scope should I use?"),
                "options": .array([
                    .object(["value": .string("minimal_patch"), "label": .string("Minimal patch"), "description": .string("Smallest safe change")]),
                    .object(["value": .string("full_refactor"), "label": .string("Full refactor")])
                ])
            ])]), "answers": .object(["scope": .string("minimal_patch")]), "allIgnored": .bool(false)
        ])
        #expect(ToolCallFormatting.askAnswerSummary(details: details) == "**Q:** Which scope should I use?\n- [x] Minimal patch — Smallest safe change\n- [ ] Full refactor")
    }
}
