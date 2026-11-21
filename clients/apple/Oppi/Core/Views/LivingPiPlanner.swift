import Foundation

/// The plan behind the sidebar's living π (`LivingPiMarkView`): two elves
/// move the π's blocks around a 9 × 9 grid, one job at a time, for ever.
///
/// The cells come from the app icon's layers (`AppIcon.icon`: 85 px cells on
/// a 97 px pitch). The π's 16 cells are *slots*. Blocks differ only by tint,
/// so any block may fill any slot and the colours drift; nothing resets.
/// Rules every job keeps, rehearsed on a copy before it is accepted:
///
/// - At most `maxAway` blocks are off a slot at any moment, mid-job too.
/// - A block off a slot never comes to rest inside or under the arch
///   (`noPark`): that closes the π into a box. It may pass through.
/// - Blocks move like Sokoban with pulling: a block steps into a free cell
///   with an elf behind it (push) or ahead of it walking backwards (pull).
///   Elves and blocks never share a cell when a job ends.
///
/// Which jobs may run depends on how many blocks are out: with none out the
/// elves knock, nudge or carry one out, shove two crooked, swap two, or
/// wander; with the limit out they only heal (work a loose block into any
/// empty slot), move a loose block, or wander.
///
/// A plain value: the view asks for one job, turns its tracks into Core
/// Animation keyframes, and holds the result until the next wake.
struct LivingPiPlanner {
    struct Cell: Hashable {
        var col: Int
        var row: Int

        static func + (a: Self, b: Self) -> Self { Self(col: a.col + b.col, row: a.row + b.row) }
        func step(_ d: Self, _ k: Int = 1) -> Self { Self(col: col + d.col * k, row: row + d.row * k) }
        func distance(to b: Self) -> Int { abs(col - b.col) + abs(row - b.row) }
    }

    /// A block's colour, as the icon draws it. `ink` is the icon's white.
    enum Tint: CaseIterable {
        case ink, amber, red, blue, sky, periwinkle, lavender
    }

    /// Where an actor is drawn: a cell position (fractional mid-move) and a
    /// size, 1 at rest; lifted blocks and working elves grow a little.
    struct Pose: Equatable {
        var x: Double
        var y: Double
        var scale: Double

        init(_ x: Double, _ y: Double, _ scale: Double = 1) {
            self.x = x
            self.y = y
            self.scale = scale
        }

        init(_ cell: Cell, _ scale: Double = 1) {
            self.init(Double(cell.col), Double(cell.row), scale)
        }
    }

    enum Ease {
        case smooth, linear, easeOut

        func callAsFunction(_ u: Double) -> Double {
            let u = min(1, max(0, u))
            switch self {
            case .smooth: return u * u * (3 - 2 * u)
            case .linear: return u
            case .easeOut: return 1 - pow(1 - u, 3)
            }
        }
    }

    /// One actor's motion through a job: segments in time order, each easing
    /// along a polyline with equal time per point. Between segments the
    /// actor holds still.
    struct Track {
        struct Segment {
            var start: Double
            var end: Double
            var points: [Pose]
            var ease: Ease
        }

        private(set) var segments: [Segment] = []
        private(set) var last: Pose
        private let first: Pose

        init(_ pose: Pose) {
            first = pose
            last = pose
        }

        var isStill: Bool { segments.isEmpty }
        var end: Double { segments.map(\.end).max() ?? 0 }

        @discardableResult
        mutating func add(_ start: Double, _ end: Double, _ points: [Pose], _ ease: Ease = .smooth) -> Double {
            segments.append(Segment(start: start, end: max(end, start + 0.001), points: [last] + points, ease: ease))
            last = points.last ?? last
            return end
        }

        func at(_ t: Double) -> Pose {
            var pose = first
            for segment in segments {
                if t < segment.start { break }
                if t >= segment.end {
                    pose = segment.points[segment.points.count - 1]
                    continue
                }
                let x = segment.ease((t - segment.start) / (segment.end - segment.start)) * Double(segment.points.count - 1)
                let i = min(Int(x), segment.points.count - 2)
                let f = x - Double(i)
                let a = segment.points[i], b = segment.points[i + 1]
                return Pose(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, a.scale + (b.scale - a.scale) * f)
            }
            return pose
        }
    }

