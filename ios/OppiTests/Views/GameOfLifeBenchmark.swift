import CoreFoundation
import Testing

@testable import Oppi

/// Benchmark suite for Game of Life optimization.
/// Outputs METRIC lines parsed by autoresearch.sh.
@Suite("GameOfLifeBenchmark")
struct GameOfLifeBenchmark {

    // MARK: - Primary: tick performance

    @Test("benchmark tick 6x6")
    func benchmarkTick6x6() {
        let layer = GameOfLifeLayer(gridSize: 6)
        let iterations = 50_000
        let warmup = 1_000

        // Warmup
        for _ in 0..<warmup { layer.tick() }

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            layer.tick()
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let perTickUs = (elapsed / Double(iterations)) * 1_000_000

        print("METRIC tick_us=\(String(format: "%.3f", perTickUs))")
        #expect(perTickUs < 100, "tick too slow: \(perTickUs)us")
    }

    // MARK: - Secondary: draw performance

    @Test("benchmark draw 6x6")
    func benchmarkDraw6x6() {
        let layer = GameOfLifeLayer(gridSize: 6)
        layer.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        layer.contentsScale = 3.0

        let iterations = 10_000
        let warmup = 500

        // Warmup
        for _ in 0..<warmup {
            layer.tick()
            layer.setNeedsDisplay()
            layer.displayIfNeeded()
        }

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            layer.tick()
            layer.setNeedsDisplay()
            layer.displayIfNeeded()
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let perFrameUs = (elapsed / Double(iterations)) * 1_000_000

        print("METRIC frame_us=\(String(format: "%.3f", perFrameUs))")
        #expect(perFrameUs < 500, "frame too slow: \(perFrameUs)us")
    }

    // MARK: - Secondary: combined battery proxy

    @Test("benchmark battery proxy")
    func benchmarkBatteryProxy() {
        // Simulate 1 second of animation at 8 FPS = 8 frames.
        // Measure total CPU time for 8 tick+draw cycles.
        // Lower = less battery drain per second of animation.
        let layer = GameOfLifeLayer(gridSize: 6)
        layer.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        layer.contentsScale = 3.0

        let framesPerSecond = 8
        let secondsToSimulate = 100
        let totalFrames = framesPerSecond * secondsToSimulate

        // Warmup
        for _ in 0..<100 {
            layer.tick()
            layer.setNeedsDisplay()
            layer.displayIfNeeded()
        }

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<totalFrames {
            layer.tick()
            layer.setNeedsDisplay()
            layer.displayIfNeeded()
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // CPU milliseconds per second of animation
        let cpuMsPerSec = (elapsed / Double(secondsToSimulate)) * 1000

        print("METRIC battery_ms_per_sec=\(String(format: "%.3f", cpuMsPerSec))")
        #expect(cpuMsPerSec < 50, "battery cost too high: \(cpuMsPerSec)ms/s")
    }

    // MARK: - Secondary: hash/reseed overhead

    @Test("benchmark hash overhead")
    func benchmarkHashOverhead() {
        let layer = GameOfLifeLayer(gridSize: 6)
        let iterations = 50_000

        // Full tick (includes hash)
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            layer.tick()
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let tickNs = (elapsed / Double(iterations)) * 1_000_000_000

        print("METRIC tick_ns=\(String(format: "%.1f", tickNs))")
        #expect(tickNs < 100_000, "tick too slow in ns")
    }
}
