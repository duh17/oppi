import Foundation
import GhosttyVt
import Testing
@testable import Oppi

@Suite("SSH terminal engine dirty rows", .serialized)
@MainActor
struct SSHTerminalEngineRenderTests {
    @Test func aChangeToOneRowRebuildsOnlyThatRow() throws {
        let engine = try SSHTerminalEngine(geometry: .init(columns: 40, rows: 10)) { _ in }
        let line = String(repeating: "abcdefghij", count: 4)
        engine.receive(Data((Array(repeating: line, count: 10).joined(separator: "\r\n") + "\u{1b}[5;1H").utf8))
        let first = engine.frame()
        #expect(first.rebuiltRows == IndexSet(integersIn: 0..<10))
        #expect(engine.frame().rebuiltRows.isEmpty)

        engine.receive(Data("x".utf8))
        let after = engine.frame()
        #expect(after.rebuiltRows == IndexSet(integer: 4))
        #expect(after.rows[4][0].text == "x")
        #expect(after.rows[4][0].cluster == nil)
        #expect(after.rows[4][0].scalar == UInt32(Unicode.Scalar("x").value))
        #expect(after.rows[0][0].cluster == nil)
        #expect(after.rows[0][0].scalar == UInt32(Unicode.Scalar("a").value))
    }

    @Test func resizeAndScrollRebuildEverything() throws {
        let engine = try SSHTerminalEngine(geometry: .init(columns: 10, rows: 2)) { _ in }
        engine.receive(Data("one\r\ntwo\r\nthree\r\nfour".utf8))
        _ = engine.frame()
        engine.scroll(rows: -1)
        let scrolled = engine.frame()
        #expect(scrolled.rebuiltRows == IndexSet(integersIn: 0..<scrolled.rows.count))

        engine.resize(.init(columns: 10, rows: 3, cellWidth: 8, cellHeight: 17))
        let resized = engine.frame()
        #expect(resized.rows.count == 3)
        #expect(resized.rebuiltRows == IndexSet(integersIn: 0..<3))
    }

    @Test func combiningGraphemesAllocateAClusterPlainScalarsDoNot() throws {
        let engine = try SSHTerminalEngine(geometry: .init(columns: 10, rows: 1)) { _ in }
        engine.receive(Data("a中e\u{301}".utf8))
        let row = engine.frame().rows[0]
        #expect(row[0].cluster == nil)
        #expect(row[0].scalar == UInt32(Unicode.Scalar("a").value))
        #expect(row[1].text == "中")
        #expect(row[1].width == 2)
        #expect(row[3].text == "e\u{301}")
        #expect(row[3].cluster != nil)
    }
}
