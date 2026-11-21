import Foundation
import Testing
@testable import Oppi

/// The living π's rules over long seeded runs: the shape never loses more
/// than two blocks, never closes the arch, and every job's motion lands on
/// the state the next job starts from.
@Suite("Living π planner")
struct LivingPiPlannerTests {
    typealias Planner = LivingPiPlanner

    @Test("long seeded runs keep the π's rules at every frame and after every job", arguments: [1, 7, 42] as [UInt64])
    func longRunKeepsRules(seed: UInt64) {
        var planner = Planner(seed: seed)
        func tally(_ tints: [Planner.Tint]) -> [Planner.Tint: Int] { Dictionary(tints.map { ($0, 1) }, uniquingKeysWith: +) }
        let tints = tally(Planner.slots.map(\.1))
        var kinds = Set<Planner.JobKind>()
        var planned = 0
        for _ in 0..<400 {
            guard let job = planner.nextJob() else { continue }
            planned += 1
            kinds.insert(job.kind)

            // Mid-job, at every frame the view draws.
            let frames = Int((job.duration / Planner.frameInterval).rounded(.up))
            let peak = (0...frames).map { job.blocksAway(at: Double($0) * Planner.frameInterval) }.max() ?? 0
            #expect(peak <= Planner.maxAway, "\(job.kind) had \(peak) blocks off a slot mid-job")

            // At the end: a legal state the motion actually reaches.
            let away = planner.blocks.filter { !Planner.slotCells.contains($0.cell) }
            #expect(away.count <= Planner.maxAway)
            #expect(planner.awayCount == away.count)
            #expect(!away.contains { Planner.noPark.contains($0.cell) }, "\(job.kind) parked a block under the arch")
            let cells = planner.blocks.map(\.cell) + planner.elves
            #expect(Set(cells).count == cells.count, "\(job.kind) left two actors on one cell")
            #expect(cells.allSatisfy { (0..<Planner.gridSize).contains($0.col) && (0..<Planner.gridSize).contains($0.row) })
            #expect(tally(planner.blocks.map(\.tint)) == tints, "the π keeps its 16 blocks and their colours")
            for (track, block) in zip(job.blockTracks, planner.blocks) {
                #expect(track.at(job.duration) == Planner.Pose(block.cell), "\(job.kind) animates a block somewhere it is not")
            }
            for (track, elf) in zip(job.elfTracks, planner.elves) {
                #expect(track.at(job.duration) == Planner.Pose(elf), "\(job.kind) animates an elf somewhere it is not")
            }
        }
        #expect(planned >= 390, "the elves found work in \(planned) of 400 wakes")
        #expect(kinds == Set(Planner.JobKind.allCases), "jobs that never ran: \(Set(Planner.JobKind.allCases).subtracting(kinds))")
    }
}
