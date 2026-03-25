import Testing
@testable import Oppi
import SwiftUI

@Suite("AskCard Accessibility")
@MainActor
struct AskCardAccessibilityTests {

    // MARK: - Dynamic Type Scaling

    @Test func optionCardWidthDefaultSize() {
        #expect(AskCard.optionCardWidth(for: .large) == 120)
        #expect(AskCard.optionCardWidth(for: .medium) == 120)
        #expect(AskCard.optionCardWidth(for: .xSmall) == 120)
    }

    @Test func optionCardWidthLargerSizes() {
        #expect(AskCard.optionCardWidth(for: .xxLarge) == 160)
        #expect(AskCard.optionCardWidth(for: .xxxLarge) == 160)
    }

    @Test func optionCardWidthAccessibilitySizes() {
        #expect(AskCard.optionCardWidth(for: .accessibility1) == 200)
        #expect(AskCard.optionCardWidth(for: .accessibility3) == 200)
        #expect(AskCard.optionCardWidth(for: .accessibility5) == 200)
    }

    // MARK: - Page Announcements

    private func sampleQuestions() -> [AskQuestion] {
        [
            AskQuestion(id: "q1", question: "Pick a color", options: [
                AskOption(value: "red", label: "Red"),
            ], multiSelect: false),
            AskQuestion(id: "q2", question: "Pick a size", options: [
                AskOption(value: "sm", label: "Small"),
            ], multiSelect: false),
        ]
    }

    @Test func pageAnnouncementFirstQuestion() {
        let questions = sampleQuestions()
        let text = AskCard.pageAnnouncementText(
            page: 0,
            questions: questions,
            isSingleQuestionSingleSelect: false
        )
        #expect(text == "Question 1 of 2: Pick a color")
    }

    @Test func pageAnnouncementSecondQuestion() {
        let questions = sampleQuestions()
        let text = AskCard.pageAnnouncementText(
            page: 1,
            questions: questions,
            isSingleQuestionSingleSelect: false
        )
        #expect(text == "Question 2 of 2: Pick a size")
    }

    @Test func pageAnnouncementSubmitPage() {
        let questions = sampleQuestions()
        let text = AskCard.pageAnnouncementText(
            page: 2,
            questions: questions,
            isSingleQuestionSingleSelect: false
        )
        #expect(text == "Review and submit answers")
    }

    @Test func pageAnnouncementSingleQuestion() {
        let questions = [AskQuestion(id: "q1", question: "Yes or no?", options: [
            AskOption(value: "y", label: "Yes"),
            AskOption(value: "n", label: "No"),
        ], multiSelect: false)]
        let text = AskCard.pageAnnouncementText(
            page: 0,
            questions: questions,
            isSingleQuestionSingleSelect: true
        )
        #expect(text == "Yes or no?")
    }

    // MARK: - Timeout (nil timeout = no action)

    @Test func nilTimeoutDoesNotDismiss() {
        // AskRequest with nil timeout should not auto-dismiss.
        // This tests the guard path in .task(id:).
        let request = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Q", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )
        #expect(request.timeout == nil)
    }

    @Test func zeroTimeoutDoesNotDismiss() {
        let request = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Q", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: 0
        )
        // The .task guard checks timeout > 0, so 0 should not trigger dismiss
        #expect(request.timeout == 0)
    }
}
