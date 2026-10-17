import CoreText
import Foundation
import GhosttyVt
import Metal
import Testing
import UIKit
@testable import Oppi

@Suite("SSH terminal Metal pixels", .serialized)
@MainActor
struct SSHTerminalMetalTests {
    @Test func offscreenPixelsMatchCellBackgroundGlyphCursorAndAttributes() throws {
        let harness = try Harness(columns: 8, rows: 4)
        defer { harness.finish() }

        harness.engine.setColors(
            foreground: .init(r: 255, g: 255, b: 255),
            background: .init(r: 0, g: 0, b: 16),
            dark: true
        )
        harness.engine.receive(Data("\u{1b}[?25l\u{1b}[2J\u{1b}[H".utf8))
        var shot = try harness.render()
        shot.expectBackground(column: 0, row: 0, r: 0, g: 0, b: 16)

        harness.engine.receive(Data("\u{1b}[48;2;200;10;10m \u{1b}[0m".utf8))
        shot = try harness.render()
        shot.expectBackground(column: 0, row: 0, r: 200, g: 10, b: 10)

        harness.engine.receive(Data("\u{1b}[2J\u{1b}[H\u{1b}[38;2;255;255;255mX \u{1b}[0m".utf8))
        shot = try harness.render()
        #expect(shot.hasInk(column: 0, row: 0), "glyph ink inside its cell")
        #expect(!shot.hasInk(column: 1, row: 0), "no ink outside the glyph cell")

        harness.engine.receive(Data("\u{1b}[2J\u{1b}[H中x".utf8))
        shot = try harness.render()
        #expect(shot.hasInk(column: 0, row: 0) || shot.hasInk(column: 1, row: 0), "wide glyph spans two cells")
        #expect(shot.hasInk(column: 0, row: 0))
        #expect(shot.hasInk(column: 1, row: 0) || shot.backgroundDiffers(column: 1, row: 0, from: (0, 0, 16)))
        #expect(!shot.hasInk(column: 3, row: 0), "cell after the wide glyph + x stays empty")

        for (code, name) in [
            ("1", "block"), ("5", "bar"), ("3", "underline"),
        ] {
            harness.engine.receive(Data("\u{1b}[2J\u{1b}[H\u{1b}[?25h\u{1b}[\(code) q".utf8))
            shot = try harness.render()
            #expect(shot.hasInk(column: 0, row: 0), "cursor \(name) draws")
        }
        harness.engine.receive(Data("\u{1b}[?25l".utf8))

        harness.engine.receive(Data("\u{1b}[2J\u{1b}[H\u{1b}[4m \u{1b}[0m".utf8))
        shot = try harness.render()
        #expect(shot.hasInk(column: 0, row: 0), "underline draws on a blank cell")

        harness.engine.receive(Data("\u{1b}[2J\u{1b}[H\u{1b}[9mX\u{1b}[0m".utf8))
        shot = try harness.render()
        #expect(shot.hasInk(column: 0, row: 0), "strikethrough cell has ink")

        harness.engine.receive(Data("\u{1b}[2J\u{1b}[H\u{1b}[38;2;255;255;255mX\u{1b}[0m".utf8))
        let full = try harness.render()
        harness.engine.receive(Data("\u{1b}[2J\u{1b}[H\u{1b}[2;38;2;255;255;255mX\u{1b}[0m".utf8))
        let faint = try harness.render()
        #expect(faint.maxChannel(column: 0, row: 0) < full.maxChannel(column: 0, row: 0), "faint is lower alpha")

        harness.engine.receive(Data("\u{1b}[2J\u{1b}[H\u{1b}[8mX\u{1b}[0m".utf8))
        shot = try harness.render()
        #expect(!shot.hasInk(column: 0, row: 0), "invisible draws no ink")

        harness.engine.receive(Data("\u{1b}[2J\u{1b}[H\u{1b}[8;4m \u{1b}[0m".utf8))
        shot = try harness.render()
        #expect(!shot.hasInk(column: 0, row: 0), "invisible plus underline draws no ink")

        harness.engine.receive(Data("\u{1b}[2J\u{1b}[H\u{E0B0}".utf8))
        shot = try harness.render()
        #expect(shot.hasInk(column: 0, row: 0), "Nerd Font symbol has ink")
    }

