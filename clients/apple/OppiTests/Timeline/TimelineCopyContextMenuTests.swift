import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Timeline copy context menus")
struct TimelineCopyContextMenuTests {
    @MainActor
    @Test(arguments: TimelineCopyRowCase.allCases)
    func rowContextMenuUsesCopyPrimary(_ rowCase: TimelineCopyRowCase) throws {
        let menu = try #require(rowCase.makeContextMenu())
        #expect(timelineActionTitles(in: menu) == ["Copy"])
    }

    @MainActor
    @Test(arguments: TimelineCopyRowCase.allCases)
    func rowInstallsDoubleTapCopyGesture(_ rowCase: TimelineCopyRowCase) {
        assertHasDoubleTapGesture(in: rowCase.makeView())
    }

    @MainActor
    @Test(arguments: TimelineCopyRowCase.allCases)
    func rowReconfigurationKeepsSingleDoubleTapGesture(_ rowCase: TimelineCopyRowCase) throws {
        let view = rowCase.makeView()

        rowCase.reconfigure(view)
        rowCase.reconfigure(view)

        let doubleTapCount = timelineAllGestureRecognizers(in: view).reduce(into: 0) { count, recognizer in
            guard let tap = recognizer as? UITapGestureRecognizer,
                  tap.numberOfTapsRequired == 2 else { return }
            count += 1
        }

        #expect(doubleTapCount == 1, "Expected exactly one double-tap recognizer for \(rowCase.name)")

        let menu = try #require(rowCase.contextMenu(from: view))
        #expect(timelineActionTitles(in: menu) == ["Copy"])
    }

    /// Long press and double-tap on a message belong to native text selection,
    /// so message rows must not add a row menu or copy gesture that would take them.
    @MainActor
    @Test func messageRowsLeaveLongPressAndDoubleTapToTextSelection() {
        let selectionContext = TimelineInteractionContext()
        selectionContext.reviewCommentSelectionRouter = ReviewCommentSelectionRouter { _ in }
        selectionContext.sessionId = "session-1"
        let rows: [UIView] = [
            UserTimelineRowContentView(configuration: UserTimelineRowConfiguration(
                text: "hello", images: [], canFork: false, onFork: nil, interactionContext: selectionContext
            )),
            AssistantTimelineRowContentView(configuration: makeTimelineAssistantConfiguration(text: "Answer")),
        ]
        for row in rows {
            row.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
            row.layoutIfNeeded()
            #expect(timelineAllTextViews(in: row).contains { $0.isSelectable && !($0.text ?? "").isEmpty })
            // UITextView's own selection machinery is the behavior we want to keep.
            let rowOwned = timelineViewsOutsideTextViews(in: row)
            #expect(!rowOwned.contains { $0.interactions.contains { $0 is UIContextMenuInteraction } })
            #expect(!rowOwned.contains { view in
                (view.gestureRecognizers ?? []).contains { ($0 as? UITapGestureRecognizer)?.numberOfTapsRequired == 2 }
            })
        }
    }

    @MainActor
    private func timelineViewsOutsideTextViews(in root: UIView) -> [UIView] {
        guard !(root is UITextView) else { return [] }
        return [root] + root.subviews.flatMap { timelineViewsOutsideTextViews(in: $0) }
    }
}

enum TimelineCopyRowCase: CaseIterable, Sendable {
    case error
    case compaction

    var name: String {
        switch self {
        case .error: return "error"
        case .compaction: return "compaction"
        }
    }

    @MainActor
    func makeContextMenu() -> UIMenu? {
        contextMenu(from: makeView())
    }

    @MainActor
    func makeView() -> UIView {
        switch self {
        case .error:
            return ErrorTimelineRowContentView(configuration: errorConfiguration)
        case .compaction:
            return CompactionTimelineRowContentView(configuration: compactionConfiguration)
        }
    }

    @MainActor
    func reconfigure(_ view: UIView) {
        switch self {
        case .error:
            guard let typedView = view as? ErrorTimelineRowContentView else {
                Issue.record("Expected ErrorTimelineRowContentView for \(name)")
                return
            }
            typedView.configuration = errorConfiguration

        case .compaction:
            guard let typedView = view as? CompactionTimelineRowContentView else {
                Issue.record("Expected CompactionTimelineRowContentView for \(name)")
                return
            }
            typedView.configuration = compactionConfiguration
        }
    }

    @MainActor
    func contextMenu(from view: UIView) -> UIMenu? {
        switch self {
        case .error:
            return (view as? ErrorTimelineRowContentView)?.buildContextMenu()
        case .compaction:
            return (view as? CompactionTimelineRowContentView)?.buildContextMenu()
        }
    }

    private var errorConfiguration: ErrorTimelineRowConfiguration {
        ErrorTimelineRowConfiguration(
            message: "Permission denied"
        )
    }

    private var compactionConfiguration: CompactionTimelineRowConfiguration {
        CompactionTimelineRowConfiguration(
            presentation: .init(
                phase: .completed,
                detail: "Summary",
                tokensBefore: 12_345
            ),
            isExpanded: false
        )
    }
}
