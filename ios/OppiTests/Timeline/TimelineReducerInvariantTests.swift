import Foundation
import Testing
@testable import Oppi

@Suite("TimelineReducer — Invariants")
struct TimelineReducerInvariantTests {

    @MainActor
    @Test func seededBatchesPreserveRenderAndIdentityInvariants() {
        let reducer = TimelineReducer()
        let batches = makeSeededBatches(seed: 0xC0FFEE, count: 120)

        for batch in batches {
            let beforeVersion = reducer.renderVersion
            let before = snapshot(of: reducer)

            reducer.processBatch(batch)

            let afterVersion = reducer.renderVersion
            let after = snapshot(of: reducer)

            #expect(afterVersion >= beforeVersion)
            if after != before {
                #expect(afterVersion > beforeVersion)
            }

            let ids = reducer.items.map(\.id)
            #expect(Set(ids).count == ids.count)

            let toolIDs = reducer.items.compactMap { item -> String? in
                guard case .toolCall(let id, _, _, _, _, _, _) = item else { return nil }
                return id
            }
            #expect(Set(toolIDs).count == toolIDs.count)
        }
    }

    @MainActor
    @Test func deterministicPermutationsKeepOrderingAndSingleToolRow() {
        for permutation in timelinePermutationCases() {
            let reducer = TimelineReducer()
            reducer.processBatch(permutation.events)

            let toolRows = reducer.items.enumerated().compactMap { index, item -> Int? in
                if case .toolCall = item { return index }
                return nil
            }
            #expect(toolRows.count <= 1, "\(permutation.name): expected <=1 tool row")

            guard let toolIndex = toolRows.first else {
                continue
            }

            let beforeTool = reducer.items[..<toolIndex]
            let afterTool = reducer.items.dropFirst(toolIndex + 1)

            let hasAssistantBefore = beforeTool.contains {
                if case .assistantMessage = $0 { return true }
                return false
            }
            let hasAssistantAfter = afterTool.contains {
                if case .assistantMessage = $0 { return true }
                return false
            }

            // If text is emitted both before and after tool execution,
            // reducer should preserve split chronology around the tool row.
            if permutation.expectAssistantSplitAroundTool {
                #expect(hasAssistantBefore, "\(permutation.name): missing assistant before tool")
                #expect(hasAssistantAfter, "\(permutation.name): missing assistant after tool")
            }
        }
    }
}

private struct ReducerSnapshot: Equatable {
    let items: [ChatItem]
    let toolOutputsByVisibleToolID: [String: String]
}

@MainActor
private func snapshot(of reducer: TimelineReducer) -> ReducerSnapshot {
    let toolIDs = reducer.items.compactMap { item -> String? in
        guard case .toolCall(let id, _, _, _, _, _, _) = item else { return nil }
        return id
    }

    var outputs: [String: String] = [:]
    for id in toolIDs {
        outputs[id] = reducer.toolOutputStore.fullOutput(for: id)
    }

    return ReducerSnapshot(items: reducer.items, toolOutputsByVisibleToolID: outputs)
}

private struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func nextInt(upperBound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(upperBound))
    }
}

