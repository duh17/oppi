import Foundation

/// Shared cell generation logic for the session grid icon.
///
/// Used by both `SessionGridView` (SwiftUI Canvas, placeholder) and
/// `SessionGridBadgeView` (UIKit cached image, assistant row badge).
///
/// Pure computation — no UI framework dependencies.
enum SessionGridRenderer {

    // MARK: - Types

    enum CellRole {
        case scatter, growth, piExposed, piEdge, piCore, almostSpark, spark
    }

    struct CellData {
        let row: Int
        let col: Int
        let role: CellRole
        let opacity: Float // pre-computed opacity for mono cells
    }

    // MARK: - Constants

    static let gridSize = 8

    // The ideal pi shape — right leg kicks outward
    private static let piIdeal: [Bool] = [
        false, false, false, false, false, false, false, false,
        false, true,  true,  true,  true,  true,  true,  false,
        false, false, true,  false, false, true,  false, false,
        false, false, true,  false, false, true,  false, false,
        false, false, true,  false, false, true,  false, false,
        false, false, true,  false, false, true,  false, false,
        false, false, true,  false, false, true,  true,  false,
        false, false, false, false, false, false, false, false,
    ]

    // Interior gap — never fill between legs
    private static let interiorGap: Set<Int> = {
        var set = Set<Int>()
        for r in 2...6 { for c in 3...4 { set.insert(r * gridSize + c) } }
        return set
    }()

    // Structural cells — don't erode
    private static let structural: Set<Int> = {
        let coords = [
            (1,1), (1,2), (1,3), (1,4), (1,5), (1,6),
            (2,2), (6,2), (2,5), (6,5), (6,6),
        ]
        return Set(coords.map { $0.0 * gridSize + $0.1 })
    }()

    // MARK: - Generate

    /// Generate cells for a given session ID. Deterministic per ID.
    static func generateCells(sessionId: String) -> [CellData] {
        let seed = seedFrom(sessionId)
        var rng = SplitMix64(seed: seed)
        let grid = gridSize

        var alive = piIdeal
        // 0 = empty, 1 = pi, 2 = growth, 3 = scatter
        var cellType = alive.map { $0 ? 1 : 0 }

        // Erode ~18% of non-structural edge cells
        var edgeIndices: [Int] = []
        for i in 0..<(grid * grid) where alive[i] && !structural.contains(i) {
            if isEdge(i, grid: grid, alive: alive) { edgeIndices.append(i) }
        }
        edgeIndices.shuffle(using: &rng)
        let erodeCount = max(1, edgeIndices.count * 18 / 100)
        for i in edgeIndices.prefix(erodeCount) {
            alive[i] = false
            cellType[i] = 0
        }

        // Grow ~22% of adjacent empty cells (not into interior gap)
        var growCandidates = Set<Int>()
        for i in 0..<(grid * grid) where alive[i] {
            let r = i / grid, c = i % grid
            for (dr, dc) in [(-1,-1),(-1,0),(-1,1),(0,-1),(0,1),(1,-1),(1,0),(1,1)] {
                let nr = r + dr, nc = c + dc
                guard nr >= 0, nr < grid, nc >= 0, nc < grid else { continue }
                let ni = nr * grid + nc
                if !alive[ni] && !interiorGap.contains(ni) {
                    growCandidates.insert(ni)
                }
            }
        }
        var growList = Array(growCandidates).sorted()
        growList.shuffle(using: &rng)
        let growCount = max(1, growList.count * 22 / 100)
        for i in growList.prefix(growCount) {
            alive[i] = true
            cellType[i] = 2
        }

        // Scatter ~8% debris
        for i in 0..<(grid * grid) where !alive[i] && !interiorGap.contains(i) {
            if rng.nextDouble() < 0.08 {
                alive[i] = true
                cellType[i] = 3
            }
        }

        // Neighbor density for brightness grading
        func neighbors(_ idx: Int) -> Int {
            let r = idx / grid, c = idx % grid
            var count = 0
            for (dr, dc) in [(-1,-1),(-1,0),(-1,1),(0,-1),(0,1),(1,-1),(1,0),(1,1)] {
                let nr = r + dr, nc = c + dc
                if nr >= 0, nr < grid, nc >= 0, nc < grid, alive[nr * grid + nc] { count += 1 }
            }
            return count
        }

        // Pick sparks (1-2) and almost-sparks (2-3)
        let piIndices = (0..<(grid * grid)).filter { cellType[$0] == 1 }
        var sparkSet = Set<Int>()
        var almostSet = Set<Int>()

        var shuffledPi = piIndices
        shuffledPi.shuffle(using: &rng)
        let sparkCount = 1 + (rng.nextDouble() > 0.5 ? 1 : 0)
        for i in shuffledPi.prefix(sparkCount) { sparkSet.insert(i) }
        let remaining = shuffledPi.filter { !sparkSet.contains($0) }
        let almostCount = 2 + (rng.nextDouble() > 0.6 ? 1 : 0)
        for i in remaining.prefix(almostCount) { almostSet.insert(i) }

        // Build cell data
        var result: [CellData] = []
        for i in 0..<(grid * grid) where alive[i] {
            let r = i / grid, c = i % grid
            let type = cellType[i]
            let n = neighbors(i)

            let role: CellRole
            let opacity: Float

            if sparkSet.contains(i) {
                role = .spark
                opacity = 0.90
            } else if almostSet.contains(i) {
                role = .almostSpark
                opacity = 0.40
            } else if type == 1 {
                // Pi body — density graded
                if n <= 2 {
                    role = .piExposed
                    opacity = 0.25 + Float(rng.nextDouble()) * 0.08
                } else if n <= 4 {
                    role = .piEdge
                    opacity = 0.38 + Float(rng.nextDouble()) * 0.10
                } else {
                    role = .piCore
                    opacity = 0.55 + Float(rng.nextDouble()) * 0.10
                }
            } else if type == 2 {
                role = .growth
                opacity = 0.15 + Float(rng.nextDouble()) * 0.06
            } else {
                role = .scatter
                opacity = 0.08 + Float(rng.nextDouble()) * 0.05
            }

            result.append(CellData(row: r, col: c, role: role, opacity: opacity))
        }
        return result
    }

    // MARK: - Helpers

    private static func isEdge(_ i: Int, grid: Int, alive: [Bool]) -> Bool {
        let r = i / grid, c = i % grid
        for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let nr = r + dr, nc = c + dc
            if nr < 0 || nr >= grid || nc < 0 || nc >= grid { return true }
            if !alive[nr * grid + nc] { return true }
        }
        return false
    }

    /// FNV-1a 64-bit hash
    private static func seedFrom(_ id: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

// MARK: - SplitMix64 PRNG

/// Minimal splitmix64 for reproducible patterns.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
