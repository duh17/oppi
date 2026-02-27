import Foundation
import Testing
import UIKit
@testable import Oppi

/// Tool families that render distinct expanded layouts in timeline rows.
enum ToolExpandScrollMatrixCase: CaseIterable, Sendable {
    case writeCode
    case readCode
    case bashOutput
    case editDiff
    case todoDiff
    case todoCard
    case rememberMarkdown
    case recallText
    case customText
    case plot
    case readMarkdown
    case readMedia

    var name: String {
        switch self {
        case .writeCode: return "write-code"
        case .readCode: return "read-code"
        case .bashOutput: return "bash-output"
        case .editDiff: return "edit-diff"
        case .todoDiff: return "todo-diff"
        case .todoCard: return "todo-card"
        case .rememberMarkdown: return "remember-markdown"
        case .recallText: return "recall-text"
        case .customText: return "custom-text"
        case .plot: return "plot"
        case .readMarkdown: return "read-markdown"
        case .readMedia: return "read-media"
        }
    }

    var targetItemID: String { "tc-tool-matrix-\(name)" }

    @MainActor
    func makeTimeline(
        toolArgsStore: ToolArgsStore,
        toolOutputStore: ToolOutputStore,
        toolSegmentStore: ToolSegmentStore
    ) -> [ChatItem] {
        var items: [ChatItem] = []

        for index in 0..<12 {
            items.append(Self.fillerAssistantMessage(id: "\(name)-pre-\(index)", seed: index))
        }

        items.append(makeTargetToolCall(
            itemID: targetItemID,
            toolArgsStore: toolArgsStore,
            toolOutputStore: toolOutputStore,
            toolSegmentStore: toolSegmentStore
        ))

        for index in 0..<12 {
            items.append(Self.fillerAssistantMessage(id: "\(name)-post-\(index)", seed: 100 + index))
        }

        return items
    }