    enum JobKind: CaseIterable {
        case knock, nudge, carry, shift, swap, heal, relocate, wander
    }

    /// One planned job: every block's and elf's track from time 0 (the job's
    /// start) to `duration`. Indices match `blocks` and `elves`.
    struct Job {
        let kind: JobKind
        let duration: Double
        let blockTracks: [Track]
        let elfTracks: [Track]

        /// Blocks drawn off every slot at time `t`.
        func blocksAway(at t: Double) -> Int {
            blockTracks.count { LivingPiPlanner.isAway(track: $0, at: t) }
        }
    }

    struct Block {
        var cell: Cell
        let tint: Tint
    }

    // MARK: The icon

    static let gridSize = 9
    static let maxAway = 2
    /// The π as the icon draws it: slot → original tint.
    static let slots: [(Cell, Tint)] = [
        (Cell(col: 1, row: 1), .amber), (Cell(col: 2, row: 1), .red), (Cell(col: 3, row: 1), .blue),
        (Cell(col: 4, row: 1), .ink), (Cell(col: 5, row: 1), .ink), (Cell(col: 6, row: 1), .sky),
        (Cell(col: 2, row: 2), .ink), (Cell(col: 2, row: 3), .ink), (Cell(col: 2, row: 4), .periwinkle),
        (Cell(col: 2, row: 5), .ink), (Cell(col: 2, row: 6), .ink),
        (Cell(col: 5, row: 2), .ink), (Cell(col: 5, row: 4), .ink), (Cell(col: 5, row: 5), .lavender),
        (Cell(col: 5, row: 6), .ink), (Cell(col: 6, row: 6), .ink),
    ]
    static let slotCells = Set(slots.map(\.0))
    /// Inside the arch, the right leg's gap and the cell beside it, and the
    /// two cells under the arch.
    static let noPark: Set<Cell> = {
        var cells: Set<Cell> = [Cell(col: 5, row: 3), Cell(col: 6, row: 3), Cell(col: 3, row: 7), Cell(col: 4, row: 7)]
        for col in 3...4 { for row in 2...6 { cells.insert(Cell(col: col, row: row)) } }
        return cells
    }()

    private static let grid: [Cell] = (0..<gridSize).flatMap { row in (0..<gridSize).map { Cell(col: $0, row: row) } }
    private static let directions = [Cell(col: 1, row: 0), Cell(col: -1, row: 0), Cell(col: 0, row: 1), Cell(col: 0, row: -1)]
    private static let elfStarts = [Cell(col: 4, row: 0), Cell(col: 4, row: 7)]
    private static let walkSpeed = 5.8
    private static let strollSpeed = 3.5
    private static let pushSeconds = 0.28
    private static let pullSeconds = 0.38
    private static let lean = 0.28
    private static let weights: [[(JobKind, Double)]] = [
        [(.knock, 2), (.nudge, 3), (.carry, 2), (.shift, 1.5), (.swap, 1.5), (.wander, 1.5)],
        [(.heal, 3), (.knock, 1), (.nudge, 1.5), (.carry, 1), (.relocate, 1.5), (.wander, 1.5)],
        [(.heal, 4), (.relocate, 1.5), (.wander, 1.5)],
    ]
    /// The view draws at 20 fps; the rehearsal checks every frame it will show.
    static let frameInterval = 1.0 / 20

    // MARK: State

    private(set) var blocks: [Block]
    private(set) var elves: [Cell]
    private var rng: Generator
    // A job's tracks while it is planned; reset at the start of each job.
    private var blockTracks: [Track] = []
    private var elfTracks: [Track] = []

    init(seed: UInt64) {
        blocks = Self.slots.map { Block(cell: $0.0, tint: $0.1) }
        elves = Self.elfStarts
        rng = Generator(seed: seed)
    }

    var awayCount: Int { blocks.count { !Self.slotCells.contains($0.cell) } }

    /// A rest between jobs: 2–6 s.
    mutating func rest() -> Double { rng.uniform(2, 6) }

    /// Plans one job from the current state and moves the state to its end,
    /// or returns nil when no job fits (the elves rest).
    mutating func nextJob() -> Job? {
        let weighted = Self.weights[awayCount]
        for _ in 0..<8 {
            let kind = rng.weighted(weighted)
            if let job = run(kind) { return job }
        }
        return nil
    }

