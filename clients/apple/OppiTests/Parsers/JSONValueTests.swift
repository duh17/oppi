import Testing
import Foundation
@testable import Oppi

@Suite("JSONValue")
struct JSONValueTests {

    @Test func decodesNestedJSON() throws {
        let json = """
        {"name":"test","count":42,"nested":{"flag":true,"items":[1,2,3]},"empty":null}
        """
        let data = Data(json.utf8)
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

    // MARK: - Convenience accessors

    @Test func stringValue() {
        #expect(JSONValue.string("hi").stringValue == "hi")
        #expect(JSONValue.number(42).stringValue == nil)
        #expect(JSONValue.null.stringValue == nil)
    }

    @Test func numberValue() {
        #expect(JSONValue.number(3.14).numberValue == 3.14)
        #expect(JSONValue.string("x").numberValue == nil)
        #expect(JSONValue.null.numberValue == nil)
    }

    @Test func boolValue() {
        #expect(JSONValue.bool(true).boolValue == true)
        #expect(JSONValue.bool(false).boolValue == false)
        #expect(JSONValue.string("x").boolValue == nil)
        #expect(JSONValue.null.boolValue == nil)
    }

    // MARK: - Summary for all types

    @Test func summaryString() {
        #expect(JSONValue.string("hello").summary() == "hello")
    }

    @Test func summaryIntegerNumber() {
        // Whole numbers display without decimal
        #expect(JSONValue.number(42).summary() == "42")
    }

    @Test func summaryFractionalNumber() {
        #expect(JSONValue.number(3.14).summary() == "3.14")
    }

    @Test func summaryBool() {
        #expect(JSONValue.bool(true).summary() == "true")
        #expect(JSONValue.bool(false).summary() == "false")
    }

    @Test func summaryNull() {
        #expect(JSONValue.null.summary() == "null")
    }

    @Test func summaryShortStringNoTruncation() {
        let short = JSONValue.string("abc")
        #expect(short.summary(maxLength: 80) == "abc")
    }

    // MARK: - Encode/decode round-trips for all types

    @Test func encodeDecodeNull() throws {
        let data = try JSONEncoder().encode(JSONValue.null)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == .null)
    }

    @Test func encodeDecodeBool() throws {
        let data = try JSONEncoder().encode(JSONValue.bool(false))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == .bool(false))
    }

    @Test func encodeDecodeArray() throws {
        let arr: JSONValue = .array([.string("a"), .number(1), .null])
        let data = try JSONEncoder().encode(arr)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == arr)
    }

    @Test func encodeDecodeNestedObject() throws {
        let obj: JSONValue = .object(["inner": .object(["deep": .bool(true)])])
        let data = try JSONEncoder().encode(obj)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == obj)
    }

    // MARK: - Literal conformances

    @Test func floatLiteral() {
        let f: JSONValue = 2.718
        #expect(f == .number(2.718))
    }

    @Test func arrayLiteral() {
        let a: JSONValue = ["x", 1, true]
        guard case .array(let items) = a else {
            Issue.record("Expected array")
            return
        }
        #expect(items.count == 3)
    }

    @Test func dictionaryLiteral() {
        let d: JSONValue = ["key": "val"]
        guard case .object(let obj) = d else {
            Issue.record("Expected object")
            return
        }
        #expect(obj["key"] == .string("val"))
    }
}