private func makeSeededBatches(seed: UInt64, count: Int) -> [[AgentEvent]] {
    var rng = SeededRNG(seed: seed)
    let sessionId = "s-seeded"
    var nextTool = 0

    var turnOpen = false
    var openToolID: String?
    var batches: [[AgentEvent]] = []
    batches.reserveCapacity(count)

    for step in 0..<count {
        let batchSize = 1 + rng.nextInt(upperBound: 3)
        var batch: [AgentEvent] = []
        batch.reserveCapacity(batchSize)

        for _ in 0..<batchSize {
            switch rng.nextInt(upperBound: 11) {
            case 0:
                batch.append(.agentStart(sessionId: sessionId))
                turnOpen = true

            case 1:
                if turnOpen {
                    batch.append(.agentEnd(sessionId: sessionId))
                    turnOpen = false
                    openToolID = nil
                }

            case 2:
                if turnOpen {
                    batch.append(.thinkingDelta(sessionId: sessionId, delta: "t\(step)-\(rng.nextInt(upperBound: 10))"))
                }

            case 3:
                if turnOpen {
                    batch.append(.textDelta(sessionId: sessionId, delta: "a\(step)-\(rng.nextInt(upperBound: 10))"))
                }

            case 4:
                if turnOpen {
                    nextTool += 1
                    let toolID = "tool-\(nextTool)"
                    openToolID = toolID
                    batch.append(.toolStart(
                        sessionId: sessionId,
                        toolEventId: toolID,
                        tool: "bash",
                        args: ["command": .string("echo \(step)")]
                    ))
                }

            case 5:
                if let openToolID {
                    batch.append(.toolOutput(sessionId: sessionId, toolEventId: openToolID, output: "o\(step)\n", isError: false))
                }

            case 6:
                if let currentToolID = openToolID {
                    batch.append(.toolEnd(sessionId: sessionId, toolEventId: currentToolID))
                    openToolID = nil
                }

            case 7:
                if turnOpen {
                    batch.append(.messageEnd(sessionId: sessionId, content: "final-\(step)"))
                }

            case 8:
                batch.append(.thinkingDelta(sessionId: sessionId, delta: ""))

            case 9:
                if let openToolID {
                    batch.append(.toolOutput(sessionId: sessionId, toolEventId: openToolID, output: "", isError: false))
                }

            default:
                if turnOpen {
                    batch.append(.compactionStart(sessionId: sessionId, reason: "overflow"))
                }
            }
        }

        if batch.isEmpty {
            batch = [.thinkingDelta(sessionId: sessionId, delta: "")]
        }

        batches.append(batch)
    }

    return batches
}

private struct TimelinePermutationCase {
    let name: String
    let events: [AgentEvent]
    let expectAssistantSplitAroundTool: Bool
}

private func timelinePermutationCases() -> [TimelinePermutationCase] {
    let sessionId = "s-permute"

    return [
        TimelinePermutationCase(
            name: "text-before-and-after-tool",
            events: [
                .agentStart(sessionId: sessionId),
                .textDelta(sessionId: sessionId, delta: "before "),
                .toolStart(sessionId: sessionId, toolEventId: "t1", tool: "bash", args: [:]),
                .toolOutput(sessionId: sessionId, toolEventId: "t1", output: "ok\n", isError: false),
                .toolEnd(sessionId: sessionId, toolEventId: "t1"),
                .textDelta(sessionId: sessionId, delta: "after"),
                .agentEnd(sessionId: sessionId),
            ],
            expectAssistantSplitAroundTool: true
        ),
        TimelinePermutationCase(
            name: "thinking-before-tool",
            events: [
                .agentStart(sessionId: sessionId),
                .thinkingDelta(sessionId: sessionId, delta: "plan"),
                .toolStart(sessionId: sessionId, toolEventId: "t2", tool: "read", args: [:]),
                .toolEnd(sessionId: sessionId, toolEventId: "t2"),
                .messageEnd(sessionId: sessionId, content: "done"),
                .agentEnd(sessionId: sessionId),
            ],
            expectAssistantSplitAroundTool: false
        ),
        TimelinePermutationCase(
            name: "duplicate-tool-start-same-id",
            events: [
                .agentStart(sessionId: sessionId),
                .toolStart(sessionId: sessionId, toolEventId: "t3", tool: "bash", args: [:]),
                .toolStart(sessionId: sessionId, toolEventId: "t3", tool: "bash", args: [:]),
                .toolOutput(sessionId: sessionId, toolEventId: "t3", output: "x", isError: false),
                .toolEnd(sessionId: sessionId, toolEventId: "t3"),
                .agentEnd(sessionId: sessionId),
            ],
            expectAssistantSplitAroundTool: false
        ),
    ]
}
