import AppKit
import SwiftUI

// MARK: - Simulation Layer

/// Conway's Game of Life simulation + rendering on a bare CALayer (macOS).
///
/// Mirrors the iOS `GameOfLifeLayer` implementation:
/// - Flat `[Bool]` cell array, row-major, toroidal wrap
/// - `tick()` advances one generation (zero heap allocations)
/// - `draw(in:)` renders live cells as solid rects via CGContext
/// - Auto-reseeds on death, stale, or sparse states
private final class GameOfLifeMacLayer: CALayer {

    var gridSize: Int
    var tintCGColor: CGColor = NSColor.labelColor.cgColor
    var initialDensity: Double = 0.33

    private(set) var cells: [Bool]
    private var nextCells: [Bool]
    private var previousHash: Int = 0
    private var staleCount: Int = 0

    private static let staleThreshold = 4
    private static let sparseThreshold = 2

    init(gridSize: Int) {
        self.gridSize = gridSize
        let count = gridSize * gridSize
        self.cells = [Bool](repeating: false, count: count)
        self.nextCells = [Bool](repeating: false, count: count)
        super.init()
        self.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        self.isOpaque = false
        self.needsDisplayOnBoundsChange = true
        seed()
    }

    override init(layer: Any) {
        if let other = layer as? GameOfLifeMacLayer {
            self.gridSize = other.gridSize
            self.cells = other.cells
            self.nextCells = other.nextCells
            self.previousHash = other.previousHash
            self.staleCount = other.staleCount
        } else {
            self.gridSize = 5
            let count = 5 * 5
            self.cells = [Bool](repeating: false, count: count)
            self.nextCells = [Bool](repeating: false, count: count)
        }
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    func seed() {
        let count = gridSize * gridSize
        for i in 0..<count {
            cells[i] = Double.random(in: 0..<1) < initialDensity
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
                nextCells[i] = neighbors == 2 || neighbors == 3
            } else {
                nextCells[i] = neighbors == 3
            }
        }

        swap(&cells, &nextCells)

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
    private var timer: Timer?

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
        stopAnimation()
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
            self?.timerFired()
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