    @MainActor
    private func makeTargetToolCall(
        itemID: String,
        toolArgsStore: ToolArgsStore,
        toolOutputStore: ToolOutputStore,
        toolSegmentStore: ToolSegmentStore
    ) -> ChatItem {
        switch self {
        case .writeCode:
            let path = "Sources/MatrixWrite.swift"
            let content = Self.sampleSwiftSource(functionPrefix: "matrixWrite", count: 32)
            let output = "Successfully wrote \(path)"

            toolArgsStore.set([
                "path": .string(path),
                "content": .string(content),
            ], for: itemID)
            toolOutputStore.append(output, to: itemID)

            return .toolCall(
                id: itemID,
                tool: "write",
                argsSummary: "write \(path)",
                outputPreview: output,
                outputByteCount: content.utf8.count,
                isError: false,
                isDone: true
            )

        case .readCode:
            let path = "Sources/MatrixRead.swift"
            let content = Self.sampleSwiftSource(functionPrefix: "matrixRead", count: 34)

            toolArgsStore.set([
                "path": .string(path),
                "offset": .number(1),
                "limit": .number(240),
            ], for: itemID)
            toolOutputStore.append(content, to: itemID)

            return .toolCall(
                id: itemID,
                tool: "read",
                argsSummary: "read \(path)",
                outputPreview: "import Foundation",
                outputByteCount: content.utf8.count,
                isError: false,
                isDone: true
            )

        case .bashOutput:
            let command = "for i in $(seq 1 120); do echo matrix-$i; done"
            let output = (1...120).map { "matrix-line-\($0)" }.joined(separator: "\n")

            toolArgsStore.set([
                "command": .string(command),
            ], for: itemID)
            toolOutputStore.append(output, to: itemID)

            return .toolCall(
                id: itemID,
                tool: "bash",
                argsSummary: "command: \(command)",
                outputPreview: "matrix-line-1",
                outputByteCount: output.utf8.count,
                isError: false,
                isDone: true
            )

        case .editDiff:
            let path = "Sources/MatrixEdit.swift"
            let oldText = Self.sampleSwiftSource(functionPrefix: "beforeEdit", count: 18)
            var newLines = oldText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if newLines.indices.contains(3) {
                newLines[3] = "    // updated by tool matrix"
            }
            newLines.append("func matrixEditTail() { print(\"tail\") }")
            let newText = newLines.joined(separator: "\n")

            toolArgsStore.set([
                "path": .string(path),
                "oldText": .string(oldText),
                "newText": .string(newText),
            ], for: itemID)
            toolOutputStore.append("Applied edit to \(path)", to: itemID)

            return .toolCall(
                id: itemID,
                tool: "edit",
                argsSummary: "edit \(path)",
                outputPreview: "Applied edit",
                outputByteCount: newText.utf8.count,
                isError: false,
                isDone: true
            )

        case .todoDiff:
            let body = (1...36).map { "- checklist item \($0)" }.joined(separator: "\n")

            toolArgsStore.set([
                "action": .string("update"),
                "id": .string("TODO-matrix-scroll"),
                "title": .string("Stabilize scroll matrix"),
                "status": .string("in_progress"),
                "body": .string(body),
            ], for: itemID)
            toolOutputStore.append("Updated TODO", to: itemID)

            return .toolCall(
                id: itemID,
                tool: "todo",
                argsSummary: "action: update, id: TODO-matrix-scroll",
                outputPreview: "Updated TODO",
                outputByteCount: body.utf8.count,
                isError: false,
                isDone: true
            )

        case .todoCard:
            let output = """
            [
              {"id":"TODO-a1","title":"Stabilize scroll anchor","status":"in_progress","tags":["ios","scroll"]},
              {"id":"TODO-a2","title":"Audit remember/recall rows","status":"open","tags":["timeline"]},
              {"id":"TODO-a3","title":"Capture perf traces","status":"done","tags":["perf"]}
            ]
            """

            toolArgsStore.set([
                "action": .string("list-all"),
            ], for: itemID)
            toolOutputStore.append(output, to: itemID)
            toolSegmentStore.setCallSegments([
                StyledSegment(text: "todo ", style: .bold),
                StyledSegment(text: "list-all", style: .accent),
            ], for: itemID)
            toolSegmentStore.setResultSegments([
                StyledSegment(text: "3 items", style: .success),
            ], for: itemID)

            return .toolCall(
                id: itemID,
                tool: "todo",
                argsSummary: "action: list-all",
                outputPreview: "TODO-a1",
                outputByteCount: output.utf8.count,
                isError: false,
                isDone: true
            )

        case .rememberMarkdown:
            let text = Self.sampleMarkdownDocument(title: "Remembered Notes", sections: 10)

            toolArgsStore.set([
                "text": .string(text),
                "tags": .array([.string("ios"), .string("scroll"), .string("timeline")]),
            ], for: itemID)
            toolOutputStore.append("", to: itemID)
            toolSegmentStore.setCallSegments([
                StyledSegment(text: "remember ", style: .bold),
                StyledSegment(text: "\"Remembered Notes\"", style: .accent),
                StyledSegment(text: " [ios, scroll, timeline]", style: .muted),
            ], for: itemID)
            toolSegmentStore.setResultSegments([
                StyledSegment(text: "saved", style: .success),
            ], for: itemID)

            return .toolCall(
                id: itemID,
                tool: "remember",
                argsSummary: "text: remembered notes",
                outputPreview: "",
                outputByteCount: text.utf8.count,
                isError: false,
                isDone: true
            )

        case .recallText:
            let output = (1...80)
                .map { "[\($0)] /journal/entry-\($0).md: matched architecture decision line \($0)" }
                .joined(separator: "\n")

            toolArgsStore.set([
                "query": .string("scroll anchoring"),
                "scope": .string("journal"),
                "days": .number(30),
            ], for: itemID)
            toolOutputStore.append(output, to: itemID)
            toolSegmentStore.setCallSegments([
                StyledSegment(text: "recall ", style: .bold),
                StyledSegment(text: "\"scroll anchoring\"", style: .accent),
                StyledSegment(text: " scope:journal 30d", style: .muted),
            ], for: itemID)
            toolSegmentStore.setResultSegments([
                StyledSegment(text: "80 matches", style: .success),
            ], for: itemID)

            return .toolCall(
                id: itemID,
                tool: "recall",
                argsSummary: "query: scroll anchoring",
                outputPreview: "[1] /journal/entry-1.md",
                outputByteCount: output.utf8.count,
                isError: false,
                isDone: true
            )

        case .customText:
            let output = (1...100).map { "custom-result-\($0): extension output" }.joined(separator: "\n")

            toolArgsStore.set([
                "query": .string("scroll reset bug"),
                "mode": .string("hybrid"),
            ], for: itemID)
            toolOutputStore.append(output, to: itemID)
            toolSegmentStore.setCallSegments([
                StyledSegment(text: "search ", style: .bold),
                StyledSegment(text: "\"scroll reset bug\"", style: .accent),
            ], for: itemID)
            toolSegmentStore.setResultSegments([
                StyledSegment(text: "100 hits", style: .success),
            ], for: itemID)

            return .toolCall(
                id: itemID,
                tool: "extensions.search",
                argsSummary: "query: scroll reset bug",
                outputPreview: "custom-result-1",
                outputByteCount: output.utf8.count,
                isError: false,
                isDone: true
            )

        case .plot:
            let rows: [JSONValue] = (0..<50).map { step in
                .object([
                    "step": .number(Double(step)),
                    "latencyMs": .number(110 + Double((step * 7) % 17)),
                ])
            }

            let spec: JSONValue = .object([
                "title": .string("Latency trend"),
                "dataset": .object([
                    "rows": .array(rows),
                ]),
                "marks": .array([
                    .object([
                        "type": .string("line"),
                        "x": .string("step"),
                        "y": .string("latencyMs"),
                    ]),
                ]),
                "axes": .object([
                    "x": .object(["label": .string("Step")]),
                    "y": .object(["label": .string("Latency (ms)")]),
                ]),
                "height": .number(240),
            ])

            toolArgsStore.set([
                "spec": spec,
            ], for: itemID)
            toolOutputStore.append("", to: itemID)

            return .toolCall(
                id: itemID,
                tool: "plot",
                argsSummary: "plot latency",
                outputPreview: "rendered chart",
                outputByteCount: rows.count * 16,
                isError: false,
                isDone: true
            )

        case .readMarkdown:
            let path = "Docs/Matrix.md"
            let markdown = Self.sampleMarkdownDocument(title: "Matrix Markdown", sections: 16)

            toolArgsStore.set([
                "path": .string(path),
                "offset": .number(1),
                "limit": .number(300),
            ], for: itemID)
            toolOutputStore.append(markdown, to: itemID)

            return .toolCall(
                id: itemID,
                tool: "read",
                argsSummary: "read \(path)",
                outputPreview: "# Matrix Markdown",
                outputByteCount: markdown.utf8.count,
                isError: false,
                isDone: true
            )

        case .readMedia:
            let path = "Assets/Matrix.png"
            let output = "data:image/png;base64,\(Self.samplePNGBase64)"

            toolArgsStore.set([
                "path": .string(path),
                "offset": .number(1),
                "limit": .number(20),
            ], for: itemID)
            toolOutputStore.append(output, to: itemID)

            return .toolCall(
                id: itemID,
                tool: "read",
                argsSummary: "read \(path)",
                outputPreview: output,
                outputByteCount: output.utf8.count,
                isError: false,
                isDone: true
            )
        }
    }

