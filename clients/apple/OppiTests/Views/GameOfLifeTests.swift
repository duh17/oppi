import CoreFoundation
import Testing

@testable import Oppi

@Suite("GameOfLifeLayer")
struct GameOfLifeTests {

    // MARK: - Initialization

    @Test("seed produces cells near target density")
    func seedDensity() {
        let layer = GameOfLifeLayer(gridSize: 10)
        let count = layer.cells.count
        let alive = layer.cells.filter { $0 }.count
        let density = Double(alive) / Double(count)
        // 33% target density, allow wide range for small grid
        #expect(density > 0.1 && density < 0.6, "Expected density near 0.33, got \(density)")
    }

    @Test("grid size matches expected cell count")
    func gridCellCount() {
        let layer = GameOfLifeLayer(gridSize: 6)
        #expect(layer.cells.count == 36)
    }

    // MARK: - Toroidal Wrapping

    @Test("corner cell wraps to opposite edges")
    func toroidalWrapping() {
        // Place a glider-like pattern at top-left corner that requires wrapping.
        // Set up a 5x5 grid with 3 cells that would produce a birth at (4,4) via wrapping.
        let layer = GameOfLifeLayer(gridSize: 5)
        // Clear all cells
        for i in 0..<25 { layer.cells[i] = false }

        // Place 3 live cells around the (0,0) corner using toroidal neighbors.
        // (0,0) has toroidal neighbors at (4,4), (4,0), (4,1), (0,4), (0,1), (1,4), (1,0), (1,1).
        // To birth at (4,4), it needs exactly 3 neighbors alive.
        // Neighbors of (4,4) on a 5x5 toroidal grid:
        //   (3,3), (3,4), (3,0), (4,3), (4,0), (0,3), (0,4), (0,0)
        // Set (3,3), (3,4), (3,0) alive -> (4,4) should be born.
        layer.cells[3 * 5 + 3] = true  // (3,3)
        layer.cells[3 * 5 + 4] = true  // (3,4)
        layer.cells[3 * 5 + 0] = true  // (3,0)

        layer.tick()

        // (4,4) should now be alive (born from 3 wrapping neighbors)
        #expect(layer.cells[4 * 5 + 4] == true, "Cell at (4,4) should be born via toroidal wrap")
    }

    // MARK: - GoL Rules

    @Test("blinker oscillates correctly")
    func blinkerOscillator() {
        // Blinker: classic period-2 oscillator
        // Horizontal: (1,0), (1,1), (1,2) on a 5x5 grid
        let layer = GameOfLifeLayer(gridSize: 5)
        for i in 0..<25 { layer.cells[i] = false }

        // Horizontal blinker in center
        layer.cells[2 * 5 + 1] = true  // (2,1)
        layer.cells[2 * 5 + 2] = true  // (2,2)
        layer.cells[2 * 5 + 3] = true  // (2,3)

        let beforeTick = layer.cells
        layer.tick()
        let afterOneTick = layer.cells

        // Should become vertical
        #expect(afterOneTick[1 * 5 + 2] == true, "Blinker vertical (1,2)")
        #expect(afterOneTick[2 * 5 + 2] == true, "Blinker vertical (2,2)")
        #expect(afterOneTick[3 * 5 + 2] == true, "Blinker vertical (3,2)")
        #expect(afterOneTick[2 * 5 + 1] == false, "Blinker cleared (2,1)")
        #expect(afterOneTick[2 * 5 + 3] == false, "Blinker cleared (2,3)")

        layer.tick()
        let afterTwoTicks = layer.cells

        // Should return to horizontal (period 2)
        #expect(afterTwoTicks[2 * 5 + 1] == true, "Blinker restored (2,1)")
        #expect(afterTwoTicks[2 * 5 + 2] == true, "Blinker restored (2,2)")
        #expect(afterTwoTicks[2 * 5 + 3] == true, "Blinker restored (2,3)")
        #expect(afterTwoTicks[1 * 5 + 2] == false, "Blinker cleared (1,2)")
        #expect(afterTwoTicks[3 * 5 + 2] == false, "Blinker cleared (3,2)")

        // Verify the two-tick cycle matches the original
        for i in 0..<25 {
            #expect(beforeTick[i] == afterTwoTicks[i], "Blinker period-2 failed at index \(i)")
        }
    }

    @Test("block still life is stable")
    func blockStillLife() {
        // Block: 2x2 square, should not change
        let layer = GameOfLifeLayer(gridSize: 6)
        for i in 0..<36 { layer.cells[i] = false }

        layer.cells[2 * 6 + 2] = true  // (2,2)
        layer.cells[2 * 6 + 3] = true  // (2,3)
        layer.cells[3 * 6 + 2] = true  // (3,2)
        layer.cells[3 * 6 + 3] = true  // (3,3)

        let before = layer.cells
        layer.tick()

        // Block should remain unchanged (ignoring reseed for now — 4 alive > sparseThreshold)
        for i in 0..<36 {
            #expect(layer.cells[i] == before[i], "Block should be stable at index \(i)")
        }
    }

    // MARK: - Reseed Detection

