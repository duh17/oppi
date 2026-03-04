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

    @MainActor
    @Test func cappedToolOutputNoOpBatchesDoNotMutateVisibleState() {
        let reducer = TimelineReducer()
        let toolID = "tool-cap"

        reducer.processBatch([
            .agentStart(sessionId: "s1"),
            .toolStart(sessionId: "s1", toolEventId: toolID, tool: "read", args: [:]),
        ])

        let huge = String(repeating: "x", count: ToolOutputStore.perItemCap + 512)
        reducer.processBatch([
            .toolOutput(sessionId: "s1", toolEventId: toolID, output: huge, isError: false),
        ])

        let baselineVersion = reducer.renderVersion
        let baselineSnapshot = snapshot(of: reducer)

        reducer.processBatch([
            .toolOutput(sessionId: "s1", toolEventId: toolID, output: "", isError: false),
            .toolOutput(sessionId: "s1", toolEventId: toolID, output: "ignored-after-cap", isError: false),
        ])

        #expect(reducer.renderVersion == baselineVersion)
        #expect(snapshot(of: reducer) == baselineSnapshot)
    }

    @MainActor
    @Test func replayingNonDeltaBatchBumpsRenderVersionOnlyOnFirstPass() {
        let reducer = TimelineReducer()
        let batch: [AgentEvent] = [
            .toolStart(
                sessionId: "s1",
                toolEventId: "tool-replay",
                tool: "bash",
                args: ["command": "pwd"]
            ),
        ]

        let baselineVersion = reducer.renderVersion
        reducer.processBatch(batch)

        let versionAfterFirstPass = reducer.renderVersion
        #expect(versionAfterFirstPass == baselineVersion + 1)

        let baselineSnapshot = snapshot(of: reducer)
        reducer.processBatch(batch)

        #expect(reducer.renderVersion == versionAfterFirstPass)
        #expect(snapshot(of: reducer) == baselineSnapshot)
    }

    @MainActor
    @Test func reconnectReplayMaintainsSingleToolIdentityAndTerminalInvariants() {
        for terminalEvent in deterministicTerminalEvents() {
            let reducer = TimelineReducer()

            reducer.processBatch([
                .agentStart(sessionId: "s1"),
                .thinkingDelta(sessionId: "s1", delta: "plan"),
                .textDelta(sessionId: "s1", delta: "before "),
                .toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]),
                .toolOutput(sessionId: "s1", toolEventId: "t1", output: "ok\n", isError: false),
                .toolEnd(sessionId: "s1", toolEventId: "t1"),
                .textDelta(sessionId: "s1", delta: "after"),
                terminalEvent,
            ])

            // Simulate replay after reconnect: duplicate tool_start + message_end.
            reducer.processBatch([
                .agentStart(sessionId: "s1"),
                .toolStart(sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]),
                .toolEnd(sessionId: "s1", toolEventId: "t1"),
                .messageEnd(sessionId: "s1", content: "after"),
                .agentEnd(sessionId: "s1"),
            ])

            let toolItems = reducer.items.compactMap { item -> (id: String, isDone: Bool)? in
                guard case .toolCall(let id, _, _, _, _, _, let isDone) = item else { return nil }
                return (id: id, isDone: isDone)
            }

            #expect(toolItems.filter { $0.id == "t1" }.count == 1)
            #expect(toolItems.allSatisfy { $0.isDone })
            #expect(reducer.streamingAssistantID == nil)

            let unfinishedThinking = reducer.items.contains { item in
                guard case .thinking(_, _, _, let isDone) = item else { return false }
                return !isDone
            }
            #expect(!unfinishedThinking)
        }
    }

    @MainActor
    @Test func partitionedProcessBatchMatchesSequentialProcessingContracts() {
        let events = makeSeededBatches(seed: 0xA11CE, count: 40).flatMap { $0 }

        let sequential = TimelineReducer()
        for event in events {
            sequential.process(event)
        }

        let chunked = TimelineReducer()
        for chunk in chunkEvents(events, widths: [1, 4, 2, 3, 5]) {
            chunked.processBatch(chunk)
        }

        #expect(itemSignatures(chunked.items) == itemSignatures(sequential.items))
        #expect(snapshot(of: chunked).toolOutputsByVisibleToolID == snapshot(of: sequential).toolOutputsByVisibleToolID)
    }

    @Test func timelineHotPathComplexityBudgets() throws {
        for budget in timelineComplexityBudgets {
            let metrics = try sourceMetrics(for: budget.path)
            #expect(
                metrics.lines <= budget.maxLines,
                "\(budget.path) grew to \(metrics.lines) lines (budget \(budget.maxLines))"
            )
            #expect(
                metrics.cyclomaticDisableCount <= budget.maxCyclomaticDisables,
                "\(budget.path) has \(metrics.cyclomaticDisableCount) cyclomatic disables (budget \(budget.maxCyclomaticDisables))"
            )
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