    /// Tries a job up to 20 times on a copy; keeps the first rehearsal that
    /// keeps every rule. A failed try still advances the random generator.
    private mutating func run(_ kind: JobKind) -> Job? {
        for _ in 0..<20 {
            var trial = self
            trial.blockTracks = blocks.map { Track(Pose($0.cell)) }
            trial.elfTracks = elves.map { Track(Pose($0)) }
            do {
                let end = try trial.perform(kind)
                let duration = max(end, (trial.blockTracks + trial.elfTracks).map(\.end).max() ?? 0)
                let job = Job(kind: kind, duration: duration, blockTracks: trial.blockTracks, elfTracks: trial.elfTracks)
                guard trial.isLegal, Self.peakAway(job) <= Self.maxAway else { throw JobFailed() }
                trial.blockTracks = []
                trial.elfTracks = []
                self = trial
                return job
            } catch {
                rng = trial.rng
            }
        }
        return nil
    }

    /// The end state keeps the rules: no more than the limit out, none parked
    /// under the arch, and every actor on its own cell of the grid.
    private var isLegal: Bool {
        let away = blocks.filter { !Self.slotCells.contains($0.cell) }
        let cells = blocks.map(\.cell) + elves
        return away.count <= Self.maxAway
            && !away.contains { Self.noPark.contains($0.cell) }
            && Set(cells).count == cells.count
            && cells.allSatisfy(Self.inGrid)
    }

    static func isAway(track: Track, at t: Double) -> Bool {
        let pose = track.at(t)
        return !slots.contains { hypot(pose.x - Double($0.0.col), pose.y - Double($0.0.row)) <= 0.05 }
    }

    private static func peakAway(_ job: Job) -> Int {
        let frames = Int((job.duration / frameInterval).rounded(.up))
        return (0...frames).map { job.blocksAway(at: Double($0) * frameInterval) }.max() ?? 0
    }

    private mutating func perform(_ kind: JobKind) throws -> Double {
        switch kind {
        case .knock: try knock()
        case .nudge: try nudge()
        case .carry: try carry()
        case .shift: try shift()
        case .swap: try swap()
        case .heal: try heal()
        case .relocate: try relocate()
        case .wander: try wander()
        }
    }

    // MARK: Occupancy

    private static func inGrid(_ p: Cell) -> Bool { (0..<gridSize).contains(p.col) && (0..<gridSize).contains(p.row) }

    private func solid(exceptElf: Int? = nil, exceptBlock: Int? = nil) -> Set<Cell> {
        var cells = Set<Cell>()
        for (i, block) in blocks.enumerated() where i != exceptBlock { cells.insert(block.cell) }
        for (i, elf) in elves.enumerated() where i != exceptElf { cells.insert(elf) }
        return cells
    }

    /// The working elf steps out of the way first, so its cell counts as free.
    private func isFree(forBlock b: Int, _ p: Cell, worker: Int? = nil) -> Bool {
        Self.inGrid(p) && !solid(exceptElf: worker, exceptBlock: b).contains(p)
    }

    private func isParkable(_ b: Int, _ p: Cell) -> Bool {
        !Self.slotCells.contains(p) && !Self.noPark.contains(p) && isFree(forBlock: b, p)
    }

    /// Directions `b` can be pushed `n` cells: room ahead, and room behind for
    /// the elf to stand.
    private func openDirections(_ b: Int, _ n: Int = 1) -> [Cell] {
        Self.directions.filter { d in
            (-1...n).allSatisfy { k in k == 0 || isFree(forBlock: b, blocks[b].cell.step(d, k)) }
        }
    }

    private var homeBlocks: [Int] { blocks.indices.filter { Self.slotCells.contains(blocks[$0].cell) } }
    private var awayBlocks: [Int] { blocks.indices.filter { !Self.slotCells.contains(blocks[$0].cell) } }

    private mutating func pickElf(near p: Cell) -> Int {
        let keys = elves.map { Double($0.distance(to: p)) + rng.unit() }
        return keys[0] <= keys[1] ? 0 : 1
    }

    // MARK: Moves (each advances its actors' tracks and returns its end time)