    @Test func cursorOutlineBlendsOverAColouredCell() throws {
        let harness = try Harness(columns: 4, rows: 2)
        defer { harness.finish() }
        harness.engine.setColors(
            foreground: .init(r: 255, g: 255, b: 255),
            background: .init(r: 0, g: 0, b: 16),
            dark: true
        )
        harness.engine.receive(Data("\u{1b}[?25h\u{1b}[1 q\u{1b}[2J\u{1b}[H\u{1b}[48;2;200;10;10m \u{1b}[0m\u{1b}[H".utf8))
        let shot = try harness.render()
        let p = shot.pixel(column: 0, row: 0, dx: 0.5, dy: 0.05)
        // Source-over white 0.65 on rgb(200,10,10) is ~236,169,169, not raw white or raw red.
        #expect(Int(p.r) > 210 && Int(p.r) < 250, "cursor red \(p)")
        #expect(Int(p.g) > 80 && Int(p.g) < 220, "cursor green \(p)")
        #expect(!(p.r > 240 && p.g > 240 && p.b > 240), "cursor must not replace with raw white")
    }

    @Test func atlasOverflowResetsAndRepacksOrRefuses() throws {
        let metrics = SSHTerminalCellMetrics(
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            boldFont: .monospacedSystemFont(ofSize: 13, weight: .bold)
        )
        let cellW = Int(metrics.cellSize.width.rounded(.up))
        let cellH = Int(metrics.cellSize.height.rounded(.up))
        let pipeline = try SSHTerminalMetalPipeline.shared()

        let tight = try SSHTerminalMetalRenderer(
            pipeline: pipeline, metrics: metrics, scale: 1, atlasSide: cellW * 2
        )
        let engine = try SSHTerminalEngine(geometry: .init(columns: 4, rows: 1, cellWidth: 8, cellHeight: 17)) { _ in }
        engine.setColors(foreground: .init(r: 255, g: 255, b: 255), background: .init(r: 0, g: 0, b: 16), dark: true)
        engine.receive(Data("\u{1b}[?25l\u{1b}[2J\u{1b}[HAB".utf8))
        let first = try render(engine: engine, renderer: tight, metrics: metrics)
        #expect(first.shot.hasInk(column: 0, row: 0))
        #expect(first.shot.hasInk(column: 1, row: 0))

        engine.receive(Data("\u{1b}[2J\u{1b}[HCD".utf8))
        let second = try render(engine: engine, renderer: tight, metrics: metrics)
        #expect(second.cost.submitted, "reset mid-pack still presents the complete new frame")
        #expect(second.shot.hasInk(column: 0, row: 0), "first packed cell after reset")
        #expect(second.shot.hasInk(column: 1, row: 0), "last packed cell after reset")

        let tiny = try SSHTerminalMetalRenderer(
            pipeline: pipeline, metrics: metrics, scale: 1, atlasSide: max(1, min(cellW, cellH) / 2)
        )
        engine.receive(Data("\u{1b}[2J\u{1b}[HX".utf8))
        let frame = engine.frame()
        let width = max(1, Int(metrics.cellSize.width * 4))
        let height = max(1, Int(metrics.cellSize.height))
        let texture = try #require(tiny.makeOffscreenTexture(width: width, height: height))
        let refused = tiny.encodeOffscreen(
            frame: frame, cursorColor: SIMD4(1, 1, 1, 0.65), texture: texture, waitUntilCompleted: true
        )
        #expect(!refused.submitted, "a glyph larger than the atlas is not presented")
        #expect(refused.miss == .deterministic, "overflow is a deterministic miss, not a retry")
    }

