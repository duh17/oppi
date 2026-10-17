import Foundation
import Metal
import Testing
import UIKit
@testable import Oppi

/// Full-screen SSH terminal snapshot + Metal encode. Alternates two complete
/// grids so every iteration rebuilds every row (not the dirty-clean cache).
///
/// Output: SSH_TERMINAL_AFTER lines and METRIC microseconds.
@Suite("SSHTerminalGridPerfBench", .tags(.perf))
@MainActor
struct SSHTerminalGridPerfBench {
    private static let columns = 48
    private static let rows = 40

    @Test func fullScreenChangeFrameAndEncode() throws {
        let pipeline = try SSHTerminalMetalPipeline.shared()
        let metrics = SSHTerminalCellMetrics.codeFont()
        let width = max(1, Int((metrics.cellSize.width * CGFloat(Self.columns) * 2).rounded()))
        let height = max(1, Int((metrics.cellSize.height * CGFloat(Self.rows) * 2).rounded()))

        let coldRenderer = try SSHTerminalMetalRenderer(pipeline: pipeline, metrics: metrics, scale: 2)
        let coldEngine = try SSHTerminalEngine(
            geometry: .init(columns: Self.columns, rows: Self.rows, cellWidth: 8, cellHeight: 17)
        ) { _ in }
        guard let coldTexture = coldRenderer.makeOffscreenTexture(width: width, height: height) else {
            Issue.record("no offscreen texture")
            return
        }
        coldEngine.receive(Data(Self.styledScreen(seed: 0).utf8))
        let cold = Self.once(engine: coldEngine, renderer: coldRenderer, texture: coldTexture)

        let renderer = try SSHTerminalMetalRenderer(pipeline: pipeline, metrics: metrics, scale: 2)
        let engine = try SSHTerminalEngine(
            geometry: .init(columns: Self.columns, rows: Self.rows, cellWidth: 8, cellHeight: 17)
        ) { _ in }
        guard let texture = renderer.makeOffscreenTexture(width: width, height: height) else {
            Issue.record("no offscreen texture")
            return
        }

        let plain = Self.measure(
            engine: engine, renderer: renderer, texture: texture,
            screens: [Self.plainScreen(fill: "a"), Self.plainScreen(fill: "b")]
        )
        let styled = Self.measure(
            engine: engine, renderer: renderer, texture: texture,
            screens: [Self.styledScreen(seed: 0), Self.styledScreen(seed: 1)]
        )

        print("SSH_TERMINAL_AFTER method=metal_full_rebuild_48x40_scale2 warmup=2 iterations=7 alternate_two_screens")
        print("SSH_TERMINAL_AFTER plain_frame_ms=\(Self.ms(plain.frameNs)) plain_encode_ms=\(Self.ms(plain.encodeNs)) plain_total_ms=\(Self.ms(plain.totalNs))")
        print("SSH_TERMINAL_AFTER styled_frame_ms=\(Self.ms(styled.frameNs)) styled_encode_ms=\(Self.ms(styled.encodeNs)) styled_total_ms=\(Self.ms(styled.totalNs))")
        print("SSH_TERMINAL_AFTER styled_cold_atlas_frame_ms=\(Self.ms(cold.frameNs)) styled_cold_atlas_encode_ms=\(Self.ms(cold.encodeNs)) styled_cold_atlas_total_ms=\(Self.ms(cold.totalNs))")
        print("METRIC ssh_terminal_plain_frame_us=\(String(format: "%.1f", Double(plain.frameNs) / 1_000))")
        print("METRIC ssh_terminal_plain_encode_us=\(String(format: "%.1f", Double(plain.encodeNs) / 1_000))")
        print("METRIC ssh_terminal_styled_frame_us=\(String(format: "%.1f", Double(styled.frameNs) / 1_000))")
        print("METRIC ssh_terminal_styled_encode_us=\(String(format: "%.1f", Double(styled.encodeNs) / 1_000))")
        print("METRIC ssh_terminal_styled_cold_encode_us=\(String(format: "%.1f", Double(cold.encodeNs) / 1_000))")
        #expect(plain.encodeNs > 0)
        #expect(styled.encodeNs > 0)
        #expect(styled.completed, "worst-case styled screen presented in one frame")
        #expect(cold.completed, "cold-atlas styled screen presented in one frame")
    }

    private struct Sample {
        var frameNs: UInt64
        var encodeNs: UInt64
        var completed: Bool
        var totalNs: UInt64 { frameNs + encodeNs }
    }

    private static func once(
        engine: SSHTerminalEngine,
        renderer: SSHTerminalMetalRenderer,
        texture: MTLTexture
    ) -> Sample {
        let frameStart = DispatchTime.now().uptimeNanoseconds
        let frame = engine.frame()
        let frameNs = DispatchTime.now().uptimeNanoseconds &- frameStart
        let cost = renderer.encodeOffscreen(
            frame: frame, cursorColor: SIMD4(1, 1, 1, 0.65),
            texture: texture, waitUntilCompleted: true
        )
        return Sample(frameNs: frameNs, encodeNs: cost.encodeNanos, completed: cost.completed)
    }

    private static func measure(
        engine: SSHTerminalEngine,
        renderer: SSHTerminalMetalRenderer,
        texture: MTLTexture,
        screens: [String],
        warmup: Int = 2,
        iterations: Int = 7
    ) -> Sample {
        var frames: [UInt64] = []
        var encodes: [UInt64] = []
        var completed = false
        for i in 0..<(warmup + iterations) {
            engine.receive(Data(screens[i % screens.count].utf8))
            let sample = once(engine: engine, renderer: renderer, texture: texture)
            if i >= warmup {
                frames.append(sample.frameNs)
                encodes.append(sample.encodeNs)
                completed = completed || sample.completed
            }
        }
        frames.sort()
        encodes.sort()
        return Sample(frameNs: frames[frames.count / 2], encodeNs: encodes[encodes.count / 2], completed: completed)
    }

    private static func ms(_ ns: UInt64) -> String {
        String(format: "%.2f", Double(ns) / 1_000_000)
    }

    private static func plainScreen(fill: Character) -> String {
        let line = String(repeating: fill, count: columns)
        return "\u{1b}[2J\u{1b}[H" + (0..<rows).map { _ in line }.joined(separator: "\r\n")
    }

    private static func styledScreen(seed: Int) -> String {
        var screen = "\u{1b}[2J\u{1b}[H"
        screen.reserveCapacity(columns * rows * 48)
        for y in 0..<rows {
            for x in 0..<columns {
                let r = (x * 5 + seed * 17) % 256
                let g = (y * 6 + seed * 13) % 256
                let b = ((x + 1) * (y + 1) + seed) % 256
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
    }
}