    private static var samplePNGBase64: String {
        // 1x1 transparent PNG.
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
    }

    private static func sampleSwiftSource(functionPrefix: String, count: Int) -> String {
        (0..<count).map { index in
            "func \(functionPrefix)_\(index)() {\n    print(\"row \\(\(index))\")\n}\n"
        }.joined(separator: "\n")
    }

    private static func sampleMarkdownDocument(title: String, sections: Int) -> String {
        var blocks: [String] = ["# \(title)"]
        for section in 1...sections {
            blocks.append("## Section \(section)")
            blocks.append((1...4).map { "- bullet \(section).\($0)" }.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func fillerAssistantMessage(id: String, seed: Int) -> ChatItem {
        .assistantMessage(
            id: "assistant-\(id)",
            text: String(repeating: "Timeline filler \(seed). ", count: 14),
            timestamp: Date()
        )
    }
}

@MainActor
struct ToolExpandScrollMatrixFixture {
    let toolCase: ToolExpandScrollMatrixCase
    let harness: WindowedTimelineHarness
    let items: [ChatItem]
    let targetIndexPath: IndexPath

    static func make(
        for toolCase: ToolExpandScrollMatrixCase,
        sessionSuffix: String,
        useAnchoredCollectionView: Bool = false
    ) -> Self? {
        let harness = makeWindowedTimelineHarness(
            sessionId: "s-tool-matrix-\(toolCase.name)-\(sessionSuffix)",
            useAnchoredCollectionView: useAnchoredCollectionView
        )

        let items = toolCase.makeTimeline(
            toolArgsStore: harness.toolArgsStore,
            toolOutputStore: harness.toolOutputStore,
            toolSegmentStore: harness.toolSegmentStore
        )
        harness.applyItems(items, isBusy: false)

        guard let targetIndex = items.firstIndex(where: { $0.id == toolCase.targetItemID }) else {
            return nil
        }

        return Self(
            toolCase: toolCase,
            harness: harness,
            items: items,
            targetIndexPath: IndexPath(item: targetIndex, section: 0)
        )
    }

    var collectionView: UICollectionView { harness.collectionView }

    var offsetY: CGFloat {
        collectionView.contentOffset.y + collectionView.adjustedContentInset.top
    }

    var maxOffsetY: CGFloat {
        let insets = collectionView.adjustedContentInset
        return max(
            0,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + insets.top
                + insets.bottom
        )
    }

    func prepareDetachedViewport() {
        _ = setOffsetY(maxOffsetY)
        _ = setOffsetY(maxOffsetY * 0.5)
        harness.scrollController.detachFromBottomForUserScroll()

        ensureTargetVisible()
    }

    func expandTarget() {
        harness.coordinator.collectionView(collectionView, didSelectItemAt: targetIndexPath)
        settleLayout()
    }

    func collapseTarget() {
        harness.coordinator.collectionView(collectionView, didSelectItemAt: targetIndexPath)
        settleLayout()
    }

    @discardableResult
    func setOffsetY(_ targetY: CGFloat) -> CGFloat {
        let clamped = clampOffsetY(targetY)
        let rawOffset = clamped - collectionView.adjustedContentInset.top
        collectionView.contentOffset.y = rawOffset
        settleLayout()
        return clamped
    }

    func clampOffsetY(_ targetY: CGFloat) -> CGFloat {
        min(max(0, targetY), maxOffsetY)
    }

    func assertExpandedInnerScrollViewsDoNotBounceVertically() {
        guard let cell = collectionView.cellForItem(at: targetIndexPath) else {
            Issue.record("Expanded target cell not visible for \(toolCase.name)")
            return
        }

        let innerScrollViews = timelineAllScrollViews(in: cell.contentView)
            .filter { $0 !== collectionView }

        #expect(!innerScrollViews.isEmpty, "Expected inner scroll views for \(toolCase.name)")

        for inner in innerScrollViews {
            #expect(!inner.alwaysBounceVertical,
                    "Inner scroll view has alwaysBounceVertical=true for \(toolCase.name)")
        }
    }

    func settleLayout(passes: Int = 2) {
        settleTimelineLayout(collectionView, passes: passes)
    }

    private func ensureTargetVisible() {
        if collectionView.cellForItem(at: targetIndexPath) != nil {
            return
        }

        collectionView.scrollToItem(at: targetIndexPath, at: .centeredVertically, animated: false)
        settleLayout()
        harness.scrollController.detachFromBottomForUserScroll()
    }
}
