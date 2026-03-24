import QuartzCore
import UIKit

/// Conway's Game of Life simulation + rendering on a bare CALayer.
///
/// Architecture:
/// - UInt64 bit-packed grid (36 bits for 6×6, fits in one register)
/// - `[UInt8]` age array for color mapping (newborn → elder)
/// - `tick()` advances one generation via bit manipulation
/// - `draw(in:)` renders live cells as age-colored rects via CGContext
/// - Auto-reseeds on death (0 alive), stale (same bits 4+ ticks), or sparse (<2 alive)
///
/// This layer does NOT own timing — the parent `GameOfLifeUIView` drives
/// ticks via CADisplayLink and calls `setNeedsDisplay()`.
final class GameOfLifeLayer: CALayer {

    // MARK: - Configuration

    /// Grid dimension (gridSize x gridSize). Must be <= 8 (64 bits max).
    var gridSize: Int {
        didSet { resetGrid() }
    }

    /// Base color for live cells. Individual cell colors shift hue based on age.
    var tintCGColor: CGColor = UIColor.label.cgColor {
        didSet { rebuildColorPalette() }
    }

    /// Initial density of live cells (0.0–1.0).
    var initialDensity: Double = 0.33

    // MARK: - Color Palette

    /// Max age tiers for color mapping.
    private static let maxAgeTiers = 8

    /// Precomputed CGColors for each age tier. Rebuilt when tintCGColor changes.
    private var colorPalette: [CGColor] = []

    // MARK: - State

    /// Bit-packed cell grid. Bit i = cell i (row-major). Internal for testing.
    private var bits: UInt64 = 0

    // periphery:ignore
    /// Compatibility: cells as [Bool] array, derived from bits. Internal for testing.
    var cells: [Bool] {
        get {
            let count = gridSize * gridSize
            var result = [Bool](repeating: false, count: count)
            for i in 0..<count {
                result[i] = (bits >> i) & 1 == 1
            }
            return result
        }
        set {
            bits = 0
            for i in 0..<min(newValue.count, 64) {
                if newValue[i] { bits |= 1 << i }
            }
        }
    }

    /// Age of each cell in ticks (0 = just born this tick). Internal for testing.
    var ages: [UInt8]

    /// Scratch buffer for next generation ages.
    private var nextAges: [UInt8]

    /// History ring for stale/oscillator detection (catches period 1-4).
    /// Using ContiguousArray avoids SwiftLint large_tuple violation.
    private var historyRing: ContiguousArray<UInt64> = [0, 0, 0, 0]
    private var historyIndex: Int = 0
    private var ticksSinceReseed: Int = 0

    /// Minimum ticks before checking for oscillation.
    private static let staleCheckDelay = 8

    /// Minimum alive cells before reseed.
    private static let sparseThreshold = 2

    // MARK: - Init

    init(gridSize: Int) {
        self.gridSize = gridSize
        let count = gridSize * gridSize
        self.ages = [UInt8](repeating: 0, count: count)
        self.nextAges = [UInt8](repeating: 0, count: count)
        super.init()
        self.contentsScale = UIScreen.main.scale
        self.isOpaque = false
        self.needsDisplayOnBoundsChange = true
        rebuildColorPalette()
        seed()
    }

