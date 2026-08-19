import Foundation
import Testing
@testable import Oppi

@Suite("JSON unpaired surrogate repair")
struct JSONUnpairedSurrogateRepairTests {
    @Test func foundationRejectsTruncatedSearchSnippetSurrogate() {
        let data = Self.snippetJSON.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TraceEvent.self, from: data)
        }
    }

    @Test func repairingTruncatedSearchSnippetLetsHistoryDecode() throws {
        let repaired = JSONUnpairedSurrogateRepair.repairing(Self.snippetJSON.data(using: .utf8)!)
        let event = try JSONDecoder().decode(TraceEvent.self, from: repaired)
        #expect(event.type == .system)
        #expect(event.text?.contains("\u{FFFD}") == true)
        #expect(event.text?.contains("GDPval-AA v2") == true)
    }

    @Test func preservesValidEmojiSurrogatePair() throws {
        let json = """
        {"id":"e1","type":"system","timestamp":"t","text":"ok \\ud83d\\ude0a"}
        """
        let repaired = JSONUnpairedSurrogateRepair.repairing(json.data(using: .utf8)!)
        let event = try JSONDecoder().decode(TraceEvent.self, from: repaired)
        #expect(event.text == "ok 😊")
    }

    @Test func leavesEscapedBackslashUnicodeTextAlone() throws {
        let json = """
        {"id":"e1","type":"system","timestamp":"t","text":"literal \\\\ud835"}
        """
        let repaired = JSONUnpairedSurrogateRepair.repairing(json.data(using: .utf8)!)
        let event = try JSONDecoder().decode(TraceEvent.self, from: repaired)
        #expect(event.text == "literal \\ud835")
    }

    @Test func replacesLoneLowSurrogate() throws {
        let json = """
        {"id":"e1","type":"system","timestamp":"t","text":"bad \\ude0a end"}
        """
        let repaired = JSONUnpairedSurrogateRepair.repairing(json.data(using: .utf8)!)
        let event = try JSONDecoder().decode(TraceEvent.self, from: repaired)
        #expect(event.text == "bad \u{FFFD} end")
    }

    @Test func returnsOriginalBytesWhenNothingNeedsRepair() {
        let data = #"{"id":"e1","type":"system","timestamp":"t","text":"plain"}"#.data(using: .utf8)!
        let repaired = JSONUnpairedSurrogateRepair.repairing(data)
        #expect(repaired == data)
    }

    private static let snippetJSON = """
    {"id":"e1","type":"system","timestamp":"t","text":"Artificial Analysis Intelligence Index v4.1.1 includes: GDPval-AA v2, \\ud835..."}
    """
}