private func deterministicTerminalEvents() -> [AgentEvent] {
    [
        .agentEnd(sessionId: "s1"),
        .sessionEnded(sessionId: "s1", reason: "disconnect"),
    ]
}

private struct TimelineComplexityBudget {
    let path: String
    let maxLines: Int
    let maxCyclomaticDisables: Int
}

private let timelineComplexityBudgets: [TimelineComplexityBudget] = [
    .init(
        path: "ios/Oppi/Core/Runtime/TimelineReducer.swift",
        maxLines: 1_150,
        maxCyclomaticDisables: 1
    ),
    .init(
        path: "ios/Oppi/Features/Chat/Output/ToolPresentationBuilder.swift",
        maxLines: 620,
        maxCyclomaticDisables: 0
    ),
    .init(
        path: "ios/Oppi/Features/Chat/Timeline/ToolTimelineRowContent.swift",
        maxLines: 1_731,
        maxCyclomaticDisables: 0
    ),
]

private struct SourceMetrics {
    let lines: Int
    let cyclomaticDisableCount: Int
}

private func sourceMetrics(for relativePath: String) throws -> SourceMetrics {
    let projectRoot = try findProjectRoot(startingFrom: URL(filePath: #filePath))
    let fileURL = projectRoot.appending(path: relativePath)
    let text = try String(contentsOf: fileURL, encoding: .utf8)

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
    let cyclomaticDisableCount = text
        .components(separatedBy: "cyclomatic_complexity")
        .count - 1

    return SourceMetrics(lines: lines, cyclomaticDisableCount: cyclomaticDisableCount)
}

private func findProjectRoot(startingFrom url: URL) throws -> URL {
    var candidate = url.deletingLastPathComponent()

    while candidate.path != "/" {
        let probe = candidate.appending(path: "ios/Oppi/Core/Runtime/TimelineReducer.swift")
        if FileManager.default.fileExists(atPath: probe.path) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }

    throw NSError(
        domain: "TimelineReducerInvariantTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not locate project root"]
    )
}

private func chunkEvents(_ events: [AgentEvent], widths: [Int]) -> [[AgentEvent]] {
    guard !widths.isEmpty else { return [events] }

    var chunks: [[AgentEvent]] = []
    chunks.reserveCapacity(events.count)

    var cursor = 0
    var widthIndex = 0
    while cursor < events.count {
        let width = max(1, widths[widthIndex % widths.count])
        let end = min(events.count, cursor + width)
        chunks.append(Array(events[cursor..<end]))
        cursor = end
        widthIndex += 1
    }

    return chunks
}

private enum ItemSignature: Equatable {
    case user(String)
    case assistant(String)
    case audio(String)
    case thinking(String, Bool)
    case tool(String, String, String, Bool, Bool)
    case permission(String)
    case permissionResolved(PermissionOutcome, String, String)
    case system(String)
    case error(String)
}

private func itemSignatures(_ items: [ChatItem]) -> [ItemSignature] {
    items.map { item in
        switch item {
        case .userMessage(_, let text, _, _):
            return .user(text)
        case .assistantMessage(_, let text, _):
            return .assistant(text)
        case .audioClip(_, let title, _, _):
            return .audio(title)
        case .thinking(_, let preview, _, let isDone):
            return .thinking(preview, isDone)
        case .toolCall(let id, let tool, _, let outputPreview, _, let isError, let isDone):
            return .tool(id, tool, outputPreview, isError, isDone)
        case .permission(let request):
            return .permission(request.id)
        case .permissionResolved(_, let outcome, let tool, let summary):
            return .permissionResolved(outcome, tool, summary)
        case .systemEvent(_, let message):
            return .system(message)
        case .error(_, let message):
            return .error(message)
        }
    }
}
