import Foundation
import SwiftUI
import Testing

@testable import Oppi

@Suite("AskCard")
@MainActor
struct AskCardTests {
    // MARK: - Test Fixtures

    private static func singleSelectRequest() -> AskRequest {
        AskRequest(
            id: "ask-1",
            sessionId: "session-1",
            questions: [
                AskQuestion(
                    id: "approach",
                    question: "What testing approach?",
                    options: [
                        AskOption(value: "unit", label: "Unit tests", description: "Fast, isolated"),
                        AskOption(value: "integration", label: "Integration", description: "End-to-end"),
                        AskOption(value: "both", label: "Both", description: nil),
                    ],
                    multiSelect: false
                ),
            ],
            allowCustom: true,
            timeout: nil
        )
    }

    private static func multiQuestionRequest() -> AskRequest {
        AskRequest(
            id: "ask-2",
            sessionId: "session-1",
            questions: [
                AskQuestion(
                    id: "approach",
                    question: "Testing approach?",
                    options: [
                        AskOption(value: "unit", label: "Unit", description: nil),
                        AskOption(value: "integration", label: "Integration", description: nil),
                    ],
                    multiSelect: false
                ),
                AskQuestion(
                    id: "frameworks",
                    question: "Which frameworks?",
                    options: [
                        AskOption(value: "jest", label: "Jest", description: "Mature"),
                        AskOption(value: "vitest", label: "Vitest", description: "Fast"),
                        AskOption(value: "playwright", label: "Playwright", description: "E2E"),
                    ],
                    multiSelect: true
                ),
            ],
            allowCustom: true,
            timeout: 120_000
        )
    }

    private static func multiSelectOnlyRequest() -> AskRequest {
        AskRequest(
            id: "ask-3",
            sessionId: "session-1",
            questions: [
                AskQuestion(
                    id: "features",
                    question: "Which features?",
                    options: [
                        AskOption(value: "a", label: "Feature A", description: nil),
                        AskOption(value: "b", label: "Feature B", description: nil),
                    ],
                    multiSelect: true
                ),
            ],
            allowCustom: false,
            timeout: nil
        )
    }

    // MARK: - AskAnswer Encoding