    private mutating func walk(_ e: Int, to goals: Set<Cell>, from t0: Double, speed: Double = walkSpeed) throws -> Double {
        if goals.contains(elves[e]) { return t0 }
        let walkable = Set(Self.grid).subtracting(solid(exceptElf: e))
        let targets = goals.intersection(walkable)
        guard !targets.isEmpty, let path = Self.path(from: elves[e], to: targets, through: walkable) else { throw JobFailed() }
        let duration = max(0.22, Double(path.count - 1) / speed)
        elfTracks[e].add(t0, t0 + duration, path.dropFirst().map { Pose($0) })
        elves[e] = path[path.count - 1]
        return t0 + duration
    }

    private static func path(from start: Cell, to goals: Set<Cell>, through walkable: Set<Cell>) -> [Cell]? {
        var previous: [Cell: Cell] = [:]
        var seen: Set<Cell> = [start]
        var queue = [start]
        var head = 0
        while head < queue.count {
            let p = queue[head]
            head += 1
            if goals.contains(p) {
                var path = [p]
                while let q = previous[path[path.count - 1]] { path.append(q) }
                return path.reversed()
            }
            for d in directions {
                let n = p + d
                if walkable.contains(n), seen.insert(n).inserted {
                    previous[n] = p
                    queue.append(n)
                }
            }
        }
        return nil
    }

    /// The elf gets behind `b`, leans in, and pushes it `n` cells along `d`.
    private mutating func push(_ e: Int, _ b: Int, _ d: Cell, _ n: Int, from t0: Double) throws -> Double {
        for k in 1...n where !isFree(forBlock: b, blocks[b].cell.step(d, k), worker: e) { throw JobFailed() }
        var t = try walk(e, to: [blocks[b].cell.step(d, -1)], from: t0)
        func lean(_ p: Cell) -> Pose {
            Pose(Double(p.col) - Double(d.col) * (1 - Self.lean), Double(p.row) - Double(d.row) * (1 - Self.lean), 1.15)
        }
        t = elfTracks[e].add(t, t + 0.14, [lean(blocks[b].cell)])
        let cells = (1...n).map { blocks[b].cell.step(d, $0) }
        let duration = Self.pushSeconds * Double(n)
        blockTracks[b].add(t, t + duration, cells.map { Pose($0) })
        t = elfTracks[e].add(t, t + duration, cells.map(lean))
        blocks[b].cell = cells[cells.count - 1]
        elves[e] = blocks[b].cell.step(d, -1)
        return elfTracks[e].add(t, t + 0.14, [Pose(elves[e])])
    }

    /// The elf gets ahead of `b`, grips it, and walks backwards `n` cells
    /// along `d`, dragging it: how a block gets into a slot with no room
    /// behind it.
    private mutating func pull(_ e: Int, _ b: Int, _ d: Cell, _ n: Int, from t0: Double) throws -> Double {
        for k in 1...(n + 1) where !isFree(forBlock: b, blocks[b].cell.step(d, k), worker: e) { throw JobFailed() }
        var t = try walk(e, to: [blocks[b].cell.step(d)], from: t0)
        func grip(_ p: Cell) -> Pose {
            Pose(Double(p.col) + Double(d.col) * (1 - Self.lean), Double(p.row) + Double(d.row) * (1 - Self.lean), 1.15)
        }
        t = elfTracks[e].add(t, t + 0.16, [grip(blocks[b].cell)])
        let cells = (1...n).map { blocks[b].cell.step(d, $0) }
        let duration = Self.pullSeconds * Double(n)
        blockTracks[b].add(t, t + duration, cells.map { Pose($0) })
        t = elfTracks[e].add(t, t + duration, cells.map(grip))
        blocks[b].cell = cells[cells.count - 1]
        elves[e] = blocks[b].cell.step(d)
        return elfTracks[e].add(t, t + 0.14, [Pose(elves[e])])
    }

    private enum Move: Equatable {
        case push(Cell)
        case pull(Cell)
    }

