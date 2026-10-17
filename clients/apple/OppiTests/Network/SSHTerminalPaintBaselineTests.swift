import Foundation
import GhosttyVt
import Metal
import Testing
import UIKit
@testable import Oppi

/// Main-thread encode cost on the 28c33e2b0 48×40 fixtures, after Metal cutover.
@Suite("SSH terminal paint baseline", .serialized)
@MainActor
struct SSHTerminalPaintBaselineTests {
    private static let columns = 48
    private static let rows = 40

    @Test func mainThreadTimePerFrameForPlainAndFullyStyledScreens() throws {
        let pipeline = try SSHTerminalMetalPipeline.shared()
        let metrics = SSHTerminalCellMetrics.codeFont()
        let renderer = try SSHTerminalMetalRenderer(pipeline: pipeline, metrics: metrics, scale: 2)
        let engine = try SSHTerminalEngine(
            geometry: .init(columns: Self.columns, rows: Self.rows, cellWidth: 8, cellHeight: 17)
        ) { _ in }
        let width = max(1, Int((metrics.cellSize.width * CGFloat(Self.columns) * 2).rounded()))
        let height = max(1, Int((metrics.cellSize.height * CGFloat(Self.rows) * 2).rounded()))
        guard let texture = renderer.makeOffscreenTexture(width: width, height: height) else {
            Issue.record("no offscreen texture")
            return
        }

        engine.receive(Data(Self.plainScreen.utf8))
        let plain = Self.measure(engine: engine, renderer: renderer, texture: texture)
        engine.receive(Data(Self.styledScreen.utf8))
        let styled = Self.measure(engine: engine, renderer: renderer, texture: texture)

        print("SSH_TERMINAL_AFTER method=metal_encode_48x40_scale2 warmup=2 iterations=7")
        print("SSH_TERMINAL_AFTER plain_frame_ms=\(Self.ms(plain.frameNs)) plain_encode_ms=\(Self.ms(plain.encodeNs)) plain_total_ms=\(Self.ms(plain.totalNs))")
        print("SSH_TERMINAL_AFTER styled_frame_ms=\(Self.ms(styled.frameNs)) styled_encode_ms=\(Self.ms(styled.encodeNs)) styled_total_ms=\(Self.ms(styled.totalNs))")
        #expect(plain.encodeNs > 0)
        #expect(styled.encodeNs > 0)
        #expect(styled.completed, "worst-case styled screen presented in one frame")
    }

    private struct Sample {
        var frameNs: UInt64
        var encodeNs: UInt64
        var completed: Bool
        var totalNs: UInt64 { frameNs + encodeNs }
    }

    private static func measure(
        engine: SSHTerminalEngine,
        renderer: SSHTerminalMetalRenderer,
        texture: MTLTexture,
        warmup: Int = 2,
        iterations: Int = 7
    ) -> Sample {
        var frames: [UInt64] = []
        var encodes: [UInt64] = []
        var completed = false
        for i in 0..<(warmup + iterations) {
            let frameStart = DispatchTime.now().uptimeNanoseconds
            let frame = engine.frame()
            let frameNs = DispatchTime.now().uptimeNanoseconds &- frameStart
            let cost = renderer.encodeOffscreen(
                frame: frame, cursorColor: SIMD4(1, 1, 1, 0.65),
                texture: texture, waitUntilCompleted: true
            )
            if i >= warmup {
                frames.append(frameNs)
                encodes.append(cost.encodeNanos)
                completed = completed || cost.completed
            }
        }
        frames.sort()
        encodes.sort()
        return Sample(frameNs: frames[frames.count / 2], encodeNs: encodes[encodes.count / 2], completed: completed)
    }

    private static func ms(_ ns: UInt64) -> String {
        String(format: "%.2f", Double(ns) / 1_000_000)
    }

    private static let plainScreen: String = {
        let line = String(repeating: "abcdefghij", count: 4) + "abcdefgh"
        return "\u{1b}[2J\u{1b}[H" + (0..<rows).map { _ in line }.joined(separator: "\r\n")
    }()

    private static let styledScreen: String = {
        var screen = "\u{1b}[2J\u{1b}[H"
        screen.reserveCapacity(columns * rows * 48)
        for y in 0..<rows {
            for x in 0..<columns {
                let r = (x * 5) % 256
                let g = (y * 6) % 256
                let b = ((x + 1) * (y + 1)) % 256
                screen += "\u{1b}[38;2;\(r);\(g);\(b)m\u{1b}[48;2;\(255 - r);\(255 - g);\(255 - b)m"
                if x % 2 == 0 { screen += "\u{1b}[1m" }
                if y % 2 == 0 { screen += "\u{1b}[3m" }
                if x % 3 == 0 { screen += "\u{1b}[4m" }
                if y % 3 == 0 { screen += "\u{1b}[9m" }
                screen += "X\u{1b}[0m"
            }
            if y + 1 < rows { screen += "\r\n" }
        }
        return screen
    }()
}