    override init(layer: Any) {
        if let other = layer as? GameOfLifeLayer {
            self.gridSize = other.gridSize
            self.bits = other.bits
            self.ages = other.ages
            self.nextAges = other.nextAges
            self.historyRing = ContiguousArray(other.historyRing)
            self.historyIndex = other.historyIndex
            self.ticksSinceReseed = other.ticksSinceReseed
            self.colorPalette = other.colorPalette
        } else {
            self.gridSize = 6
            let count = 6 * 6
            self.ages = [UInt8](repeating: 0, count: count)
            self.nextAges = [UInt8](repeating: 0, count: count)
        }
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    // MARK: - Grid Management

    private func resetGrid() {
        let count = gridSize * gridSize
        bits = 0
        ages = [UInt8](repeating: 0, count: count)
        nextAges = [UInt8](repeating: 0, count: count)
        historyRing = [0, 0, 0, 0]
        historyIndex = 0
        ticksSinceReseed = 0
        seed()
    }

    /// Seed grid with random live cells at `initialDensity`.
    func seed() {
        let count = gridSize * gridSize
        bits = 0
        for i in 0..<count {
            let alive = Double.random(in: 0..<1) < initialDensity
            if alive {
                bits |= 1 << i
                ages[i] = UInt8.random(in: 0...3)
            } else {
                ages[i] = 0
            }
        }
        historyRing = [bits, bits, bits, bits]
        historyIndex = 0
        ticksSinceReseed = 0
        setNeedsDisplay()
    }

    // MARK: - Color Palette

    private func rebuildColorPalette() {
        let uiColor = UIColor(cgColor: tintCGColor)
        var baseHue: CGFloat = 0
        var baseSat: CGFloat = 0
        var baseBri: CGFloat = 0
        var baseAlpha: CGFloat = 1
        uiColor.getHue(&baseHue, saturation: &baseSat, brightness: &baseBri, alpha: &baseAlpha)

        let isAchromatic = baseSat < 0.05
        let startHue: CGFloat = isAchromatic ? 0.0 : baseHue
        let hueRange: CGFloat = 0.75

        var palette = [CGColor]()
        palette.reserveCapacity(Self.maxAgeTiers)

        for tier in 0..<Self.maxAgeTiers {
            let t = CGFloat(tier) / CGFloat(Self.maxAgeTiers - 1)
            let hue = (startHue + t * hueRange).truncatingRemainder(dividingBy: 1.0)
            let sat: CGFloat = isAchromatic ? (0.6 + t * 0.3) : max(0.4, baseSat)
            let bri: CGFloat = isAchromatic ? (0.95 - t * 0.2) : max(0.5, baseBri - t * 0.15)
            let alpha: CGFloat = 0.7 + t * 0.3
            palette.append(UIColor(hue: hue, saturation: sat, brightness: bri, alpha: alpha).cgColor)
        }

        colorPalette = palette
    }

    // MARK: - Simulation

    /// Advance one generation. Returns true if reseeded.
    @discardableResult
    func tick() -> Bool {
        let size = gridSize
        let count = size * size
        var newBits: UInt64 = 0
        let currentBits = bits
        let sizeMinus1 = size - 1

        // Apply GoL rules with toroidal wrapping.
        // Track row/col manually and precompute row offsets to avoid
        // all division, modulo, and multiplication in the hot loop.
        var row = 0
        var col = 0
        var rowOffset = 0             // row * size
        var rowUpOffset = sizeMinus1 * size  // rUp * size (initially last row)
        var rowDownOffset = size       // rDown * size (initially row 1)
        for i in 0..<count {
            let cLeft = col == 0 ? sizeMinus1 : col - 1
            let cRight = col == sizeMinus1 ? 0 : col + 1

            // Count neighbors via bit extraction using precomputed offsets.
            var neighbors = 0
            if (currentBits >> (rowUpOffset + cLeft))    & 1 == 1 { neighbors &+= 1 }
            if (currentBits >> (rowUpOffset + col))      & 1 == 1 { neighbors &+= 1 }
            if (currentBits >> (rowUpOffset + cRight))   & 1 == 1 { neighbors &+= 1 }
            if (currentBits >> (rowOffset + cLeft))      & 1 == 1 { neighbors &+= 1 }
            if (currentBits >> (rowOffset + cRight))     & 1 == 1 { neighbors &+= 1 }
            if (currentBits >> (rowDownOffset + cLeft))  & 1 == 1 { neighbors &+= 1 }
            if (currentBits >> (rowDownOffset + col))    & 1 == 1 { neighbors &+= 1 }
            if (currentBits >> (rowDownOffset + cRight)) & 1 == 1 { neighbors &+= 1 }

            let alive = (currentBits >> i) & 1 == 1
            if alive {
                let survives = neighbors == 2 || neighbors == 3
                if survives {
                    newBits |= 1 << i
                    nextAges[i] = ages[i] &+ 1
                } else {
                    nextAges[i] = 0
                }
            } else {
                if neighbors == 3 {
                    newBits |= 1 << i
                    nextAges[i] = 0
                } else {
                    nextAges[i] = 0
                }
            }

            // Advance row/col and precomputed offsets.
            col &+= 1
            if col == size {
                col = 0
                row &+= 1
                rowUpOffset = rowOffset
                rowOffset = rowDownOffset
                rowDownOffset = row == sizeMinus1 ? 0 : rowDownOffset &+ size
            }
        }

        bits = newBits
        swap(&ages, &nextAges)

        // Stale/death/sparse detection — no hash needed, bits ARE the hash.
        let aliveCount = newBits.nonzeroBitCount
        var didReseed = false

        if aliveCount < Self.sparseThreshold {
            seed()
            didReseed = true
        } else {
            ticksSinceReseed &+= 1

            // Check for oscillation (period 1-4) using history ring.
            // Only check after enough ticks to avoid false positives from seed.
            if ticksSinceReseed >= Self.staleCheckDelay {
                let isStale = newBits == historyRing[0]
                    || newBits == historyRing[1]
                    || newBits == historyRing[2]
                    || newBits == historyRing[3]
                if isStale {
                    seed()
                    didReseed = true
                }
            }

            // Rotate history ring.
            historyRing[historyIndex & 3] = newBits
            historyIndex &+= 1
        }

        return didReseed
    }

    // MARK: - Rendering

    /// Precomputed cell rects. Rebuilt on layout change.
    private var cellRects: [CGRect] = []
    private var lastLayoutSize: CGSize = .zero

    private func rebuildCellRects() {
        let size = gridSize
        let count = size * size
        guard size > 0 else { cellRects = []; return }

        let cellW = bounds.width / CGFloat(size)
        let cellH = bounds.height / CGFloat(size)
        let gapX = max(0.5, cellW * 0.15) * 0.5
        let gapY = max(0.5, cellH * 0.15) * 0.5
        let rectW = cellW - gapX * 2
        let rectH = cellH - gapY * 2

        cellRects = [CGRect](repeating: .zero, count: count)
        for i in 0..<count {
            let row = i / size
            let col = i % size
            cellRects[i] = CGRect(
                x: CGFloat(col) * cellW + gapX,
                y: CGFloat(row) * cellH + gapY,
                width: rectW,
                height: rectH
            )
        }
        lastLayoutSize = bounds.size
    }

    override func draw(in ctx: CGContext) {
        let size = gridSize
        let count = size * size
        guard size > 0 else { return }

        // Rebuild rects if layout changed.
        if bounds.size != lastLayoutSize || cellRects.count != count {
            rebuildCellRects()
        }

        let maxTier = UInt8(Self.maxAgeTiers - 1)
        let currentBits = bits

        for i in 0..<count {
            guard (currentBits >> i) & 1 == 1 else { continue }

            let tier = Int(min(ages[i], maxTier))
            let color = tier < colorPalette.count ? colorPalette[tier] : tintCGColor
            ctx.setFillColor(color)
            ctx.fill(cellRects[i])
        }
    }
}