    /// The shortest push/pull route for `b` to `goal`: a step along `d` needs
    /// the cell ahead free, plus the cell behind (push) or the cell beyond
    /// (pull) for the elf. Pushes are tried first.
    private func route(_ b: Int, to goal: Cell, worker: Int) throws -> [Move] {
        let solid = solid(exceptElf: worker, exceptBlock: b)
        func isOpen(_ p: Cell) -> Bool { Self.inGrid(p) && !solid.contains(p) }
        let start = blocks[b].cell
        var previous: [Cell: (Cell, Move)] = [:]
        var seen: Set<Cell> = [start]
        var queue = [start]
        var head = 0
        while head < queue.count {
            var p = queue[head]
            head += 1
            if p == goal {
                var moves: [Move] = []
                while let step = previous[p] {
                    moves.append(step.1)
                    p = step.0
                }
                return moves.reversed()
            }
            for pushes in [true, false] {
                for d in Self.directions {
                    let next = p + d
                    let elfCell = pushes ? p.step(d, -1) : p.step(d, 2)
                    if isOpen(next), isOpen(elfCell), seen.insert(next).inserted {
                        previous[next] = (p, pushes ? .push(d) : .pull(d))
                        queue.append(next)
                    }
                }
            }
        }
        throw JobFailed()
    }

    private mutating func work(_ e: Int, _ b: Int, to goal: Cell, from t0: Double) throws -> Double {
        let moves = try route(b, to: goal, worker: e)
        var t = t0
        var i = 0
        while i < moves.count {
            var j = i
            while j < moves.count, moves[j] == moves[i] { j += 1 }
            switch moves[i] {
            case let .push(d): t = try push(e, b, d, j - i, from: t)
            case let .pull(d): t = try pull(e, b, d, j - i, from: t)
            }
            i = j
        }
        return t
    }

    private static func neighbours(_ p: Cell) -> Set<Cell> { Set(directions.map { p + $0 }) }

    // MARK: Jobs that take a block out

    /// An elf shoves a slotted block one or two cells out; it stays there.
    private mutating func nudge() throws -> Double {
        let b = try rng.choice(homeBlocks)
        let n = try rng.choice([1, 1, 2])
        let d = try rng.choice(openDirections(b, n).filter { isParkable(b, blocks[b].cell.step($0, n)) })
        return try push(pickElf(near: blocks[b].cell), b, d, n, from: 0)
    }

    /// An elf bumps a block, it slides off and stays; the elf goes to look.
    private mutating func knock() throws -> Double {
        let b = try rng.choice(homeBlocks)
        let n = try rng.choice([2, 3])
        let d = try rng.choice(openDirections(b, n).filter { isParkable(b, blocks[b].cell.step($0, n)) })
        let e = pickElf(near: blocks[b].cell)
        let behind = blocks[b].cell.step(d, -1)
        var t = try walk(e, to: [behind], from: 0)
        let bump = Pose(Double(behind.col) + Double(d.col) * 0.35, Double(behind.row) + Double(d.row) * 0.35, 1.2)
        t = elfTracks[e].add(t, t + 0.1, [bump], .linear)
        let cells = (1...n).map { blocks[b].cell.step(d, $0) }
        let slide = 0.16 + 0.13 * Double(n)
        blockTracks[b].add(t, t + slide, cells.map { Pose($0) }, .easeOut)
        elfTracks[e].add(t, t + 0.19, [Pose(behind)])
        blocks[b].cell = cells[cells.count - 1]
        t += slide + rng.uniform(0.25, 0.45)
        return try walk(e, to: Self.neighbours(blocks[b].cell), from: t)
    }

