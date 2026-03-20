import QuartzCore
import UIKit

/// Conway's Game of Life simulation + rendering on a bare CALayer.
///
/// Architecture:
/// - Flat `[Bool]` cell array, row-major, toroidal wrap
/// - `tick()` advances one generation (zero heap allocations)
/// - `draw(in:)` renders live cells as solid rects via CGContext
/// - Auto-reseeds on death (0 alive), stale (same hash 4+ ticks), or sparse (<2 alive)
///
/// This layer does NOT own timing — the parent `GameOfLifeUIView` drives
/// ticks via CADisplayLink and calls `setNeedsDisplay()`.
final class GameOfLifeLayer: CALayer {

    // MARK: - Configuration

    /// Grid dimension (gridSize x gridSize).
    var gridSize: Int {
        didSet { resetGrid() }
    }

    /// Fill color for live cells.
    var tintCGColor: CGColor = UIColor.label.cgColor

    /// Initial density of live cells (0.0–1.0).
    var initialDensity: Double = 0.33

    // MARK: - State

    /// Current cells, row-major. Internal for testing via @testable import.
    var cells: [Bool]

    /// Scratch buffer for next generation (avoids allocation per tick).
    private var nextCells: [Bool]

    /// Hash of previous generation for stale detection.
    private var previousHash: Int = 0

    /// Consecutive ticks with unchanged hash.
    private var staleCount: Int = 0

    /// Threshold for stale detection.
    private static let staleThreshold = 4

    /// Minimum alive cells before reseed.
    private static let sparseThreshold = 2

    // MARK: - Init

    init(gridSize: Int) {
        self.gridSize = gridSize
        let count = gridSize * gridSize
        self.cells = [Bool](repeating: false, count: count)
        self.nextCells = [Bool](repeating: false, count: count)
        super.init()
        self.contentsScale = UIScreen.main.scale
        self.isOpaque = false
        self.needsDisplayOnBoundsChange = true
        seed()
    }

    override init(layer: Any) {
        if let other = layer as? GameOfLifeLayer {
            self.gridSize = other.gridSize
            self.cells = other.cells
            self.nextCells = other.nextCells
            self.previousHash = other.previousHash
            self.staleCount = other.staleCount
        } else {
            self.gridSize = 6
            let count = 6 * 6
            self.cells = [Bool](repeating: false, count: count)
            self.nextCells = [Bool](repeating: false, count: count)
        }
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    // MARK: - Grid Management

    private func resetGrid() {
        let count = gridSize * gridSize
        cells = [Bool](repeating: false, count: count)
        nextCells = [Bool](repeating: false, count: count)
        previousHash = 0
        staleCount = 0
        seed()
    }

    /// Seed grid with random live cells at `initialDensity`.
    func seed() {
        let count = gridSize * gridSize
        for i in 0..<count {
            cells[i] = Double.random(in: 0..<1) < initialDensity
        }
        previousHash = computeHash()
        staleCount = 0
        setNeedsDisplay()
    }

    // MARK: - Simulation

    /// Advance one generation. Returns true if reseeded.
    @discardableResult
    func tick() -> Bool {
        let size = gridSize
        let count = size * size

        // Apply GoL rules with toroidal wrapping.
        for i in 0..<count {
            let row = i / size
            let col = i % size

            // Neighbor coordinates with toroidal wrap.
            let rUp = (row - 1 + size) % size
            let rDown = (row + 1) % size
            let cLeft = (col - 1 + size) % size
            let cRight = (col + 1) % size

            var neighbors = 0
            if cells[rUp * size + cLeft] { neighbors &+= 1 }
            if cells[rUp * size + col] { neighbors &+= 1 }
            if cells[rUp * size + cRight] { neighbors &+= 1 }
            if cells[row * size + cLeft] { neighbors &+= 1 }
            if cells[row * size + cRight] { neighbors &+= 1 }
            if cells[rDown * size + cLeft] { neighbors &+= 1 }
            if cells[rDown * size + col] { neighbors &+= 1 }
            if cells[rDown * size + cRight] { neighbors &+= 1 }

            if cells[i] {
                nextCells[i] = neighbors == 2 || neighbors == 3
            } else {
                nextCells[i] = neighbors == 3
            }
        }

        // Swap buffers (no allocation).
        swap(&cells, &nextCells)

        // Check for reseed conditions.
        let hash = computeHash()
        var aliveCount = 0
        for i in 0..<count where cells[i] { aliveCount += 1 }

        var didReseed = false

        if aliveCount == 0 || aliveCount < Self.sparseThreshold {
            seed()
            didReseed = true
        } else if hash == previousHash {
            staleCount += 1
            if staleCount >= Self.staleThreshold {
                seed()
                didReseed = true
            }
        } else {
            staleCount = 0
        }

        previousHash = hash
        return didReseed
    }

    private func computeHash() -> Int {
        var hasher = Hasher()
        for cell in cells {
            hasher.combine(cell)
        }
        return hasher.finalize()
    }

    // MARK: - Rendering

    override func draw(in ctx: CGContext) {
        let size = gridSize
        guard size > 0 else { return }

        let cellW = bounds.width / CGFloat(size)
        let cellH = bounds.height / CGFloat(size)
        let gap: CGFloat = max(0.5, min(cellW, cellH) * 0.15)

        ctx.setFillColor(tintCGColor)

        for i in 0..<(size * size) {
            guard cells[i] else { continue }
            let row = i / size
            let col = i % size
            let rect = CGRect(
                x: CGFloat(col) * cellW + gap * 0.5,
                y: CGFloat(row) * cellH + gap * 0.5,
                width: cellW - gap,
                height: cellH - gap
            )
            ctx.fill(rect)
        }
    }
}
