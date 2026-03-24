import AppKit
import SwiftUI

// MARK: - Simulation Layer

/// Conway's Game of Life simulation + rendering on a bare CALayer (macOS).
///
/// Mirrors the iOS `GameOfLifeLayer` implementation:
/// - Flat `[Bool]` cell array, row-major, toroidal wrap
/// - Age tracking per cell for color mapping (newborn → elder)
/// - `tick()` advances one generation (zero heap allocations)
/// - `draw(in:)` renders live cells as age-colored rects via CGContext
/// - Auto-reseeds on death, stale, or sparse states
private final class GameOfLifeMacLayer: CALayer {

    var gridSize: Int
    var tintCGColor: CGColor = NSColor.labelColor.cgColor {
        didSet { rebuildColorPalette() }
    }
    var initialDensity: Double = 0.33

    // Color palette
    private static let maxAgeTiers = 8
    private var colorPalette: [CGColor] = []

    private(set) var cells: [Bool]
    private var ages: [UInt8]
    private var nextCells: [Bool]
    private var nextAges: [UInt8]
    private var previousHash: Int = 0
    private var staleCount: Int = 0

    private static let staleThreshold = 4
    private static let sparseThreshold = 2

    init(gridSize: Int) {
        self.gridSize = gridSize
        let count = gridSize * gridSize
        self.cells = [Bool](repeating: false, count: count)
        self.ages = [UInt8](repeating: 0, count: count)
        self.nextCells = [Bool](repeating: false, count: count)
        self.nextAges = [UInt8](repeating: 0, count: count)
        super.init()
        self.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        self.isOpaque = false
        self.needsDisplayOnBoundsChange = true
        rebuildColorPalette()
        seed()
    }

    override init(layer: Any) {
        if let other = layer as? GameOfLifeMacLayer {
            self.gridSize = other.gridSize
            self.cells = other.cells
            self.ages = other.ages
            self.nextCells = other.nextCells
            self.nextAges = other.nextAges
            self.previousHash = other.previousHash
            self.staleCount = other.staleCount
            self.colorPalette = other.colorPalette
        } else {
            self.gridSize = 5
            let count = 5 * 5
            self.cells = [Bool](repeating: false, count: count)
            self.ages = [UInt8](repeating: 0, count: count)
            self.nextCells = [Bool](repeating: false, count: count)
            self.nextAges = [UInt8](repeating: 0, count: count)
        }
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    private func rebuildColorPalette() {
        let nsColor = NSColor(cgColor: tintCGColor) ?? NSColor.labelColor
        let hsbColor = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        let baseHue = hsbColor.hueComponent
        let baseSat = hsbColor.saturationComponent
        let baseBri = hsbColor.brightnessComponent

        let isAchromatic = baseSat < 0.05
        let startHue: CGFloat = isAchromatic ? 0.75 : baseHue
        let hueRange: CGFloat = 0.25

        var palette = [CGColor]()
        palette.reserveCapacity(Self.maxAgeTiers)

        for tier in 0..<Self.maxAgeTiers {
            let t = CGFloat(tier) / CGFloat(Self.maxAgeTiers - 1)
            let hue = (startHue + t * hueRange).truncatingRemainder(dividingBy: 1.0)
            let sat: CGFloat = isAchromatic ? (0.6 + t * 0.3) : max(0.4, baseSat)
            let bri: CGFloat = isAchromatic ? (0.95 - t * 0.2) : max(0.5, baseBri - t * 0.15)
            let alpha: CGFloat = 0.7 + t * 0.3
            palette.append(NSColor(hue: hue, saturation: sat, brightness: bri, alpha: alpha).cgColor)
        }

        colorPalette = palette
    }

    func seed() {
        let count = gridSize * gridSize
        for i in 0..<count {
            let alive = Double.random(in: 0..<1) < initialDensity
            cells[i] = alive
            ages[i] = alive ? UInt8.random(in: 0...3) : 0
        }
        previousHash = computeHash()
        staleCount = 0
        setNeedsDisplay()
    }

    @discardableResult
    func tick() -> Bool {
        let size = gridSize
        let count = size * size

        for i in 0..<count {
            let row = i / size
            let col = i % size
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
                let survives = neighbors == 2 || neighbors == 3
                nextCells[i] = survives
                nextAges[i] = survives ? ages[i] &+ 1 : 0
            } else {
                let born = neighbors == 3
                nextCells[i] = born
                nextAges[i] = 0
            }
        }

        swap(&cells, &nextCells)
        swap(&ages, &nextAges)

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
        for cell in cells { hasher.combine(cell) }
        return hasher.finalize()
    }

    override func draw(in ctx: CGContext) {
        let size = gridSize
        guard size > 0 else { return }

        let cellW = bounds.width / CGFloat(size)
        let cellH = bounds.height / CGFloat(size)
        let gap: CGFloat = max(0.5, min(cellW, cellH) * 0.15)
        let maxTier = UInt8(Self.maxAgeTiers - 1)

        for i in 0..<(size * size) {
            guard cells[i] else { continue }
            let row = i / size
            let col = i % size

            let tier = Int(min(ages[i], maxTier))
            let color = tier < colorPalette.count ? colorPalette[tier] : tintCGColor
            ctx.setFillColor(color)

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

// MARK: - NSView Wrapper

/// NSView wrapper that drives a `GameOfLifeMacLayer` with a Timer.
///
/// macOS does not expose `CADisplayLink(target:selector:)` directly.
/// A Timer at ~8 FPS is equivalent for this use case.
private final class GameOfLifeNSView: NSView {

    let gridSize: Int
    var tintNSColor: NSColor = .labelColor {
        didSet { golLayer.tintCGColor = tintNSColor.cgColor }
    }

    private let golLayer: GameOfLifeMacLayer
    // nonisolated(unsafe): Timer is only touched on main thread but deinit
    // runs in a nonisolated context — this silences the strict-concurrency error.
    private nonisolated(unsafe) var timer: Timer?

    init(gridSize: Int) {
        self.gridSize = gridSize
        self.golLayer = GameOfLifeMacLayer(gridSize: gridSize)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(golLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    deinit {
        timer?.invalidate()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        golLayer.frame = bounds
        golLayer.contentsScale = window?.backingScaleFactor ?? 2.0
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startAnimation()
        } else {
            stopAnimation()
        }
    }

    private func startAnimation() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 8.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }

    private func timerFired() {
        golLayer.tick()
        golLayer.setNeedsDisplay()
    }
}

// MARK: - SwiftUI Bridge

/// SwiftUI bridge for the Game of Life indicator (macOS).
struct GameOfLifeRepresentable: NSViewRepresentable {

    let gridSize: Int
    let color: NSColor

    init(gridSize: Int = 5, color: NSColor = .labelColor) {
        self.gridSize = gridSize
        self.color = color
    }

    func makeNSView(context: Context) -> NSView {
        let view = GameOfLifeNSView(gridSize: gridSize)
        view.tintNSColor = color
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let golView = nsView as? GameOfLifeNSView {
            golView.tintNSColor = color
        }
    }
}