    /// Both elves flank a slotted block, lift it, carry it one or two cells
    /// out and set it down.
    private mutating func carry() throws -> Double {
        let b = try rng.choice(homeBlocks)
        let d = try rng.choice(Self.directions)
        let side = Cell(col: d.row, row: d.col)
        let n = try rng.choice([1, 2])
        let home = blocks[b].cell
        let others = Set(blocks.indices.filter { $0 != b }.map { blocks[$0].cell })
        func isOpen(_ p: Cell) -> Bool { Self.inGrid(p) && !others.contains(p) }
        for k in 0...n {
            guard isOpen(home.step(side).step(d, k)), isOpen(home.step(side, -1).step(d, k)) else { throw JobFailed() }
            if k > 0, !isOpen(home.step(d, k)) { throw JobFailed() }
        }
        var spots = [home.step(side), home.step(side, -1)]
        if elves[0].distance(to: spots[1]) < elves[0].distance(to: spots[0]) { spots.reverse() }
        let t0 = try walk(0, to: [spots[0]], from: 0)
        let t1 = try walk(1, to: [spots[1]], from: 0.19)
        let signs = spots.map { $0 == home.step(side) ? 1.0 : -1.0 }
        func lean(_ p: Cell, _ sign: Double, _ scale: Double) -> Pose {
            Pose(Double(p.col) + Double(side.col) * sign * (1 - Self.lean), Double(p.row) + Double(side.row) * sign * (1 - Self.lean), scale)
        }
        func lift(_ t: Double, _ p: Cell, up: Bool) -> Double {
            blockTracks[b].add(t, t + 0.22, [Pose(p, up ? 1.12 : 1)])
            for e in 0..<2 { elfTracks[e].add(t, t + 0.22, [lean(p, signs[e], up ? 1.15 : 1)]) }
            return t + 0.22
        }
        let out = home.step(d, n)
        var t = lift(max(t0, t1) + 0.06, home, up: true)
        let path = (1...n).map { home.step(d, $0) }
        let duration = 0.47 * Double(n)
        blockTracks[b].add(t, t + duration, path.map { Pose($0, 1.12) })
        for e in 0..<2 { elfTracks[e].add(t, t + duration, path.map { lean($0, signs[e], 1.15) }) }
        t = lift(t + duration, out, up: false)
        blocks[b].cell = out
        for e in 0..<2 {
            elves[e] = spots[e].step(d, n)
            elfTracks[e].add(t, t + 0.16, [Pose(elves[e])])
        }
        return t + 0.16
    }

    /// Two slotted neighbours get shoved one cell crooked, and stay crooked.
    private mutating func shift() throws -> Double {
        let home = homeBlocks
        let byCell = Dictionary(uniqueKeysWithValues: home.map { (blocks[$0].cell, $0) })
        let pairs = home.flatMap { b in
            [Cell(col: 1, row: 0), Cell(col: 0, row: 1)].compactMap { a in byCell[blocks[b].cell + a].map { (b, $0) } }
        }
        let (b1, b2) = try rng.choice(pairs)
        let along = Cell(col: blocks[b2].cell.col - blocks[b1].cell.col, row: blocks[b2].cell.row - blocks[b1].cell.row)
        let open1 = openDirections(b1), open2 = openDirections(b2)
        let d = try rng.choice([Cell(col: along.row, row: along.col), Cell(col: -along.row, row: -along.col)].filter {
            open1.contains($0) && open2.contains($0)
                && isParkable(b1, blocks[b1].cell + $0) && isParkable(b2, blocks[b2].cell + $0)
        })
        let first = pickElf(near: blocks[b1].cell)
        let t = try push(first, b1, d, 1, from: 0)
        return try push(1 - first, b2, d, 1, from: t - 0.19)
    }

    // MARK: Jobs that keep or lower the count

    /// An elf works a loose block into the nearest (or second nearest) empty slot.
    private mutating func heal() throws -> Double {
        let b = try rng.choice(awayBlocks)
        let taken = Set(blocks.map(\.cell))
        let empty = Self.slots.map(\.0).filter { !taken.contains($0) }
        let keyed = empty.map { ($0, Double($0.distance(to: blocks[b].cell)) + rng.unit()) }
        let sorted = keyed.sorted { $0.1 < $1.1 }.map(\.0)
        let slot = rng.unit() < 0.75 || sorted.count == 1 ? sorted[0] : sorted[1]
        return try work(pickElf(near: blocks[b].cell), b, to: slot, from: 0)
    }

    /// An elf pushes a loose block somewhere else nearby, still off a slot.
    private mutating func relocate() throws -> Double {
        let b = try rng.choice(awayBlocks)
        let n = try rng.choice([1, 2])
        let d = try rng.choice(openDirections(b, n).filter { isParkable(b, blocks[b].cell.step($0, n)) })
        return try push(pickElf(near: blocks[b].cell), b, d, n, from: 0)
    }

