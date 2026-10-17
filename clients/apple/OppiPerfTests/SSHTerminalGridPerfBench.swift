import Foundation
import Metal
import Testing
import UIKit
@testable import Oppi

/// Full-screen SSH terminal snapshot + Metal encode. Alternates two complete
/// grids so every iteration rebuilds every row (not the dirty-clean cache).
/// Also measures a dirty-one-row frame, idle display-link ticks, and color emoji.
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
        let cold = Self.once(engine: coldEngine, renderer: coldRenderer, texture: coldTexture, fullRebuild: true)

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
            screens: [Self.plainScreen(fill: "a"), Self.plainScreen(fill: "b")],
            fullRebuild: true
        )
        let styled = Self.measure(
            engine: engine, renderer: renderer, texture: texture,
            screens: [Self.styledScreen(seed: 0), Self.styledScreen(seed: 1)],
            fullRebuild: true
        )

        engine.receive(Data(Self.plainScreen(fill: "a").utf8))
        _ = renderer.encodeOffscreen(
            frame: engine.frame(), cursorColor: SIMD4(1, 1, 1, 0.65),
            texture: texture, waitUntilCompleted: true, fullRebuild: true
        )
        let dirtySamples = Self.measureDirtyRow(
            engine: engine, renderer: renderer, texture: texture
        )
        let emoji = Self.onceEmoji(engine: engine, renderer: renderer, texture: texture)
        let idle = try Self.measureIdleTicks()

        print("SSH_TERMINAL_AFTER method=metal_full_rebuild_48x40_scale2 warmup=2 iterations=7 alternate_two_screens configuration=Debug")
        print("SSH_TERMINAL_AFTER plain_frame_ms=\(Self.ms(plain.frameNs.median)) plain_encode_ms=\(Self.ms(plain.encodeNs.median)) plain_total_ms=\(Self.ms(plain.totalNs.median)) plain_encode_p95_ms=\(Self.ms(plain.encodeNs.p95))")
        print("SSH_TERMINAL_AFTER styled_frame_ms=\(Self.ms(styled.frameNs.median)) styled_encode_ms=\(Self.ms(styled.encodeNs.median)) styled_total_ms=\(Self.ms(styled.totalNs.median)) styled_encode_p95_ms=\(Self.ms(styled.encodeNs.p95))")
        print("SSH_TERMINAL_AFTER styled_cold_atlas_frame_ms=\(Self.ms(cold.frameNs)) styled_cold_atlas_encode_ms=\(Self.ms(cold.encodeNs)) styled_cold_atlas_total_ms=\(Self.ms(cold.totalNs))")
        print("SSH_TERMINAL_AFTER dirty_one_row_encode_ms=\(Self.ms(dirtySamples.encodeNs.median)) dirty_one_row_encode_p95_ms=\(Self.ms(dirtySamples.encodeNs.p95)) dirty_rebuilt_rows=\(dirtySamples.rebuilt) dirty_reused_rows=\(dirtySamples.reused)")
        print("SSH_TERMINAL_AFTER color_emoji_encode_ms=\(Self.ms(emoji.encodeNs)) color_emoji_completed=\(emoji.completed)")
        print("SSH_TERMINAL_AFTER idle_display_link_ticks_over_2s=\(idle.ticks) idle_display_link_running=\(idle.running)")
        print("METRIC ssh_terminal_plain_frame_us=\(String(format: "%.1f", Double(plain.frameNs.median) / 1_000))")
        print("METRIC ssh_terminal_plain_encode_us=\(String(format: "%.1f", Double(plain.encodeNs.median) / 1_000))")
        print("METRIC ssh_terminal_styled_frame_us=\(String(format: "%.1f", Double(styled.frameNs.median) / 1_000))")
        print("METRIC ssh_terminal_styled_encode_us=\(String(format: "%.1f", Double(styled.encodeNs.median) / 1_000))")
        print("METRIC ssh_terminal_styled_cold_encode_us=\(String(format: "%.1f", Double(cold.encodeNs) / 1_000))")
        print("METRIC ssh_terminal_dirty_one_row_encode_us=\(String(format: "%.1f", Double(dirtySamples.encodeNs.median) / 1_000))")
        print("METRIC ssh_terminal_color_emoji_encode_us=\(String(format: "%.1f", Double(emoji.encodeNs) / 1_000))")
        print("METRIC ssh_terminal_idle_display_link_ticks_2s=\(idle.ticks)")
        #expect(plain.encodeNs.median > 0)
        #expect(styled.encodeNs.median > 0)
        #expect(styled.completed, "worst-case styled screen presented in one frame")
        #expect(cold.completed, "cold-atlas styled screen presented in one frame")
        #expect(dirtySamples.encodeNs.median > 0)
        #expect(dirtySamples.reused >= Self.rows - 2, "dirty-one-row must reuse the rest of the grid")
        #expect(emoji.completed, "color-emoji cell presented in one frame")
        #expect(idle.ticks == 0, "idle display link must not tick for 2s after pause")
        #expect(!idle.running)
    }

    private struct Percentiles {
        var median: UInt64
        var p95: UInt64
    }

    private struct Sample {
        var frameNs: UInt64
        var encodeNs: UInt64
        var completed: Bool
        var rebuilt: Int = 0
        var reused: Int = 0
        var totalNs: UInt64 { frameNs + encodeNs }
    }

    private struct SampleSet {
        var frameNs: Percentiles
        var encodeNs: Percentiles
        var totalNs: Percentiles { Percentiles(median: frameNs.median + encodeNs.median, p95: frameNs.p95 + encodeNs.p95) }
        var completed: Bool
        var rebuilt: Int = 0
        var reused: Int = 0
    }

    private static func once(
        engine: SSHTerminalEngine,
        renderer: SSHTerminalMetalRenderer,
        texture: MTLTexture,
        fullRebuild: Bool
    ) -> Sample {
        let frameStart = DispatchTime.now().uptimeNanoseconds
        let frame = engine.frame()
        let frameNs = DispatchTime.now().uptimeNanoseconds &- frameStart
        let cost = renderer.encodeOffscreen(
            frame: frame, cursorColor: SIMD4(1, 1, 1, 0.65),
            texture: texture, waitUntilCompleted: true, fullRebuild: fullRebuild
        )
        return Sample(
            frameNs: frameNs, encodeNs: cost.encodeNanos, completed: cost.completed,
            rebuilt: cost.rebuiltRowCount, reused: cost.reusedRowCount
        )
    }

    private static func measure(
        engine: SSHTerminalEngine,
        renderer: SSHTerminalMetalRenderer,
        texture: MTLTexture,
        screens: [String],
        warmup: Int = 2,
        iterations: Int = 7,
        fullRebuild: Bool
    ) -> SampleSet {
        var frames: [UInt64] = []
        var encodes: [UInt64] = []
        var completed = false
        for i in 0..<(warmup + iterations) {
            engine.receive(Data(screens[i % screens.count].utf8))
            let sample = once(engine: engine, renderer: renderer, texture: texture, fullRebuild: fullRebuild)
            if i >= warmup {
                frames.append(sample.frameNs)
                encodes.append(sample.encodeNs)
                completed = completed || sample.completed
            }
        }
        return SampleSet(frameNs: percentiles(frames), encodeNs: percentiles(encodes), completed: completed)
    }

    private static func measureDirtyRow(
        engine: SSHTerminalEngine,
        renderer: SSHTerminalMetalRenderer,
        texture: MTLTexture,
        warmup: Int = 2,
        iterations: Int = 7
    ) -> SampleSet {
        var encodes: [UInt64] = []
        var rebuilt = 0
        var reused = 0
        var completed = false
        for i in 0..<(warmup + iterations) {
            let ch = i % 2 == 0 ? "x" : "y"
            engine.receive(Data("\u{1b}[H\(ch)".utf8))
            let sample = once(engine: engine, renderer: renderer, texture: texture, fullRebuild: false)
            if i >= warmup {
                encodes.append(sample.encodeNs)
                rebuilt = sample.rebuilt
                reused = sample.reused
                completed = completed || sample.completed
            }
        }
        return SampleSet(
            frameNs: Percentiles(median: 0, p95: 0),
            encodeNs: percentiles(encodes),
            completed: completed,
            rebuilt: rebuilt,
            reused: reused
        )
    }

    private static func onceEmoji(
        engine: SSHTerminalEngine,
        renderer: SSHTerminalMetalRenderer,
        texture: MTLTexture
    ) -> Sample {
        engine.receive(Data("\u{1b}[2J\u{1b}[H\u{1F600} \u{23FA}\r\n".utf8))
        return once(engine: engine, renderer: renderer, texture: texture, fullRebuild: true)
    }

    private static func measureIdleTicks() throws -> (ticks: UInt64, running: Bool) {
        let channel = try SSHTerminalChannel()
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        let host = UIViewController()
        grid.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: host.view.topAnchor),
            grid.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
        ])
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            channel.close(reason: "bench")
        }
        let settle = Date().addingTimeInterval(1.2)
        while Date() < settle, grid.isDisplayLinkRunning {
            RunLoop.current.run(until: Date().addingTimeInterval(0.016))
        }
        let start = grid.displayLinkTickCount
        let until = Date().addingTimeInterval(2)
        while Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return (grid.displayLinkTickCount &- start, grid.isDisplayLinkRunning)
    }

    private static func percentiles(_ values: [UInt64]) -> Percentiles {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return Percentiles(median: 0, p95: 0) }
        let median = sorted[sorted.count / 2]
        let p95Index = min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.95).rounded()))
        return Percentiles(median: median, p95: sorted[p95Index])
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
