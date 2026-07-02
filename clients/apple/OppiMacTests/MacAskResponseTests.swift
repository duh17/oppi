import Testing
@testable import Oppi

@Suite("Mac ask response")
struct MacAskResponseTests {

    @Test func encodesSingleMultiAndCustomAnswersDeterministically() {
        let encoded = MacAskResponseEncoder.encode([
            "choice": .single("swift"),
            "many": .multi(["b", "a"]),
            "note": .custom("ship it"),
        ])

        #expect(encoded == #"{"choice":"swift","many":["a","b"],"note":"ship it"}"#)
    }

    @Test func draftTogglesMultiSelectOptions() {
        let option = AskOption(value: "a", label: "A")
        let question = AskQuestion(id: "q", question: "Pick", options: [option], multiSelect: true)
        var draft = MacAskResponseDraft()

        draft.toggle(option, question: question)
        #expect(draft.isSelected(option, question: question))
        #expect(draft.encodedValue() == #"{"q":["a"]}"#)

        draft.toggle(option, question: question)
        #expect(!draft.isSelected(option, question: question))
        #expect(draft.isEmpty)
    }

    @Test func draftTrimsEmptyCustomAnswers() {
        let question = AskQuestion(id: "q", question: "Why?", options: [], multiSelect: false)
        var draft = MacAskResponseDraft()

        draft.setCustom("  useful detail  ", question: question)
        #expect(draft.encodedValue() == #"{"q":"useful detail"}"#)

        draft.setCustom("   ", question: question)
        #expect(draft.isEmpty)
    }

    @Test func encodesInlineSelectAsRawValue() throws {
        let request = AskRequest(
            id: "select-1",
            sessionId: "session-1",
            questions: [],
            allowCustom: false,
            timeout: nil,
            responseEncoding: .extensionSelect
        )
        var draft = MacAskResponseDraft()
        let question = AskQuestion(
            id: MacAskResponseEncoder.inlineQuestionId,
            question: "Pick",
            options: [AskOption(value: "A", label: "A")],
            multiSelect: false
        )
        draft.toggle(AskOption(value: "A", label: "A"), question: question)

        let encoded = try MacAskResponseEncoder.responseMessage(request: request, draft: draft).jsonString()
        #expect(encoded.contains(#""value":"A""#))
    }

    @Test func encodesInlineConfirmAsBooleanOrCancel() throws {
        let request = AskRequest(
            id: "confirm-1",
            sessionId: "session-1",
            questions: [],
            allowCustom: false,
            timeout: nil,
            responseEncoding: .extensionConfirm
        )
        var draft = MacAskResponseDraft()
        let question = AskQuestion(
            id: MacAskResponseEncoder.inlineQuestionId,
            question: "Confirm?",
            options: [AskOption(value: MacAskResponseEncoder.confirmValue, label: "Confirm")],
            multiSelect: false
        )
        draft.toggle(AskOption(value: MacAskResponseEncoder.confirmValue, label: "Confirm"), question: question)

        let confirmed = try MacAskResponseEncoder.responseMessage(request: request, draft: draft).jsonString()
        let cancelled = try MacAskResponseEncoder.responseMessage(request: request, draft: MacAskResponseDraft()).jsonString()
        #expect(confirmed.contains(#""confirmed":true"#))
        #expect(cancelled.contains(#""cancelled":true"#))
    }
}