    @Test func missedPackDoesNotCacheBlankGlyphsForALaterFrame() throws {
        let metrics = SSHTerminalCellMetrics(
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            boldFont: .monospacedSystemFont(ofSize: 13, weight: .bold)
        )
        let scale: CGFloat = 1
        let glyphW = max(1, Int(ceil(metrics.cellSize.width * scale)))
        let glyphH = max(1, Int(ceil(metrics.cellSize.height * scale)))
        func shelfFits(_ side: Int, count: Int) -> Bool {
            var x = 0, y = 0, rowHeight = 0
            for _ in 0..<count {
                if x + glyphW > side {
                    x = 0
                    y += rowHeight
                    rowHeight = 0
                }
                if y + glyphH > side { return false }
                x += glyphW
                rowHeight = max(rowHeight, glyphH)
            }
            return true
        }
        var atlasSide = max(glyphW, glyphH)
        while atlasSide < 8192 && !shelfFits(atlasSide, count: 2) {
            atlasSide += 1
        }
        #expect(shelfFits(atlasSide, count: 2) && !shelfFits(atlasSide, count: 3),
                "need an atlas that packs AB but not ABC")

        let pipeline = try SSHTerminalMetalPipeline.shared()
        let renderer = try SSHTerminalMetalRenderer(
            pipeline: pipeline, metrics: metrics, scale: scale, atlasSide: atlasSide
        )
        let engine = try SSHTerminalEngine(
            geometry: .init(columns: 3, rows: 1, cellWidth: 8, cellHeight: 17)
        ) { _ in }
        engine.setColors(
            foreground: .init(r: 255, g: 255, b: 255),
            background: .init(r: 0, g: 0, b: 16),
            dark: true
        )
        engine.receive(Data("\u{1b}[?25l\u{1b}[2J\u{1b}[HABC".utf8))
        let width = max(1, Int((metrics.cellSize.width * 3).rounded()))
        let height = max(1, Int(metrics.cellSize.height.rounded()))
        let textureA = try #require(renderer.makeOffscreenTexture(width: width, height: height))
        let costA = renderer.encodeOffscreen(
            frame: engine.frame(), cursorColor: SIMD4(1, 1, 1, 0.65),
            texture: textureA, waitUntilCompleted: true
        )
        #expect(!costA.submitted, "frame A cannot fit; packing must not submit")
        #expect(costA.miss == .deterministic, "a pack that cannot fit is deterministic")

