import Foundation
import Testing

@testable import Oppi

@Suite("AskResponseEncoder")
struct AskResponseEncoderTests {

    @Test("encode single-select answers")
    func encodeSingleSelect() {
        let answers: [String: AskAnswer] = [
            "color": .single("blue"),
            "size": .single("large"),
        ]
        let json = AskResponseEncoder.encode(answers)
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["color"] as? String == "blue")
        #expect(parsed?["size"] as? String == "large")
    }

    @Test("encode multi-select answers as a sorted array")
    func encodeMultiSelect() {
        let answers: [String: AskAnswer] = [
            "tools": .multi(Set(["ruff", "mypy"])),
        ]
        let json = AskResponseEncoder.encode(answers)
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["tools"] as? [String] == ["mypy", "ruff"])
    }

    @Test("encode custom text answer")
    func encodeCustomText() {
        let answers: [String: AskAnswer] = [
            "approach": .custom("my own approach"),
        ]
        let json = AskResponseEncoder.encode(answers)
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?["approach"] as? String == "my own approach")
    }

    @Test("encode mixed answer types")
    func encodeMixedAnswerTypes() {
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

    @Test("encode empty answers produces empty JSON object")
    func encodeEmpty() {
        let json = AskResponseEncoder.encode([:])
        #expect(json == "{}")
    }

    @Test("ignored questions are omitted from encoded output")
    func encodeIgnoredOmitted() {
        let answers: [String: AskAnswer] = [
            "q1": .single("yes"),
        ]
        let json = AskResponseEncoder.encode(answers)
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?.count == 1)
        #expect(parsed?["q1"] as? String == "yes")
        #expect(parsed?["q2"] == nil)
    }

    @Test("encode sorts object keys and multi-select values deterministically")
    func encodeDeterministicSortedKeys() {
        let encoded = AskResponseEncoder.encode([
            "choice": .single("swift"),
            "many": .multi(["b", "a"]),
            "note": .custom("ship it"),
        ])
        #expect(encoded == #"{"choice":"swift","many":["a","b"],"note":"ship it"}"#)
    }

    @Test("answer map keeps ignored questions as nil values")
    func answerMapOmitsIgnoredValues() {
        let questions = [
            AskQuestion(id: "approach", question: "Testing approach?", options: [], multiSelect: false),
            AskQuestion(id: "frameworks", question: "Which frameworks?", options: [], multiSelect: true),
        ]
        let answers: [String: AskAnswer] = ["approach": .single("unit")]
        let map = AskResponseEncoder.answerMap(answers: answers, questions: questions)
        #expect(map.count == 2)
        #expect(map[0].answer == .single("unit"))
        #expect(map[1].answer == nil)
    }

    @Test("answer map shows all questions with answered or ignored status")
    func answerMapShowsAllQuestions() {
        let questions = [
            AskQuestion(id: "approach", question: "Testing approach?", options: [], multiSelect: false),
            AskQuestion(id: "frameworks", question: "Which frameworks?", options: [], multiSelect: true),
            AskQuestion(id: "coverage", question: "Coverage target?", options: [], multiSelect: false),
        ]
        let answers: [String: AskAnswer] = [
            "approach": .single("unit"),
            "coverage": .single("90"),
        ]
        let entries = AskResponseEncoder.answerMap(answers: answers, questions: questions)
        #expect(entries.count == 3)
        #expect(entries[0].answer == .single("unit"))
        #expect(entries[1].answer == nil)
        #expect(entries[2].answer == .single("90"))
    }

    @Test("AskAnswer equatable distinguishes cases and values")
    func askAnswerEquatable() {
        #expect(AskAnswer.single("a") == AskAnswer.single("a"))
        #expect(AskAnswer.single("a") != AskAnswer.single("b"))
        #expect(AskAnswer.multi(["a", "b"]) == AskAnswer.multi(["a", "b"]))
        #expect(AskAnswer.multi(["a"]) != AskAnswer.multi(["a", "b"]))
        #expect(AskAnswer.custom("x") == AskAnswer.custom("x"))
        #expect(AskAnswer.custom("x") != AskAnswer.single("x"))
    }
}
