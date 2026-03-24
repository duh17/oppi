import CoreFoundation
import Testing
@testable import Oppi

@Suite("Word span performance")
struct WordSpanPerfTests {

    // MARK: - Micro-benchmarks

    @Test func measureSmallEdit() {
        // Typical edit: change one variable name
        let old = "let value = oldName"
        let new = "let value = newName"
        let lines = DiffEngine.compute(old: old, new: new)

        let iterations = 1000
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines, withWordSpans: true)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let perCall = (elapsed / Double(iterations)) * 1_000_000 // microseconds

        print("[perf] Small edit (1 line pair): \(String(format: "%.1f", perCall))us per call (\(iterations) iterations)")
        #expect(perCall < 1000, "Small edit should be under 1ms")
    }

    @Test func measureMediumEdit() {
        // Medium edit: 10 changed lines
        var oldLines: [String] = []
        var newLines: [String] = []
        for i in 0..<30 {
            if i >= 10 && i < 20 {
                oldLines.append("    let value\(i) = oldFunction(\(i))")
                newLines.append("    let value\(i) = newFunction(\(i), extra: true)")
            } else {
                let shared = "    let shared\(i) = context(\(i))"
                oldLines.append(shared)
                newLines.append(shared)
            }
        }
        let lines = DiffEngine.compute(old: oldLines.joined(separator: "\n"), new: newLines.joined(separator: "\n"))

        let iterations = 100
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines, withWordSpans: true)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let perCall = (elapsed / Double(iterations)) * 1_000_000

        print("[perf] Medium edit (10 line pairs, 30 total): \(String(format: "%.1f", perCall))us per call (\(iterations) iterations)")
        #expect(perCall < 5000, "Medium edit should be under 5ms")
    }

    @Test func measureLargeEdit() {
        // Large edit: 50 changed lines out of 100
        var oldLines: [String] = []
        var newLines: [String] = []
        for i in 0..<100 {
            if i % 2 == 0 {
                oldLines.append("    func method\(i)(param: OldType\(i)) -> OldReturn\(i) {")
                newLines.append("    func method\(i)(param: NewType\(i), extra: Bool) -> NewReturn\(i) {")
            } else {
                let shared = "        // line \(i) unchanged"
                oldLines.append(shared)
                newLines.append(shared)
            }
        }
        let lines = DiffEngine.compute(old: oldLines.joined(separator: "\n"), new: newLines.joined(separator: "\n"))

        let iterations = 20
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines, withWordSpans: true)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let perCall = (elapsed / Double(iterations)) * 1_000_000

        print("[perf] Large edit (50 line pairs, 100 total): \(String(format: "%.1f", perCall))us per call (\(iterations) iterations)")
        #expect(perCall < 20000, "Large edit should be under 20ms")
    }

    @Test func measureWordSpansVsNoWordSpans() {
        // Compare with vs without word spans to isolate the cost
        var oldLines: [String] = []
        var newLines: [String] = []
        for i in 0..<30 {
            if i >= 10 && i < 20 {
                oldLines.append("    let value\(i) = oldFunction(\(i))")
                newLines.append("    let value\(i) = newFunction(\(i), extra: true)")
            } else {
                let shared = "    let shared\(i) = context(\(i))"
                oldLines.append(shared)
                newLines.append(shared)
            }
        }
        let lines = DiffEngine.compute(old: oldLines.joined(separator: "\n"), new: newLines.joined(separator: "\n"))

        let iterations = 200

        // Without word spans
        let startNoSpans = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines, withWordSpans: false)
        }
        let elapsedNoSpans = CFAbsoluteTimeGetCurrent() - startNoSpans
        let perCallNoSpans = (elapsedNoSpans / Double(iterations)) * 1_000_000

        // With word spans
        let startWithSpans = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            _ = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines, withWordSpans: true)
        }
        let elapsedWithSpans = CFAbsoluteTimeGetCurrent() - startWithSpans
        let perCallWithSpans = (elapsedWithSpans / Double(iterations)) * 1_000_000

        let overhead = perCallWithSpans - perCallNoSpans
        let overheadPct = (overhead / perCallNoSpans) * 100

        print("[perf] Without word spans: \(String(format: "%.1f", perCallNoSpans))us")
        print("[perf] With word spans:    \(String(format: "%.1f", perCallWithSpans))us")
        print("[perf] Overhead:           \(String(format: "%.1f", overhead))us (\(String(format: "%.0f", overheadPct))%)")
        #expect(overhead < 5000, "Word span overhead should be under 5ms for medium edit")
    }
}
