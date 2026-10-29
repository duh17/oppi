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

    /// An erase with only a background set leaves cells that hold a color and
    /// no text or style (vim, tmux and htop status bars). They must paint
    /// that color, palette or truecolor, and keep the default foreground.
    @Test func backgroundOnlyErasedCellsKeepTheirColor() throws {
        let engine = try SSHTerminalEngine(geometry: .init(columns: 6, rows: 3)) { _ in }
        engine.setColors(
            foreground: .init(r: 200, g: 201, b: 202), background: .init(r: 10, g: 11, b: 12), dark: true,
            palette: [1: .init(r: 250, g: 1, b: 2)]
        )
        engine.receive(Data("\u{1b}[41m\u{1b}[K\u{1b}[0m\r\n\u{1b}[48;2;9;8;7m\u{1b}[K\u{1b}[0m\r\nplain".utf8))
        let rows = engine.frame().rows
        func rgb(_ color: GhosttyColorRgb) -> [UInt8] { [color.r, color.g, color.b] }
        for (y, expected) in [(0, [UInt8]([250, 1, 2])), (1, [9, 8, 7]), (2, [10, 11, 12])] {
            for (x, cell) in rows[y].enumerated() {
                #expect(rgb(cell.background) == expected, "row \(y) column \(x) background")
                #expect(rgb(cell.foreground) == [200, 201, 202], "row \(y) column \(x) foreground")
                #expect(cell.style == SSHTerminalCellStyle())
            }
        }
    }
}