        engine.receive(Data("\u{1b}[2J\u{1b}[HAB".utf8))
        let textureB = try #require(renderer.makeOffscreenTexture(width: width, height: height))
        let costB = renderer.encodeOffscreen(
            frame: engine.frame(), cursorColor: SIMD4(1, 1, 1, 0.65),
            texture: textureB, waitUntilCompleted: true
        )
        #expect(costB.submitted, "frame B fits and must submit")
        #expect(costB.completed)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            textureB.getBytes(
                base, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
            )
        }
        let shot = Shot(width: width, height: height, bytes: bytes, cell: metrics.cellSize)
        #expect(shot.hasInk(column: 0, row: 0), "reused A still has ink after a missed pack")
        #expect(shot.hasInk(column: 1, row: 0), "reused B still has ink after a missed pack")
    }

    @Test func coldFrameWithHundredsOfNewGlyphsStillPresentsInk() throws {
        let metrics = SSHTerminalCellMetrics(
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            boldFont: .monospacedSystemFont(ofSize: 13, weight: .bold)
        )
        let scale: CGFloat = 3
        let glyphH = max(1, Int(ceil(metrics.cellSize.height * scale)))
        #expect(400 * glyphH > 16384, "past the old one-glyph-per-row staging cap")
        let scalars = Self.uniqueCoveredScalars(font: metrics.font, count: 400)
        #expect(scalars.count == 400, "need 400 unique font-covered graphemes")

        let columns = 40
        let rows = 10
        let pipeline = try SSHTerminalMetalPipeline.shared()
        let renderer = try SSHTerminalMetalRenderer(pipeline: pipeline, metrics: metrics, scale: scale)
        let engine = try SSHTerminalEngine(
            geometry: .init(columns: columns, rows: rows, cellWidth: 8, cellHeight: 17)
        ) { _ in }
        engine.setColors(
            foreground: .init(r: 255, g: 255, b: 255),
            background: .init(r: 0, g: 0, b: 16),
            dark: true
        )
        let body = String(String.UnicodeScalarView(scalars))
        engine.receive(Data("\u{1b}[?25l\u{1b}[2J\u{1b}[H\(body)".utf8))
        let width = max(1, Int((metrics.cellSize.width * CGFloat(columns) * scale).rounded()))
        let height = max(1, Int((metrics.cellSize.height * CGFloat(rows) * scale).rounded()))
        let texture = try #require(renderer.makeOffscreenTexture(width: width, height: height))
        let cost = renderer.encodeOffscreen(
            frame: engine.frame(), cursorColor: SIMD4(1, 1, 1, 0.65),
            texture: texture, waitUntilCompleted: true
        )
        #expect(cost.submitted, "a cold screen that fits the atlas must not fail staging")
        #expect(cost.completed)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(
                base, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
            )
        }
        let cell = CGSize(
            width: metrics.cellSize.width * scale,
            height: metrics.cellSize.height * scale
        )
        let shot = Shot(width: width, height: height, bytes: bytes, cell: cell)
        #expect(shot.hasInk(column: 0, row: 0), "first unique cell has ink")
        #expect(shot.hasInk(column: 39, row: 9), "last unique cell has ink")
    }

    private func render(
        engine: SSHTerminalEngine,
        renderer: SSHTerminalMetalRenderer,
        metrics: SSHTerminalCellMetrics
    ) throws -> (shot: Shot, cost: SSHTerminalMetalFrameCost) {
        let frame = engine.frame()
        let width = max(1, Int((metrics.cellSize.width * CGFloat(max(1, frame.rows.first?.count ?? 1))).rounded()))
        let height = max(1, Int((metrics.cellSize.height * CGFloat(max(1, frame.rows.count))).rounded()))
        let texture = try #require(renderer.makeOffscreenTexture(width: width, height: height))
        let cost = renderer.encodeOffscreen(
            frame: frame, cursorColor: SIMD4(1, 1, 1, 0.65), texture: texture, waitUntilCompleted: true
        )
        guard cost.completed else { throw TestError.encodeFailed(cost.errorDescription) }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return (Shot(width: width, height: height, bytes: bytes, cell: metrics.cellSize), cost)
    }

    @Test func inFlightSlotIsNotRewrittenUntilCompletion() throws {
        let harness = try Harness(columns: 4, rows: 2)
        defer { harness.finish() }
        harness.engine.receive(Data("ab".utf8))
        let frame = harness.engine.frame()
        guard let texture = harness.renderer.makeOffscreenTexture(
            width: Int(harness.metrics.cellSize.width * 4),
            height: Int(harness.metrics.cellSize.height * 2)
        ) else {
            Issue.record("no offscreen texture")
            return
        }
        let before = harness.renderer.freeSlotCount
        let cost = harness.renderer.encodeOffscreen(
            frame: frame, cursorColor: SIMD4(1, 1, 1, 0.65), texture: texture, waitUntilCompleted: true
        )
        #expect(cost.submitted)
        #expect(cost.completed)
        #expect(harness.renderer.freeSlotCount == before)
        #expect(harness.renderer.inFlightCount == 0)
    }

    @MainActor
    private final class Harness {
        let engine: SSHTerminalEngine
        let metrics: SSHTerminalCellMetrics
        let renderer: SSHTerminalMetalRenderer
        let scale: CGFloat = 1

        init(columns: Int, rows: Int) throws {
            engine = try SSHTerminalEngine(geometry: .init(columns: columns, rows: rows, cellWidth: 8, cellHeight: 17)) { _ in }
            metrics = SSHTerminalCellMetrics(
                font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                boldFont: .monospacedSystemFont(ofSize: 13, weight: .bold)
            )
            let pipeline = try SSHTerminalMetalPipeline.shared()
            renderer = try SSHTerminalMetalRenderer(pipeline: pipeline, metrics: metrics, scale: 1)
        }

        func finish() {}

        func render() throws -> Shot {
            let frame = engine.frame()
            let width = max(1, Int((metrics.cellSize.width * CGFloat(max(1, frame.rows.first?.count ?? 1))).rounded()))
            let height = max(1, Int((metrics.cellSize.height * CGFloat(max(1, frame.rows.count))).rounded()))
            guard let texture = renderer.makeOffscreenTexture(width: width, height: height) else {
                throw TestError.noTexture
            }
            let cost = renderer.encodeOffscreen(
                frame: frame, cursorColor: SIMD4(1, 1, 1, 0.65), texture: texture, waitUntilCompleted: true
            )
            guard cost.completed else { throw TestError.encodeFailed(cost.errorDescription) }
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                texture.getBytes(base, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            return Shot(width: width, height: height, bytes: bytes, cell: metrics.cellSize)
        }
    }

    private static func uniqueCoveredScalars(font: UIFont, count: Int) -> [Unicode.Scalar] {
        let ctFont = font as CTFont
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(count)
        let ranges: [ClosedRange<UInt32>] = [
            0x21...0x7E,
            0xA1...0x24F,
            0x370...0x3FF,
            0x400...0x52F,
            0x1E00...0x1EFF,
        ]
        for range in ranges {
            for value in range {
                guard result.count < count, let scalar = Unicode.Scalar(value) else { continue }
                let character = Character(scalar)
                guard !character.isWhitespace, !character.isNewline else { continue }
                var units = Array(String(scalar).utf16)
                var glyphs = [CGGlyph](repeating: 0, count: units.count)
                guard CTFontGetGlyphsForCharacters(ctFont, &units, &glyphs, units.count) else { continue }
                result.append(scalar)
            }
            if result.count >= count { break }
        }
        return result
    }

    private enum TestError: Error {
        case noTexture
        case encodeFailed(String?)
    }

    private struct Shot {
        let width: Int
        let height: Int
        let bytes: [UInt8]
        let cell: CGSize

        func pixel(column: Int, row: Int, dx: CGFloat = 0.5, dy: CGFloat = 0.5) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
            let x = min(width - 1, max(0, Int(CGFloat(column) * cell.width + dx * cell.width)))
            let y = min(height - 1, max(0, Int(CGFloat(row) * cell.height + dy * cell.height)))
            let offset = (y * width + x) * 4
            return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
        }

        func expectBackground(column: Int, row: Int, r: UInt8, g: UInt8, b: UInt8, slack: Int = 12) {
            let p = pixel(column: column, row: row, dx: 0.15, dy: 0.15)
            #expect(abs(Int(p.r) - Int(r)) <= slack && abs(Int(p.g) - Int(g)) <= slack && abs(Int(p.b) - Int(b)) <= slack,
                    "bg \(p) vs \(r),\(g),\(b)")
        }

        func hasInk(column: Int, row: Int) -> Bool {
            let samples: [(CGFloat, CGFloat)] = [
                (0.5, 0.45), (0.4, 0.5), (0.6, 0.5), (0.5, 0.2), (0.5, 0.8),
                (0.15, 0.5), (0.05, 0.5), (0.5, 0.9), (0.5, 0.05), (0.5, 0.95),
            ]
            return samples.contains { dx, dy in
                let p = pixel(column: column, row: row, dx: dx, dy: dy)
                return Int(p.r) + Int(p.g) + Int(p.b) > 40
            }
        }

        func backgroundDiffers(column: Int, row: Int, from rgb: (UInt8, UInt8, UInt8)) -> Bool {
            let p = pixel(column: column, row: row, dx: 0.15, dy: 0.15)
            return abs(Int(p.r) - Int(rgb.0)) > 20 || abs(Int(p.g) - Int(rgb.1)) > 20 || abs(Int(p.b) - Int(rgb.2)) > 20
        }

        func maxChannel(column: Int, row: Int) -> Int {
            let p = pixel(column: column, row: row)
            return max(Int(p.r), Int(p.g), Int(p.b))
        }
    }
}
