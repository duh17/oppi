// swiftlint:disable file_length
import Foundation
import Testing
import UIKit
@testable import Oppi

enum TimelineStreamingContentKind: CaseIterable, Sendable {
    case plain
    case markdown
    case code

    var name: String {
        switch self {
        case .plain: return "plain"
        case .markdown: return "markdown"
        case .code: return "code"
        }
    }

    func marker(for phase: TimelineStreamingPhase, token: String) -> String {
        "[\(name)-\(phase.name)-\(token)]"
    }

    func assistantDelta(for phase: TimelineStreamingPhase, token: String) -> String {
        let marker = marker(for: phase, token: token)

        switch self {
        case .plain:
            return "Plain streaming update \(marker). "

        case .markdown:
            return "## \(marker)\n\n- markdown bullet one\n- markdown bullet two\n\n`inline-code`"

        case .code:
            let function = "matrix_\(phase.name.replacingOccurrences(of: "-", with: "_"))"
            return "```swift\n// \(marker)\nfunc \(function)() {\n    print(\"\(marker)\")\n}\n```"
        }
    }

    func inToolSpec(token: String) -> TimelineStreamingToolSpec {
        switch self {
        case .plain:
            let outputA = "plain-tool-\(token)-line-1\n"
            let outputB = "plain-tool-\(token)-line-2\n"
            return TimelineStreamingToolSpec(
                tool: "bash",
                args: ["command": .string("printf '\(outputA)\(outputB)'")],
                outputChunks: [outputA, outputB],
                expectedExpandedContent: .bash
            )

        case .markdown:
            let markdown = "# Matrix \(token)\n\n- bullet\n\n```swift\nlet value = 42\n```\n"
            let splitIndex = markdown.index(markdown.startIndex, offsetBy: markdown.count / 2)
            let chunkA = String(markdown[..<splitIndex])
            let chunkB = String(markdown[splitIndex...])

            return TimelineStreamingToolSpec(
                tool: "read",
                args: [
                    "path": .string("Docs/\(token).md"),
                    "offset": .number(1),
                    "limit": .number(240),
                ],
                outputChunks: [chunkA, chunkB],
                expectedExpandedContent: .markdown
            )

        case .code:
            let code = "struct Matrix\(token.replacingOccurrences(of: "-", with: "_")) {\n    func run() -> Int {\n        42\n    }\n}\n"
            let splitIndex = code.index(code.startIndex, offsetBy: code.count / 2)
            let chunkA = String(code[..<splitIndex])
            let chunkB = String(code[splitIndex...])

            return TimelineStreamingToolSpec(
                tool: "read",
                args: [
                    "path": .string("Sources/\(token).swift"),
                    "offset": .number(1),
                    "limit": .number(260),
                ],
                outputChunks: [chunkA, chunkB],
                expectedExpandedContent: .code
            )
        }
    }
}

enum TimelineStreamingPhase: CaseIterable, Sendable {
    case preTool
    case inTool
    case postTool

    var name: String {
        switch self {
        case .preTool: return "pre-tool"
        case .inTool: return "in-tool"
        case .postTool: return "post-tool"
        }
    }
}

enum TimelineFollowAttachmentState: CaseIterable, Sendable {
    case attachedFollow
    case detachedFollow

    var name: String {
        switch self {
        case .attachedFollow: return "attached-follow"
        case .detachedFollow: return "detached-follow"
        }
    }
}

struct TimelineStreamingScrollMatrixCase: Sendable, CustomStringConvertible {
    let content: TimelineStreamingContentKind
    let phase: TimelineStreamingPhase
    let followState: TimelineFollowAttachmentState

    var name: String {
        "\(content.name)-\(phase.name)-\(followState.name)"
    }

    var description: String { name }

    static var allCases: [Self] {
        TimelineStreamingContentKind.allCases.flatMap { content in
            TimelineStreamingPhase.allCases.flatMap { phase in
                TimelineFollowAttachmentState.allCases.map { followState in
                    Self(
                        content: content,
                        phase: phase,
                        followState: followState
                    )
                }
            }
        }
    }
}