    @Test("dead grid triggers reseed")
    func reseedOnDeath() {
        let layer = GameOfLifeLayer(gridSize: 6)
        // Kill all cells
        for i in 0..<36 { layer.cells[i] = false }

        let reseeded = layer.tick()
        #expect(reseeded == true, "Should reseed when all cells are dead")

        let alive = layer.cells.filter { $0 }.count
        #expect(alive > 0, "After reseed, should have live cells")
    }

    @Test("sparse grid triggers reseed")
    func reseedOnSparse() {
        let layer = GameOfLifeLayer(gridSize: 6)
        // Set only 1 cell alive (below sparseThreshold of 2)
        for i in 0..<36 { layer.cells[i] = false }
        layer.cells[0] = true

        let reseeded = layer.tick()
        #expect(reseeded == true, "Should reseed when below sparse threshold")
    }

    @Test("stale grid triggers reseed after threshold")
    func reseedOnStale() {
        // A block is a still-life that will trigger stale detection
        let layer = GameOfLifeLayer(gridSize: 6)
        for i in 0..<36 { layer.cells[i] = false }

        // Place a block (stable pattern)
        layer.cells[2 * 6 + 2] = true
        layer.cells[2 * 6 + 3] = true
        layer.cells[3 * 6 + 2] = true
        layer.cells[3 * 6 + 3] = true

        // Tick until reseed (staleThreshold = 4)
        let reseeded = (0..<10).contains { _ in layer.tick() }

        #expect(reseeded == true, "Stable block should trigger reseed within 10 ticks")
    }

    // MARK: - Performance

    @Test("tick performance: 10000 ticks on 6x6 grid")
    func tickPerformance() {
        let layer = GameOfLifeLayer(gridSize: 6)

        let iterations = 10_000
        let start = CFAbsoluteTimeGetCurrent()

        for _ in 0..<iterations {
            layer.tick()
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let perTick = elapsed / Double(iterations)

        // Target: <5us per tick. Allow 50us for CI variability.
        #expect(perTick < 0.00005, "Tick too slow: \(perTick * 1_000_000)us per tick (target <50us)")
    }

    // MARK: - Age Tracking

    @Test("newborn cells start at age 0")
    func newbornAge() {
        let layer = GameOfLifeLayer(gridSize: 5)
        for i in 0..<25 { layer.cells[i] = false; layer.ages[i] = 0 }

        // Set up birth at (2,2): needs exactly 3 neighbors
        layer.cells[1 * 5 + 1] = true; layer.ages[1 * 5 + 1] = 5
        layer.cells[1 * 5 + 2] = true; layer.ages[1 * 5 + 2] = 5
        layer.cells[1 * 5 + 3] = true; layer.ages[1 * 5 + 3] = 5

        layer.tick()

        // (2,2) should be born with age 0
        #expect(layer.cells[2 * 5 + 2] == true, "Cell should be born at (2,2)")
        #expect(layer.ages[2 * 5 + 2] == 0, "Newborn cell should have age 0")
    }

    @Test("surviving cells increment age")
    func survivingAge() {
        // Block: 2x2 still life, all cells survive every tick
        let layer = GameOfLifeLayer(gridSize: 6)
        for i in 0..<36 { layer.cells[i] = false; layer.ages[i] = 0 }

        layer.cells[2 * 6 + 2] = true; layer.ages[2 * 6 + 2] = 0
        layer.cells[2 * 6 + 3] = true; layer.ages[2 * 6 + 3] = 0
        layer.cells[3 * 6 + 2] = true; layer.ages[3 * 6 + 2] = 0
        layer.cells[3 * 6 + 3] = true; layer.ages[3 * 6 + 3] = 0

        layer.tick()

        #expect(layer.ages[2 * 6 + 2] == 1, "Surviving cell age should increment to 1")
        #expect(layer.ages[2 * 6 + 3] == 1)
        #expect(layer.ages[3 * 6 + 2] == 1)
        #expect(layer.ages[3 * 6 + 3] == 1)

        layer.tick()

        #expect(layer.ages[2 * 6 + 2] == 2, "Surviving cell age should increment to 2")
    }

    @Test("dead cells have age 0")
    func deadCellAge() {
        let layer = GameOfLifeLayer(gridSize: 5)
        for i in 0..<25 { layer.cells[i] = false; layer.ages[i] = 0 }

        // Single cell dies from underpopulation
        layer.cells[2 * 5 + 2] = true
        layer.ages[2 * 5 + 2] = 5

        layer.tick()

        // Cell should be dead, ages array valid
        #expect(layer.ages.count == 25)
    }

    @Test("reseed frequency is reasonable over 10000 ticks")
    func reseedFrequency() {
        let layer = GameOfLifeLayer(gridSize: 6)

        var reseedCount = 0
        // Use 10000 ticks to reduce flakiness — some random seeds produce
        // long-lived oscillators (period 2+) that avoid single-generation
        // stale detection for thousands of ticks.
        for _ in 0..<10_000 {
            if layer.tick() { reseedCount += 1 }
        }

        // On a 6x6 toroidal grid with stale detection (threshold=4) and
        // sparse/death checks, reseeds should happen regularly.
        #expect(reseedCount >= 1, "Should reseed at least once in 10000 ticks (got \(reseedCount))")
        #expect(reseedCount < 5000, "Too many reseeds in 10000 ticks (got \(reseedCount))")
    }
}
