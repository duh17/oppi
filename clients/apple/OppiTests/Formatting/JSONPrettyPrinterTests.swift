import Foundation
import Testing
@testable import Oppi

@Suite("JSONPrettyPrinter")
struct JSONPrettyPrinterTests {
    @Test func prettyPrintsObjectWithSortedKeysAndIndentation() throws {
        let source = #"{"ok":true,"data":{"timed_out":true}}"#
        let pretty = try #require(JSONPrettyPrinter.prettyPrinted(source))

        #expect(pretty != source)
        #expect(pretty.contains("\n"))
        #expect(pretty.contains("  "))
        let dataKey = try #require(pretty.range(of: "\"data\""))
        let okKey = try #require(pretty.range(of: "\"ok\""))
        #expect(dataKey.lowerBound < okKey.lowerBound)
        #expect(pretty.contains("\"timed_out\""))
    }

    @Test func prettyPrintsArray() throws {
        let source = #"[1,{"z":1,"a":2}]"#
        let pretty = try #require(JSONPrettyPrinter.prettyPrinted(source))

        #expect(pretty.contains("\n"))
        let aKey = try #require(pretty.range(of: "\"a\""))
        let zKey = try #require(pretty.range(of: "\"z\""))
        #expect(aKey.lowerBound < zKey.lowerBound)
    }

    @Test func returnsNilForInvalidJSON() {
        #expect(JSONPrettyPrinter.prettyPrinted(#"{"ok": true,"#) == nil)
        #expect(JSONPrettyPrinter.prettyPrinted("") == nil)
        #expect(JSONPrettyPrinter.prettyPrinted("not json") == nil)
    }

    @Test func returnsNilForJSONPrimitives() {
        #expect(JSONPrettyPrinter.prettyPrinted("true") == nil)
        #expect(JSONPrettyPrinter.prettyPrinted("null") == nil)
        #expect(JSONPrettyPrinter.prettyPrinted("42") == nil)
        #expect(JSONPrettyPrinter.prettyPrinted(#""hello""#) == nil)
    }

    @Test func returnsNilWhenOverUtf8Budget() {
        let padding = String(repeating: "x", count: JSONPrettyPrinter.utf8Budget)
        let source = "{\"k\":\"\(padding)\"}"
        #expect(source.utf8.count > JSONPrettyPrinter.utf8Budget)
        #expect(JSONPrettyPrinter.prettyPrinted(source) == nil)
    }

    @Test func prettyPrintsWhenUnderUtf8Budget() throws {
        let source = #"{"z":1,"a":2}"#
        #expect(source.utf8.count < JSONPrettyPrinter.utf8Budget)
        let pretty = try #require(JSONPrettyPrinter.prettyPrinted(source))
        #expect(pretty.contains("\n"))
        let aKey = try #require(pretty.range(of: "\"a\""))
        let zKey = try #require(pretty.range(of: "\"z\""))
        #expect(aKey.lowerBound < zKey.lowerBound)
    }
}