struct TimelineStreamingToolSpec {
    enum ExpandedContentKind {
        case bash
        case markdown
        case code
    }

    let tool: String
    let args: [String: JSONValue]
    let outputChunks: [String]
    let expectedExpandedContent: ExpandedContentKind
}

@MainActor
final class TimelineStreamingScrollScenarioRunner {
    let harness: WindowedTimelineHarness
    let sessionId: String
    let followState: TimelineFollowAttachmentState

    private var observedToolIDs: Set<String> = []

    init(
        sessionSuffix: String,
        followState: TimelineFollowAttachmentState,
        useAnchoredCollectionView: Bool = false
    ) {
        self.sessionId = "s-stream-scroll-matrix-\(sessionSuffix)"
        self.followState = followState
        self.harness = makeWindowedTimelineHarness(
            sessionId: sessionId,
            useAnchoredCollectionView: useAnchoredCollectionView
        )

        seedHistory()
        harness.applyReducerState(isBusy: false)
        settleTimelineLayout(harness.collectionView)
        prepareInitialFollowState()
        assertTimelineInvariants(step: "initial")
    }

    func runRound(
        content: TimelineStreamingContentKind,
        highlightPhase: TimelineStreamingPhase,
        toolEventID: String,
        token: String
    ) {
        observedToolIDs.insert(toolEventID)

        let preContent = contentForPhase(.preTool, highlightPhase: highlightPhase, selected: content)
        let inToolContent = contentForPhase(.inTool, highlightPhase: highlightPhase, selected: content)
        let postContent = contentForPhase(.postTool, highlightPhase: highlightPhase, selected: content)
        let toolSpec = inToolContent.inToolSpec(token: token)

        process(
            [.agentStart(sessionId: sessionId)],
            step: "\(token)-agent-start",
            isBusy: true
        )

        let preDelta = preContent.assistantDelta(for: .preTool, token: token)
        process(
            [.textDelta(sessionId: sessionId, delta: preDelta)],
            step: "\(token)-pre-tool-delta",
            isBusy: true
        )
        assertAssistantContains(marker: preContent.marker(for: .preTool, token: token), step: "\(token)-pre-tool")

        process(
            [
                .toolStart(
                    sessionId: sessionId,
                    toolEventId: toolEventID,
                    tool: toolSpec.tool,
                    args: toolSpec.args
                ),
            ],
            step: "\(token)-tool-start",
            isBusy: true
        )

        for (index, chunk) in toolSpec.outputChunks.enumerated() {
            process(
                [
                    .toolOutput(
                        sessionId: sessionId,
                        toolEventId: toolEventID,
                        output: chunk,
                        isError: false
                    ),
                ],
                step: "\(token)-tool-output-\(index)",
                isBusy: true
            )
        }

        assertToolExpandedContent(
            toolEventID: toolEventID,
            expected: toolSpec.expectedExpandedContent,
            step: "\(token)-tool-render"
        )

        process(
            [
                .toolOutput(
                    sessionId: sessionId,
                    toolEventId: toolEventID,
                    output: "",
                    isError: false
                ),
            ],
            step: "\(token)-no-op-output",
            isBusy: true,
            expectMutation: false
        )

        toggleToolExpansion(toolEventID: toolEventID, step: "\(token)-expand")
        toggleToolExpansion(toolEventID: toolEventID, step: "\(token)-collapse")

        process(
            [
                .toolEnd(sessionId: sessionId, toolEventId: toolEventID),
            ],
            step: "\(token)-tool-end",
            isBusy: true
        )

        let postDelta = postContent.assistantDelta(for: .postTool, token: token)
        process(
            [
                .textDelta(sessionId: sessionId, delta: postDelta),
                .messageEnd(sessionId: sessionId, content: postDelta),
                .agentEnd(sessionId: sessionId),
            ],
            step: "\(token)-post-tool",
            isBusy: false
        )
        assertAssistantContains(marker: postContent.marker(for: .postTool, token: token), step: "\(token)-post-tool")

        process(
            [
                .agentStart(sessionId: sessionId),
                .toolStart(
                    sessionId: sessionId,
                    toolEventId: toolEventID,
                    tool: toolSpec.tool,
                    args: toolSpec.args
                ),
                .toolEnd(sessionId: sessionId, toolEventId: toolEventID),
                .messageEnd(sessionId: sessionId, content: postDelta),
                .agentEnd(sessionId: sessionId),
            ],
            step: "\(token)-reconnect-replay",
            isBusy: false
        )

        #expect(
            timelineToolRowCount(for: toolEventID, in: harness.reducer.items) == 1,
            "\(token)-reconnect-replay: duplicate tool row detected for \(toolEventID)"
        )
    }

    func assertFollowTransitions(step: String) {
        switch followState {
        case .attachedFollow:
            #expect(harness.scrollController.isCurrentlyNearBottom, "\(step): expected attached follow")
            harness.scrollController.detachFromBottomForUserScroll()
            #expect(!harness.scrollController.isCurrentlyNearBottom, "\(step): detach failed")
            harness.scrollController.requestScrollToBottom()
            #expect(harness.scrollController.isCurrentlyNearBottom, "\(step): requestScrollToBottom failed")

        case .detachedFollow:
            #expect(!harness.scrollController.isCurrentlyNearBottom, "\(step): expected detached follow")
            harness.scrollController.requestScrollToBottom()
            #expect(harness.scrollController.isCurrentlyNearBottom, "\(step): requestScrollToBottom failed")
            harness.scrollController.detachFromBottomForUserScroll()
            #expect(!harness.scrollController.isCurrentlyNearBottom, "\(step): detach failed")
        }
    }

    // MARK: - Internal helpers

    private func process(
        _ events: [AgentEvent],
        step: String,
        isBusy: Bool,
        expectMutation: Bool? = nil,
        jumpTolerance: CGFloat = 8
    ) {
        let anchorBefore = harness.collectionView.contentOffset.y
        let versionBefore = harness.reducer.renderVersion

        harness.reducer.processBatch(events)
        harness.applyReducerState(isBusy: isBusy)
        settleTimelineLayout(harness.collectionView)

        if let expectMutation {
            let didMutate = harness.reducer.renderVersion > versionBefore
            #expect(didMutate == expectMutation, "\(step): renderVersion mutation mismatch")
        }

        if followState == .detachedFollow {
            let drift = abs(harness.collectionView.contentOffset.y - anchorBefore)
            #expect(drift < jumpTolerance, "\(step): detached offset jumped \(drift)pt")
            #expect(!harness.scrollController.isCurrentlyNearBottom, "\(step): detached follow unexpectedly attached")
        } else {
            #expect(harness.scrollController.isCurrentlyNearBottom, "\(step): attached follow unexpectedly detached")
        }

        assertTimelineInvariants(step: step)
    }

    private func toggleToolExpansion(toolEventID: String, step: String) {
        guard let itemIndex = harness.reducer.items.firstIndex(where: { $0.id == toolEventID }) else {
            Issue.record("\(step): missing tool row \(toolEventID)")
            return
        }

        let indexPath = IndexPath(item: itemIndex, section: 0)
        if harness.collectionView.cellForItem(at: indexPath) == nil {
            let position: UICollectionView.ScrollPosition = followState == .detachedFollow
                ? .centeredVertically
                : .bottom
            harness.collectionView.scrollToItem(at: indexPath, at: position, animated: false)
            settleTimelineLayout(harness.collectionView)
            if followState == .detachedFollow {
                harness.scrollController.detachFromBottomForUserScroll()
            }
        }

        let offsetBefore = harness.collectionView.contentOffset.y
        harness.coordinator.collectionView(harness.collectionView, didSelectItemAt: indexPath)
        settleTimelineLayout(harness.collectionView)

        if followState == .detachedFollow {
            let drift = abs(harness.collectionView.contentOffset.y - offsetBefore)
            #expect(drift < 8, "\(step): expansion drifted \(drift)pt")
            #expect(!harness.scrollController.isCurrentlyNearBottom, "\(step): detached follow unexpectedly attached")
        }

        assertTimelineInvariants(step: step)
    }

    private func assertAssistantContains(marker: String, step: String) {
        let containsMarker = harness.reducer.items.contains { item in
            guard case .assistantMessage(_, let text, _) = item else { return false }
            return text.contains(marker)
        }

        #expect(containsMarker, "\(step): assistant text missing marker \(marker)")
    }

    private func assertToolExpandedContent(
        toolEventID: String,
        expected: TimelineStreamingToolSpec.ExpandedContentKind,
        step: String
    ) {
        guard let toolItem = harness.reducer.items.first(where: { $0.id == toolEventID }) else {
            Issue.record("\(step): missing tool item \(toolEventID)")
            return
        }

        let wasExpanded = harness.reducer.expandedItemIDs.contains(toolEventID)
        harness.reducer.expandedItemIDs.insert(toolEventID)
        defer {
            if !wasExpanded {
                harness.reducer.expandedItemIDs.remove(toolEventID)
            }
        }

        guard let config = harness.coordinator.toolRowConfiguration(itemID: toolEventID, item: toolItem) else {
            Issue.record("\(step): missing tool configuration for \(toolEventID)")
            return
        }

        let isDone: Bool
        if case .toolCall(_, _, _, _, _, _, let done) = toolItem {
            isDone = done
        } else {
            Issue.record("\(step): expected tool row for \(toolEventID)")
            return
        }

        switch expected {
        case .bash:
            guard case .bash = config.expandedContent else {
                Issue.record("\(step): expected .bash expanded content")
                return
            }

        case .markdown:
            if isDone {
                guard case .markdown = config.expandedContent else {
                    Issue.record("\(step): expected .markdown expanded content")
                    return
                }
            } else {
                switch config.expandedContent {
                case .markdown, .text:
                    break
                default:
                    Issue.record("\(step): expected cheap markdown/source expanded content")
                    return
                }
            }

        case .code:
            guard case .code = config.expandedContent else {
                Issue.record("\(step): expected .code expanded content")
                return
            }
        }
    }

    private func assertTimelineInvariants(step: String) {
        let duplicateIDs = timelineDuplicateIDs(in: harness.reducer.items)
        #expect(duplicateIDs.isEmpty, "\(step): duplicate row IDs: \(duplicateIDs)")

        for toolID in observedToolIDs {
            #expect(
                timelineToolRowCount(for: toolID, in: harness.reducer.items) <= 1,
                "\(step): duplicate tool rows for \(toolID)"
            )
        }
    }

    private func contentForPhase(
        _ phase: TimelineStreamingPhase,
        highlightPhase: TimelineStreamingPhase,
        selected: TimelineStreamingContentKind
    ) -> TimelineStreamingContentKind {
        phase == highlightPhase ? selected : .plain
    }

    private func seedHistory(count: Int = 24) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let events = (0..<count).map { index in
            TraceEvent(
                id: "seed-history-\(index)",
                type: .assistant,
                timestamp: formatter.string(from: base.addingTimeInterval(Double(index))),
                text: String(repeating: "History \(index). ", count: 12),
                tool: nil,
                args: nil,
                output: nil,
                toolCallId: nil,
                toolName: nil,
                isError: nil,
                thinking: nil
            )
        }

        harness.reducer.loadSession(events)
    }

    private func prepareInitialFollowState() {
        let collectionView = harness.collectionView
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)

        collectionView.contentOffset.y = maxOffset
        settleTimelineLayout(collectionView)

        switch followState {
        case .attachedFollow:
            harness.scrollController.requestScrollToBottom()
            harness.scrollController.updateNearBottom(true)

        case .detachedFollow:
            collectionView.contentOffset.y = maxOffset * 0.5
            settleTimelineLayout(collectionView)
            harness.scrollController.detachFromBottomForUserScroll()
        }
    }
}
// swiftlint:enable file_length