    /// Do-si-do: each elf grips one of two neighbouring slotted blocks of
    /// different tints; both lift, pass each other, and land in each other's
    /// slot. Only when no block is out, since both are off a slot mid-pass.
    private mutating func swap() throws -> Double {
        guard awayCount == 0 else { throw JobFailed() }
        let pairs = blocks.indices.flatMap { x in
            blocks.indices.compactMap { y in
                x != y && blocks[x].tint != blocks[y].tint && blocks[x].cell.distance(to: blocks[y].cell) == 1 ? (x, y) : nil
            }
        }
        let (b1, b2) = try rng.choice(pairs)
        let h1 = blocks[b1].cell, h2 = blocks[b2].cell
        let e1 = pickElf(near: h1)
        let along = Cell(col: h2.col - h1.col, row: h2.row - h1.row)
        let side = try rng.choice([Cell(col: along.row, row: along.col), Cell(col: -along.row, row: -along.col)])
        var start = 0.0
        var ends: [Double] = []
        var grips: [Cell] = []
        for (e, b) in [(e1, b1), (1 - e1, b2)] {
            ends.append(try walk(e, to: Self.neighbours(blocks[b].cell).subtracting([h1, h2]), from: start))
            start += 0.19
            grips.append(Cell(col: elves[e].col - blocks[b].cell.col, row: elves[e].row - blocks[b].cell.row))
        }
        var t = ends.max() ?? 0
        let midX = Double(h1.col + h2.col) / 2, midY = Double(h1.row + h2.row) / 2
        let movers = [(e1, b1, grips[0], 1.0, h2), (1 - e1, b2, grips[1], -1.0, h1)]
        func hold(_ p: Pose, _ g: Cell) -> Pose {
            Pose(p.x + Double(g.col) * (1 - Self.lean), p.y + Double(g.row) * (1 - Self.lean), 1.15)
        }
        for (e, b, g, _, _) in movers {
            elfTracks[e].add(t, t + 0.19, [hold(Pose(blocks[b].cell), g)])
            blockTracks[b].add(t + 0.09, t + 0.28, [Pose(blocks[b].cell, 1.12)])
        }
        t += 0.31
        for (e, b, g, sign, dest) in movers {
            let via = Pose(midX + Double(side.col) * 0.32 * sign, midY + Double(side.row) * 0.32 * sign, 1.12)
            blockTracks[b].add(t, t + 0.81, [via, Pose(dest, 1.12)])
            elfTracks[e].add(t, t + 0.81, [hold(via, g), hold(Pose(dest), g)])
        }
        t += 0.81
        for (_, b, _, _, dest) in movers {
            blockTracks[b].add(t, t + 0.19, [Pose(dest)])
            blocks[b].cell = dest
        }
        t += 0.19
        for (e, _, g, _, dest) in movers {
            elves[e] = dest + g
            let taken = solid(exceptElf: e)
            if taken.contains(elves[e]) || !Self.inGrid(elves[e]) {
                let at = elfTracks[e].last
                func gap(_ p: Cell) -> Double { hypot(Double(p.col) - at.x, Double(p.row) - at.y) }
                guard let nearest = Self.grid.filter({ !taken.contains($0) }).min(by: { gap($0) < gap($1) }) else {
                    throw JobFailed()
                }
                elves[e] = nearest
            }
            elfTracks[e].add(t, t + 0.19, [Pose(elves[e])])
        }
        return t + 0.19
    }

    /// No work: one elf strolls somewhere, and half the time the other walks
    /// over to meet it.
    private mutating func wander() throws -> Double {
        let e = try rng.choice([0, 1])
        let taken = solid()
        let far = Self.grid.filter { !taken.contains($0) && $0.distance(to: elves[e]) >= 3 }
        var t = try walk(e, to: [rng.choice(far)], from: 0, speed: Self.strollSpeed)
        if rng.unit() < 0.5 {
            t = max(t, try walk(1 - e, to: Self.neighbours(elves[e]), from: 0.38, speed: Self.strollSpeed))
        }
        return t
    }

    private struct JobFailed: Error {}

    /// SplitMix64: small, fast, and the same sequence for the same seed.
    private struct Generator {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Uniform in [0, 1).
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

        mutating func uniform(_ low: Double, _ high: Double) -> Double { low + (high - low) * unit() }

        mutating func choice<T>(_ items: [T]) throws -> T {
            guard !items.isEmpty else { throw JobFailed() }
            return items[min(Int(unit() * Double(items.count)), items.count - 1)]
        }

        mutating func weighted<T>(_ items: [(T, Double)]) -> T {
            var x = unit() * items.reduce(0) { $0 + $1.1 }
            for (item, weight) in items {
                if x < weight { return item }
                x -= weight
            }
            return items[items.count - 1].0
        }
    }
}
