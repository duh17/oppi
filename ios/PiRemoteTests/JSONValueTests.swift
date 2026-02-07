import Testing
import Foundation
@testable import PiRemote

@Suite("JSONValue")
struct JSONValueTests {

    @Test func decodesNestedJSON() throws {
        let json = """
        {"name":"test","count":42,"nested":{"flag":true,"items":[1,2,3]},"empty":null}
        """
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: data)

        guard case .object(let obj) = value else {
            Issue.record("Expected object")
            return
        }

        #expect(obj["name"] == .string("test"))
        #expect(obj["count"] == .number(42))
        #expect(obj["empty"] == .null)

        guard case .object(let nested) = obj["nested"] else {
            Issue.record("Expected nested object")
            return
        }
        #expect(nested["flag"] == .bool(true))

        guard case .array(let items) = nested["items"] else {
            Issue.record("Expected array")
            return
        }
        #expect(items.count == 3)
    }

    @Test func roundTrips() throws {
        let original: JSONValue = [
            "key": "value",
            "num": 3.14,
            "list": [1, 2, 3],
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == original)
    }

    @Test func summaryTruncation() {
        let long = JSONValue.string(String(repeating: "x", count: 200))
        let summary = long.summary(maxLength: 80)
        #expect(summary.count == 80)
        #expect(summary.hasSuffix("…"))
    }

    @Test func summaryForCollections() {
        let arr: JSONValue = [1, 2, 3]
        #expect(arr.summary() == "[3 items]")

        let obj: JSONValue = ["a": 1, "b": 2]
        #expect(obj.summary() == "{2 keys}")
    }

    @Test func literals() {
        let s: JSONValue = "hello"
        #expect(s == .string("hello"))

        let n: JSONValue = 42
        #expect(n == .number(42))

        let b: JSONValue = true
        #expect(b == .bool(true))

        let null: JSONValue = nil
        #expect(null == .null)
    }
}