    @Test("Single-select encodes as string value")
    func singleSelectEncoding() {
        let answers: [String: AskAnswer] = ["approach": .single("unit")]
        let json = AskResponseEncoder.encode(answers)
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["approach"] as? String == "unit")
    }

    @Test("Multi-select encodes as sorted array")
    func multiSelectEncoding() {
        let answers: [String: AskAnswer] = ["frameworks": .multi(["vitest", "jest"])]
        let json = AskResponseEncoder.encode(answers)
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let values = parsed?["frameworks"] as? [String]
        #expect(values == ["jest", "vitest"])
    }

    @Test("Custom text encodes as string value")
    func customTextEncoding() {
        let answers: [String: AskAnswer] = ["approach": .custom("property-based tests")]
        let json = AskResponseEncoder.encode(answers)
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["approach"] as? String == "property-based tests")
    }

    @Test("Mixed answer types encode correctly")
    func mixedAnswerEncoding() {
        let answers: [String: AskAnswer] = [
            "approach": .single("unit"),
            "frameworks": .multi(["jest", "vitest"]),
        ]
        let json = AskResponseEncoder.encode(answers)
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["approach"] as? String == "unit")
        #expect(parsed?["frameworks"] as? [String] == ["jest", "vitest"])
    }

    @Test("Empty answers encode as empty object")
    func emptyAnswersEncoding() {
        let answers: [String: AskAnswer] = [:]
        let json = AskResponseEncoder.encode(answers)
        #expect(json == "{}")
    }

    // MARK: - Inline Preview

    @Test("Short inline questions do not use compact preview")
    func shortInlineQuestionDoesNotUsePreview() {
        #expect(AskCard.usesInlineQuestionPreview("Pick an option", dynamicTypeSize: .large) == false)
    }

    @Test("Long inline questions use compact preview")
    func longInlineQuestionUsesPreview() {
        let question = (1...9).map { "Detail line \($0)" }.joined(separator: "\n")
        #expect(AskCard.usesInlineQuestionPreview(question, dynamicTypeSize: .large) == true)
    }

    @Test("Accessibility sizes keep a larger inline question preview")
    func accessibilityInlineQuestionPreviewLimit() {
        #expect(AskCard.inlineQuestionLineLimit(for: .accessibility1) > AskCard.inlineQuestionLineLimit(for: .large))
    }

    @Test("Inline question display extracts fenced command preview")
    func inlineQuestionDisplayExtractsFencedCommandPreview() {
        let question = """
        Git push

        Pushing writes to a remote repository.

        ### Command

        ```bash
        git push origin main
        ```
        """

        let display = AskCard.inlineQuestionDisplay(for: question)

        #expect(display.summary == "Git push\n\nPushing writes to a remote repository.")
        #expect(display.commandPreview == "git push origin main")
    }

    @Test("Inline question display extracts unfenced command preview")
    func inlineQuestionDisplayExtractsUnfencedCommandPreview() {
        let question = """
        Review this command before allowing it.

        ### Command

        npm test -- --runInBand

        Allow this tool call?
        """

        let display = AskCard.inlineQuestionDisplay(for: question)

        #expect(display.summary == "Review this command before allowing it.")
        #expect(display.commandPreview == "npm test -- --runInBand")
    }

    @Test("Inline question display leaves ordinary questions unchanged")
    func inlineQuestionDisplayLeavesOrdinaryQuestionUnchanged() {
        let display = AskCard.inlineQuestionDisplay(for: "Pick an option")

        #expect(display.summary == "Pick an option")
        #expect(display.commandPreview == nil)
    }

    // MARK: - Selection Mode

    @Test("Multi-select questions expose explicit selection mode hint")
    func multiSelectQuestionsExposeSelectionHint() {
        let request = Self.multiSelectOnlyRequest()
        let question = request.questions[0]
        #expect(AskCardShared.selectionModeHint(for: question) == "Select multiple")
    }

    @Test("Single-select questions do not expose multi-select hint")
    func singleSelectQuestionsDoNotExposeSelectionHint() {
        let request = Self.singleSelectRequest()
        let question = request.questions[0]
        #expect(AskCardShared.selectionModeHint(for: question) == nil)
    }

    // MARK: - Page Count

    @Test("Single question single-select skips pager — 1 page")
    func singleQuestionSingleSelectPageCount() {
        let request = Self.singleSelectRequest()
        #expect(AskCard.pageCount(for: request) == 1)
    }

    @Test("Multi-question has one page per question")
    func multiQuestionPageCount() {
        let request = Self.multiQuestionRequest()
        #expect(AskCard.pageCount(for: request) == 2)
    }

    @Test("Single question multi-select stays on one page")
    func singleMultiSelectPageCount() {
        let request = Self.multiSelectOnlyRequest()
        #expect(AskCard.pageCount(for: request) == 1)
    }

    // MARK: - Telemetry Tags

    @Test("Ask response telemetry tags are bounded and content-free")
    func askResponseTelemetryTagsAreBoundedAndContentFree() {
        let request = Self.multiQuestionRequest()
        let tags = AskCard.responseMetricTags(
            request: request,
            answers: [
                "approach": .single("unit"),
                "frameworks": .multi(["jest", "vitest"]),
            ],
            outcome: "answered",
            surface: "inline"
        )

        #expect(tags["outcome"] == "answered")
        #expect(tags["surface"] == "inline")
        #expect(tags["question_count"] == "2")
        #expect(tags["answered_count"] == "2")
        #expect(tags["ignored_count"] == "0")
        #expect(tags["multi_select"] == "1")
        #expect(tags["selected_count"] == "3")
        #expect(tags.values.contains("unit") == false)
        #expect(tags.values.contains("jest") == false)
    }

    // MARK: - Answer Map

    @Test("Ignored question omitted from answer map values")
    func ignoredQuestionOmitted() {
        let request = Self.multiQuestionRequest()
        let answers: [String: AskAnswer] = ["approach": .single("unit")]
        // "frameworks" not in answers = ignored
        let map = AskResponseEncoder.answerMap(answers: answers, questions: request.questions)
        #expect(map.count == 2)
        #expect(map[0].answer != nil) // approach answered
        #expect(map[1].answer == nil) // frameworks ignored
    }

    @Test("All ignored produces empty JSON")
    func allIgnoredProducesEmptyMap() {
        let answers: [String: AskAnswer] = [:]
        let json = AskResponseEncoder.encode(answers)
        #expect(json == "{}")
    }

    @Test("Response JSON structure matches wire format")
    func responseJsonStructure() {
        let answers: [String: AskAnswer] = [
            "q1": .single("value"),
            "q2": .multi(["a", "b"]),
        ]
        let json = AskResponseEncoder.encode(answers)

        // Parse and verify structure
        let data = Data(json.utf8)
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed != nil)
        #expect(parsed?.count == 2)

        // q1 is a string
        #expect(parsed?["q1"] is String)
        #expect(parsed?["q1"] as? String == "value")

        // q2 is an array
        #expect(parsed?["q2"] is [String])
        #expect(parsed?["q2"] as? [String] == ["a", "b"])
    }

    // MARK: - AskAnswer Equatable

    @Test("AskAnswer equatable works")
    func askAnswerEquatable() {
        #expect(AskAnswer.single("a") == AskAnswer.single("a"))
        #expect(AskAnswer.single("a") != AskAnswer.single("b"))
        #expect(AskAnswer.multi(["a", "b"]) == AskAnswer.multi(["a", "b"]))
        #expect(AskAnswer.multi(["a"]) != AskAnswer.multi(["a", "b"]))
        #expect(AskAnswer.custom("x") == AskAnswer.custom("x"))
        #expect(AskAnswer.custom("x") != AskAnswer.single("x"))
    }
}
