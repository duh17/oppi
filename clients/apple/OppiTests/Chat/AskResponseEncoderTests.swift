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

    @Test("encode multi-select answers")
    func encodeMultiSelect() {
        let answers: [String: AskAnswer] = [
            "tools": .multi(Set(["ruff", "mypy"])),
        ]
        let json = AskResponseEncoder.encode(answers)
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let tools = parsed?["tools"] as? [String]
        #expect(tools != nil)
        #expect(tools?.contains("ruff") == true)
        #expect(tools?.contains("mypy") == true)
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

    @Test("encode empty answers produces empty JSON object")
    func encodeEmpty() {
        let json = AskResponseEncoder.encode([:])
        #expect(json == "{}")
    }

    @Test("ignored questions are omitted from encoded output")
    func encodeIgnoredOmitted() {
        let answers: [String: AskAnswer] = [
            "q1": .single("yes"),
            // q2 is not present — ignored
        ]
        let json = AskResponseEncoder.encode(answers)
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(parsed?.count == 1)
        #expect(parsed?["q1"] as? String == "yes")
        #expect(parsed?["q2"] == nil)
    }
}
