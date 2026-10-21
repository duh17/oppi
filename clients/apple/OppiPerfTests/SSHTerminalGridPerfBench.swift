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
        let history = try Self.measureHistoryScroll(renderer: renderer, texture: texture)
        let idle = try Self.measureIdleTicks()

        print("SSH_TERMINAL_AFTER method=metal_full_rebuild_48x40_scale2 warmup=2 iterations=7 alternate_two_screens configuration=Debug")
        print("SSH_TERMINAL_AFTER plain_frame_ms=\(Self.ms(plain.frameNs.median)) plain_encode_ms=\(Self.ms(plain.encodeNs.median)) plain_total_ms=\(Self.ms(plain.totalNs.median)) plain_encode_p95_ms=\(Self.ms(plain.encodeNs.p95))")
        print("SSH_TERMINAL_AFTER styled_frame_ms=\(Self.ms(styled.frameNs.median)) styled_encode_ms=\(Self.ms(styled.encodeNs.median)) styled_total_ms=\(Self.ms(styled.totalNs.median)) styled_encode_p95_ms=\(Self.ms(styled.encodeNs.p95))")
        print("SSH_TERMINAL_AFTER styled_cold_atlas_frame_ms=\(Self.ms(cold.frameNs)) styled_cold_atlas_encode_ms=\(Self.ms(cold.encodeNs)) styled_cold_atlas_total_ms=\(Self.ms(cold.totalNs))")
        print("SSH_TERMINAL_AFTER dirty_one_row_encode_ms=\(Self.ms(dirtySamples.encodeNs.median)) dirty_one_row_encode_p95_ms=\(Self.ms(dirtySamples.encodeNs.p95)) dirty_rebuilt_rows=\(dirtySamples.rebuilt) dirty_reused_rows=\(dirtySamples.reused)")
        print("SSH_TERMINAL_AFTER color_emoji_encode_ms=\(Self.ms(emoji.encodeNs)) color_emoji_completed=\(emoji.completed)")
        print("SSH_TERMINAL_AFTER history_subrow_shift_encode_ms=\(Self.ms(history.shift.encodeNs.median)) history_subrow_shift_encode_p95_ms=\(Self.ms(history.shift.encodeNs.p95)) history_subrow_shift_reused_rows=\(history.shift.reused)")
        print("SSH_TERMINAL_AFTER history_row_step_frame_ms=\(Self.ms(history.row.frameNs.median)) history_row_step_encode_ms=\(Self.ms(history.row.encodeNs.median)) history_row_step_total_ms=\(Self.ms(history.row.totalNs.median)) history_row_step_rows=\(history.row.rebuilt)")
        print("SSH_TERMINAL_AFTER idle_display_link_ticks_over_2s=\(idle.ticks) idle_display_link_running=\(idle.running)")
        print("METRIC ssh_terminal_plain_frame_us=\(String(format: "%.1f", Double(plain.frameNs.median) / 1_000))")
        print("METRIC ssh_terminal_plain_encode_us=\(String(format: "%.1f", Double(plain.encodeNs.median) / 1_000))")
        print("METRIC ssh_terminal_styled_frame_us=\(String(format: "%.1f", Double(styled.frameNs.median) / 1_000))")
        print("METRIC ssh_terminal_styled_encode_us=\(String(format: "%.1f", Double(styled.encodeNs.median) / 1_000))")
        print("METRIC ssh_terminal_styled_cold_encode_us=\(String(format: "%.1f", Double(cold.encodeNs) / 1_000))")
        print("METRIC ssh_terminal_dirty_one_row_encode_us=\(String(format: "%.1f", Double(dirtySamples.encodeNs.median) / 1_000))")
        print("METRIC ssh_terminal_color_emoji_encode_us=\(String(format: "%.1f", Double(emoji.encodeNs) / 1_000))")
        print("METRIC ssh_terminal_history_subrow_shift_encode_us=\(String(format: "%.1f", Double(history.shift.encodeNs.median) / 1_000))")
        print("METRIC ssh_terminal_history_row_step_total_us=\(String(format: "%.1f", Double(history.row.totalNs.median) / 1_000))")
        print("METRIC ssh_terminal_idle_display_link_ticks_2s=\(idle.ticks)")
        #expect(plain.encodeNs.median > 0)
        #expect(styled.encodeNs.median > 0)
        #expect(styled.completed, "worst-case styled screen presented in one frame")
        #expect(cold.completed, "cold-atlas styled screen presented in one frame")
        #expect(dirtySamples.encodeNs.median > 0)
        #expect(dirtySamples.reused >= Self.rows - 2, "dirty-one-row must reuse the rest of the grid")
        #expect(emoji.completed, "color-emoji cell presented in one frame")
        #expect(history.shift.completed && history.row.completed, "history scroll frames presented")
        #expect(history.shift.rebuilt == 0 && history.shift.reused > 0, "a sub-row shift reuses every row")
        #expect(idle.ticks == 0, "idle display link must not tick for 2s after pause")
        #expect(!idle.running)
    }

    /// Kitty graphics on screen: the steady state (no new pixels, same grid),
    /// a history scroll with the images pinned to their rows, and a sub-row
    /// shift. Uploads are counted so a frame that re-copies image pixels would
    /// show up here as a failure, not just as a slower number.
    @Test func kittyImagesOnScreen() throws {
        let pipeline = try SSHTerminalMetalPipeline.shared()
        let metrics = SSHTerminalCellMetrics.codeFont()
        let scale: CGFloat = 2
        let cellWidth = max(1, Int(metrics.cellSize.width * scale))
        let cellHeight = max(1, Int(metrics.cellSize.height * scale))
        let width = max(1, Int(metrics.cellSize.width * CGFloat(Self.columns) * scale))
        let height = max(1, Int(metrics.cellSize.height * CGFloat(Self.rows) * scale))
        let renderer = try SSHTerminalMetalRenderer(pipeline: pipeline, metrics: metrics, scale: scale)
        let engine = try SSHTerminalEngine(geometry: .init(
            columns: Self.columns, rows: Self.rows, cellWidth: cellWidth, cellHeight: cellHeight
        )) { _ in }
        guard let texture = renderer.makeOffscreenTexture(width: width, height: height) else {
            Issue.record("no offscreen texture")
            return
        }
        let line = String(repeating: "image ", count: Self.columns / 6)
        engine.receive(Data((0..<260).map { "\u{1b}[3\($0 % 7 + 1)m\(line)\u{1b}[0m" }.joined(separator: "\r\n").utf8))
        // Three 320x160 pictures, the shape of a listing preview or `kitten icat`.
        for i in 0..<3 {
            let pixels = (0..<(320 * 160)).map { _ in
                (UInt8((i * 60) % 256), UInt8(0x40), UInt8(0x80), UInt8(0xFF))
            }
            var bytes = [UInt8]()
            bytes.reserveCapacity(pixels.count * 4)
            for pixel in pixels { bytes += [pixel.0, pixel.1, pixel.2, pixel.3] }
            engine.receive(Data("\u{1b}[\(4 + i * 8);3H\u{1b}_Ga=T,f=32,s=320,v=160,i=\(i + 1),c=20,r=6;\(Data(bytes).base64EncodedString())\u{1b}\\".utf8))
        }
        _ = renderer.encodeOffscreen(
            frame: engine.frame(), cursorColor: SIMD4(1, 1, 1, 0.65),
            texture: texture, waitUntilCompleted: true, fullRebuild: true
        )
        let uploadsAfterWarmup = renderer.imageUploadCount

        var steadyFrames: [UInt64] = []
        var steadyEncodes: [UInt64] = []
        var placements = 0
        var steadyUploads = 0
        for _ in 0..<9 {
            let frameStart = DispatchTime.now().uptimeNanoseconds
            let frame = engine.frame()
            let cost = renderer.encodeOffscreen(
                frame: frame, cursorColor: SIMD4(1, 1, 1, 0.65),
                texture: texture, waitUntilCompleted: true, fullRebuild: false
            )
            steadyFrames.append(DispatchTime.now().uptimeNanoseconds &- frameStart &- cost.encodeNanos)
            steadyEncodes.append(cost.encodeNanos)
            placements = cost.imagePlacementCount
            steadyUploads += cost.imageUploadCount
            #expect(cost.completed)
        }
        #expect(placements == 3, "all three images draw")
        #expect(steadyUploads == 0, "a steady-state frame copies no image pixels")

        engine.scrollToRow(Int(engine.scrollbar.offset) - 20)
        _ = renderer.encodeOffscreen(
            frame: engine.frame(), cursorColor: SIMD4(1, 1, 1, 0.65),
            texture: texture, waitUntilCompleted: true, fullRebuild: true
        )
        var scrollFrames: [UInt64] = []
        var scrollEncodes: [UInt64] = []
        var scrollUploads = 0
        for i in 0..<9 {
            engine.scrollToRow(Int(engine.scrollbar.offset) - 1)
            let frameStart = DispatchTime.now().uptimeNanoseconds
            let frame = engine.frame()
            let cost = renderer.encodeOffscreen(
                frame: frame, cursorColor: SIMD4(1, 1, 1, 0.65),
                texture: texture, waitUntilCompleted: true, fullRebuild: false,
                shiftPixels: i % 12
            )
            scrollFrames.append(DispatchTime.now().uptimeNanoseconds &- frameStart &- cost.encodeNanos)
            scrollEncodes.append(cost.encodeNanos)
            scrollUploads += cost.imageUploadCount
            #expect(cost.completed)
        }
        #expect(scrollUploads == 0, "scrolling reuses the uploaded textures")

        print("SSH_TERMINAL_AFTER kitty_images=3 kitty_placement_cells=20x6 warmup=1 iterations=9 configuration=Debug")
        print("SSH_TERMINAL_AFTER kitty_steady_frame_ms=\(Self.ms(Self.percentiles(steadyFrames).median)) kitty_steady_encode_ms=\(Self.ms(Self.percentiles(steadyEncodes).median)) kitty_steady_encode_p95_ms=\(Self.ms(Self.percentiles(steadyEncodes).p95)) kitty_steady_placements=\(placements)")
        print("SSH_TERMINAL_AFTER kitty_scroll_frame_ms=\(Self.ms(Self.percentiles(scrollFrames).median)) kitty_scroll_encode_ms=\(Self.ms(Self.percentiles(scrollEncodes).median)) kitty_scroll_encode_p95_ms=\(Self.ms(Self.percentiles(scrollEncodes).p95)) kitty_uploads_total=\(renderer.imageUploadCount)")
        print("METRIC ssh_terminal_kitty_steady_frame_us=\(String(format: "%.1f", Double(Self.percentiles(steadyFrames).median) / 1_000))")
        print("METRIC ssh_terminal_kitty_steady_encode_us=\(String(format: "%.1f", Double(Self.percentiles(steadyEncodes).median) / 1_000))")
        print("METRIC ssh_terminal_kitty_scroll_frame_us=\(String(format: "%.1f", Double(Self.percentiles(scrollFrames).median) / 1_000))")
        print("METRIC ssh_terminal_kitty_scroll_encode_us=\(String(format: "%.1f", Double(Self.percentiles(scrollEncodes).median) / 1_000))")
        print("METRIC ssh_terminal_kitty_uploads_total=\(renderer.imageUploadCount)")
        print("METRIC ssh_terminal_kitty_uploads_after_warmup=\(renderer.imageUploadCount - uploadsAfterWarmup)")
        #expect(renderer.imageUploadCount - uploadsAfterWarmup == 0, "no image is uploaded twice")
    }

    /// Thousands of 1x1 pictures, the shape of a program that prints a mosaic or
    /// a listing of tiny previews. Packing used to be image x placement per layer
    /// (quadratic), so this scenario is the one that has to stay flat: one bounded
    /// set of draws, no texture per placement, and no re-upload in the steady state.
    @Test func manySmallKittyImages() throws {
        let pipeline = try SSHTerminalMetalPipeline.shared()
        let metrics = SSHTerminalCellMetrics.codeFont()
        let scale: CGFloat = 2
        let cellWidth = max(1, Int(metrics.cellSize.width * scale))
        let cellHeight = max(1, Int(metrics.cellSize.height * scale))
        let width = max(1, Int(metrics.cellSize.width * CGFloat(Self.columns) * scale))
        let height = max(1, Int(metrics.cellSize.height * CGFloat(Self.rows) * scale))
        let renderer = try SSHTerminalMetalRenderer(pipeline: pipeline, metrics: metrics, scale: scale)
        let engine = try SSHTerminalEngine(geometry: .init(
            columns: Self.columns, rows: Self.rows, cellWidth: cellWidth, cellHeight: cellHeight
        )) { _ in }
        guard let texture = renderer.makeOffscreenTexture(width: width, height: height) else {
            Issue.record("no offscreen texture")
            return
        }
        engine.receive(Data(Self.plainScreen(fill: ".").utf8))
        let white = Data([0xFF, 0xFF, 0xFF, 0xFF]).base64EncodedString()
        // Every picture is pinned to the top-left cell, so all 10,000 placements
        // are on screen and the packer has to bound them.
        for index in 0..<10_000 {
            engine.receive(Data(
                "\u{1b}[1;1H\u{1b}_Ga=T,f=32,s=1,v=1,i=\(index + 1),c=1,r=1;\(white)\u{1b}\\".utf8
            ))
        }
        _ = renderer.encodeOffscreen(
            frame: engine.frame(), cursorColor: SIMD4(1, 1, 1, 0.65),
            texture: texture, waitUntilCompleted: true, fullRebuild: true
        )
        let uploadsAfterWarmup = renderer.imageUploadCount

        var frames: [UInt64] = []
        var encodes: [UInt64] = []
        var placements = 0
        var uploads = 0
        for _ in 0..<9 {
            let frameStart = DispatchTime.now().uptimeNanoseconds
            let frame = engine.frame()
            let cost = renderer.encodeOffscreen(
                frame: frame, cursorColor: SIMD4(1, 1, 1, 0.65),
                texture: texture, waitUntilCompleted: true, fullRebuild: false
            )
            frames.append(DispatchTime.now().uptimeNanoseconds &- frameStart &- cost.encodeNanos)
            encodes.append(cost.encodeNanos)
            placements = cost.imagePlacementCount
            uploads += cost.imageUploadCount
            #expect(cost.completed)
        }
        let stored = engine.frame().kitty?.images.count ?? 0
        print("SSH_TERMINAL_AFTER kitty_many_images=10000 kitty_many_image_size=1x1 warmup=1 iterations=9 configuration=Debug")
        print("SSH_TERMINAL_AFTER kitty_many_frame_ms=\(Self.ms(Self.percentiles(frames).median)) kitty_many_encode_ms=\(Self.ms(Self.percentiles(encodes).median)) kitty_many_encode_p95_ms=\(Self.ms(Self.percentiles(encodes).p95)) kitty_many_drawn_placements=\(placements) kitty_many_cached_images=\(renderer.cachedImageCount)")
        print("METRIC ssh_terminal_kitty_many_images_frame_us=\(String(format: "%.1f", Double(Self.percentiles(frames).median) / 1_000))")
        print("METRIC ssh_terminal_kitty_many_images_encode_us=\(String(format: "%.1f", Double(Self.percentiles(encodes).median) / 1_000))")
        print("METRIC ssh_terminal_kitty_many_images_drawn_placements=\(placements)")
        print("METRIC ssh_terminal_kitty_many_images_cached=\(renderer.cachedImageCount)")
        print("METRIC ssh_terminal_kitty_many_images_stored=\(stored)")
        print("METRIC ssh_terminal_kitty_many_images_cached_bytes=\(renderer.cachedImageBytes)")
        #expect(stored == 10_000, "every picture the host sent is stored")
        #expect(placements > 0 && placements <= SSHTerminalMetalRenderer.maxKittyPlacementsPerFrame)
        #expect(renderer.cachedImageCount <= SSHTerminalMetalRenderer.maxKittyImagesPerFrame)
        #expect(renderer.cachedImageBytes <= SSHTerminalKittyTextureCache.limitBytes)
        #expect(renderer.cachedImageBytes > 0, "the budget counts real texture bytes")
        #expect(uploads == 0, "a steady-state frame copies no image pixels")
        #expect(uploadsAfterWarmup > 0, "the warmup frame uploaded the bounded set")
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

    /// A history drag: frames that only move the grid within a row, and
    /// frames that step the viewport one row (plus the two overscan rows).
    private static func measureHistoryScroll(
        renderer: SSHTerminalMetalRenderer, texture: MTLTexture, warmup: Int = 2, iterations: Int = 7
    ) throws -> (shift: SampleSet, row: SampleSet) {
        let engine = try SSHTerminalEngine(
            geometry: .init(columns: columns, rows: rows, cellWidth: 8, cellHeight: 17)
        ) { _ in }
        let line = String(repeating: "history ", count: columns / 8)
        engine.receive(Data((0..<400).map { "\u{1b}[3\($0 % 7 + 1)m\(line)\u{1b}[0m" }.joined(separator: "\r\n").utf8))
        var row = 200
        engine.scrollToRow(row)
        _ = once(engine: engine, renderer: renderer, texture: texture, fullRebuild: true)
        var shiftEncodes: [UInt64] = []
        var shiftReused = 0
        var shiftRebuilt = 0
        var shiftCompleted = false
        for i in 0..<(warmup + iterations) {
            let cost = renderer.encodeOffscreen(
                frame: engine.frame(), cursorColor: SIMD4(1, 1, 1, 0.65), texture: texture,
                waitUntilCompleted: true, fullRebuild: false, shiftPixels: 1 + i % 30
            )
            if i >= warmup {
                shiftEncodes.append(cost.encodeNanos)
                shiftReused = cost.reusedRowCount
                shiftRebuilt = max(shiftRebuilt, cost.rebuiltRowCount)
                shiftCompleted = shiftCompleted || cost.completed
            }
        }
        var rowFrames: [UInt64] = []
        var rowEncodes: [UInt64] = []
        var rowRebuilt = 0
        var rowCompleted = false
        for i in 0..<(warmup + iterations) {
            row -= 1
            engine.scrollToRow(row)
            let sample = once(engine: engine, renderer: renderer, texture: texture, fullRebuild: false)
            if i >= warmup {
                rowFrames.append(sample.frameNs)
                rowEncodes.append(sample.encodeNs)
                rowRebuilt = sample.rebuilt
                rowCompleted = rowCompleted || sample.completed
            }
        }
        return (
            SampleSet(
                frameNs: Percentiles(median: 0, p95: 0), encodeNs: percentiles(shiftEncodes),
                completed: shiftCompleted, rebuilt: shiftRebuilt, reused: shiftReused
            ),
            SampleSet(
                frameNs: percentiles(rowFrames), encodeNs: percentiles(rowEncodes),
                completed: rowCompleted, rebuilt: rowRebuilt
            )
        )
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
