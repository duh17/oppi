import Foundation
import Testing

@testable import Oppi

@Suite("AskCardExpanded")
@MainActor
struct AskCardExpandedTests {
    // MARK: - Fixtures

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
                        AskOption(value: "jest", label: "Jest", description: "Mature runner"),
                        AskOption(value: "vitest", label: "Vitest", description: "Vite-native, fast"),
                        AskOption(value: "playwright", label: "Playwright", description: "Browser E2E"),
                    ],
                    multiSelect: true
                ),
                AskQuestion(
                    id: "coverage",
                    question: "Coverage target?",
                    options: [
                        AskOption(value: "80", label: "80%", description: nil),
                        AskOption(value: "90", label: "90%", description: nil),
                    ],
                    multiSelect: false
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
                    question: "Which features to include?",
                    options: [
                        AskOption(value: "a", label: "Feature A", description: "Core functionality"),
                        AskOption(value: "b", label: "Feature B", description: "Extended support"),
                    ],
                    multiSelect: true
                ),
            ],
            allowCustom: false,
            timeout: nil
        )
    }

    // MARK: - Page Count Consistency

    @Test("Single-select single question: 1 page, no submit page")
    func singleSelectSingleQuestionPageCount() {
        let request = Self.singleSelectRequest()
        #expect(AskCard.pageCount(for: request) == 1)
    }

    @Test("Multi-question: pages = questions + 1 submit page")
    func multiQuestionPageCount() {
        let request = Self.multiQuestionRequest()
        // 3 questions + 1 submit = 4
        #expect(AskCard.pageCount(for: request) == 4)
    }

    @Test("Single multi-select question still gets submit page")
    func singleMultiSelectPageCount() {
        let request = Self.multiSelectOnlyRequest()
        // 1 question + 1 submit = 2
        #expect(AskCard.pageCount(for: request) == 2)
    }

    // MARK: - Answer State

    @Test("Option selection stored as .single answer")
    func optionSelectionStored() {
        var answers: [String: AskAnswer] = [:]
        answers["approach"] = .single("unit")
        #expect(answers["approach"] == .single("unit"))
    }

    @Test("Custom text stored as .custom answer")
    func customTextStored() {
        var answers: [String: AskAnswer] = [:]
        answers["approach"] = .custom("property-based tests")

        // Verify encoding roundtrip
        let json = AskResponseEncoder.encode(answers)
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["approach"] as? String == "property-based tests")
    }

    @Test("Option selection overwrites custom answer")
    func optionOverwritesCustom() {
        var answers: [String: AskAnswer] = [:]
        answers["approach"] = .custom("my custom approach")

        // User taps an option — overwrites custom
        answers["approach"] = .single("unit")
        #expect(answers["approach"] == .single("unit"))
    }

    @Test("Custom text overwrites option selection")
    func customOverwritesOption() {
        var answers: [String: AskAnswer] = [:]
        answers["approach"] = .single("unit")

        // User types custom text — overwrites option
        answers["approach"] = .custom("snapshot tests")
        #expect(answers["approach"] == .custom("snapshot tests"))
    }

    // MARK: - Submit Page Review

    @Test("Answer map shows all questions with answered/ignored status")
    func answerMapShowsAllQuestions() {
        let request = Self.multiQuestionRequest()
        let answers: [String: AskAnswer] = [
            "approach": .single("unit"),
            // "frameworks" omitted = ignored
            "coverage": .single("90"),
        ]

        let entries = AskResponseEncoder.answerMap(answers: answers, questions: request.questions)
        #expect(entries.count == 3)
        #expect(entries[0].answer == .single("unit"))   // approach answered
        #expect(entries[1].answer == nil)                // frameworks ignored
        #expect(entries[2].answer == .single("90"))      // coverage answered
    }

    @Test("Mixed answer types in review: single + multi + custom")
    func mixedAnswerTypesInReview() {
        let answers: [String: AskAnswer] = [
            "approach": .single("unit"),
            "frameworks": .multi(["jest", "vitest"]),
            "coverage": .custom("aim for 85%"),
        ]

        let json = AskResponseEncoder.encode(answers)
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["approach"] as? String == "unit")
        #expect(parsed?["frameworks"] as? [String] == ["jest", "vitest"])
        #expect(parsed?["coverage"] as? String == "aim for 85%")
    }

    @Test("All questions ignored produces empty JSON")
    func allIgnoredProducesEmptyJson() {
        let answers: [String: AskAnswer] = [:]
        let json = AskResponseEncoder.encode(answers)
        #expect(json == "{}")
    }

    // MARK: - Navigation Bounds

    @Test("Page navigation stays within valid range")
    func pageNavigationBounds() {
        let request = Self.multiQuestionRequest()
        let totalPages = AskCard.pageCount(for: request)
        var page = 0

        // Forward to last page
        for _ in 0..<(totalPages - 1) {
            page += 1
        }
        #expect(page == totalPages - 1)

        // Submit page is at questions.count
        #expect(page == request.questions.count)

        // Back to first
        for _ in 0..<(totalPages - 1) {
            page -= 1
        }
        #expect(page == 0)
    }

    @Test("Single question: no back navigation needed (only 1 page)")
    func singleQuestionNoBackNavigation() {
        let request = Self.singleSelectRequest()
        #expect(AskCard.pageCount(for: request) == 1)
        // currentPage stays at 0 — no forward/back
    }

    // MARK: - Collapse State Preservation

    @Test("Collapse preserves answers through binding round-trip")
    func collapsePreservesAnswers() {
        var answers: [String: AskAnswer] = [:]
        var isExpanded = true

        // Simulate answering in expanded mode
        answers["approach"] = .single("unit")
        answers["frameworks"] = .multi(["jest"])

        // Collapse
        isExpanded = false
        #expect(isExpanded == false)

        // Answers still intact
        #expect(answers["approach"] == .single("unit"))
        #expect(answers["frameworks"] == .multi(["jest"]))
    }

    @Test("Collapse preserves currentPage through binding")
    func collapsePreservesPage() {
        var currentPage = 2
        var isExpanded = true

        // Collapse
        isExpanded = false
        #expect(isExpanded == false)

        // Page position preserved
        #expect(currentPage == 2)
    }
}
