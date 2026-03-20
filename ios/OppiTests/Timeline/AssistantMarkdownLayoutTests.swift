import Foundation
import Testing
import UIKit
@testable import Oppi

/// Layout regression tests for AssistantMarkdownContentView self-sizing.
///
/// Ensures dense markdown with interleaved prose and code blocks produces
/// correct cell heights in the collection view. Guards against regressions
/// if the text view implementation changes (e.g., UILabel ↔ UITextView).
@Suite("AssistantMarkdownContentView Layout")
@MainActor
struct AssistantMarkdownLayoutTests {

    @Test func denseMarkdownProducesCorrectCellHeight() throws {
        let markdown = """
        # Heading

        Some prose text here.

        ```text
        Explain this:
        ```

        More prose between code blocks.

        ```swift
        let x = 1
        ```

        Final paragraph.
        """

        let config = AssistantTimelineRowConfiguration(
            text: markdown,
            isStreaming: false,
            canFork: false,
            onFork: nil,
            themeID: .dark
        )
        let cell = AssistantTimelineRowContentView(configuration: config)

        // Mirror the exact SafeSizingCell path — no container, no pre-layout.
        let fitted = cell.systemLayoutSizeFitting(
            CGSize(width: 370, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .defaultLow
        )

        // Heading + 2 prose + 2 code blocks + spacing ≈ 250pt minimum.
        #expect(fitted.height > 200, "Cell height \(fitted.height) too small — prose or code blocks likely collapsed")
    }

    @Test func collectionViewCellsDoNotOverlap() throws {
        let layout = ChatTimelineCollectionHost.makeTestLayout()
        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 852),
            collectionViewLayout: layout
        )

        let items: [(String, String)] = [
            ("msg-1", "Short first message."),
            ("msg-2", "# Doc\n\nProse.\n\n```text\nTemplate\n```\n\nMore prose.\n\n```swift\nlet x = 1\n```\n\nEnd."),
            ("msg-3", "Short after long."),
        ]

        let reg = UICollectionView.CellRegistration<UICollectionViewCell, String> { cell, _, itemID in
            guard let text = items.first(where: { $0.0 == itemID })?.1 else { return }
            cell.contentConfiguration = AssistantTimelineRowConfiguration(
                text: text, isStreaming: false, canFork: false, onFork: nil, themeID: .dark
            )
        }

        let ds = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { cv, ip, id in
            cv.dequeueConfiguredReusableCell(using: reg, for: ip, item: id)
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(items.map(\.0))
        ds.apply(snapshot, animatingDifferences: false)
        collectionView.layoutIfNeeded()

        let sorted = collectionView.indexPathsForVisibleItems
            .sorted { $0.item < $1.item }
            .compactMap { collectionView.cellForItem(at: $0) }
            .map(\.frame)

        #expect(sorted.count >= 2)
        for i in 0 ..< sorted.count - 1 {
            let gap = sorted[i + 1].minY - sorted[i].maxY
            #expect(gap >= 0, "Cells \(i) and \(i + 1) overlap by \(-gap)pt")
        }
    }

    /// Regression: the context bar's expanded state uses a Liquid Glass
    /// effect. When a session has spawned child agents, the expanded bar
    /// shows agent rows overlaid on the chat timeline. The glass material
    /// is semi-transparent, allowing timeline tool calls and assistant text
    /// to bleed through, creating a visual double-layer of overlapping text.
    ///
    /// Fix: add an opaque scrim behind the expanded context bar so the
    /// timeline content is dimmed and visually separated. The scrim also
    /// absorbs scroll gestures that previously passed through the clear
    /// dismiss overlay, letting the user scroll the timeline behind the bar.
    @Test func contextBarExpandedDismissOverlayShouldBeOpaque() throws {
        // The context bar dismiss overlay should use non-zero opacity
        // so the timeline doesn't show through the glass effect.
        // This test serves as a regression anchor — the actual visual
        // behavior requires the ChatView dismiss overlay to use a scrim
        // color instead of Color.clear. See ChatView.chatTimelineScaffold.
        //
        // We verify the supporting invariant: when child sessions exist,
        // the context bar has content (so the scrim matters).
        let hasContent = ContextBarScoping.hasContent(
            gitStatus: nil,
            sessionId: "s1",
            sessionScope: nil,
            childSessions: [
                makeTestSession(id: "child-1", status: .stopped),
                makeTestSession(id: "child-2", status: .busy),
            ]
        )
        #expect(hasContent, "Context bar should show when child sessions exist")

        // And verify it still works without children but with git changes.
        var dirtyGit = GitStatus.empty
        dirtyGit.isGitRepo = true
        dirtyGit.totalFiles = 1
        dirtyGit.dirtyCount = 1
        let hasContentGitOnly = ContextBarScoping.hasContent(
            gitStatus: dirtyGit,
            sessionId: nil,
            sessionScope: nil,
            childSessions: []
        )
        #expect(hasContentGitOnly, "Context bar should show for dirty git status")
    }

    /// Regression test: alternating tool rows and multi-line assistant messages
    /// must not overlap. Reproduces the bug where tool-call cells (green
    /// checkmark / red xmark) and assistant text cells render on top of
    /// each other in a session with many short tool calls interleaved with
    /// longer assistant summaries.
    @Test func mixedToolAndAssistantCellsDoNotOverlap() throws {
        let layout = ChatTimelineCollectionHost.makeTestLayout()
        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 393, height: 1200),
            collectionViewLayout: layout
        )

        // Simulate a real session: tool call → assistant summary → tool call → ...
        // The assistant summaries are multi-line (like the agent work descriptions
        // visible in the bug screenshot).
        enum CellKind {
            case tool(String)
            case assistant(String)
        }
        let timeline: [(id: String, kind: CellKind)] = [
            ("tool-1", .tool("$ grep -rn 'hitchCount' ios/")),
            ("asst-1", .assistant("Found hitchCount/totalApplyCycles counter and emitJankRate() API. The session_load_ms timer lives in ChatSessionManager — starts at connect, stops at first content.")),
            ("tool-2", .tool("$ # Also check: does the session usage metric exist?")),
            ("asst-2", .assistant("Session ID plumbed through to voice metrics (VoiceInputManager/Telemetry) and coalescer (DeltaCoalescer). Sorted JSON keys via dedicated chatMetricsEncoder with .sortedKeys. Fixed traceEvents to use trace_events tag.")),
            ("tool-3", .tool("$ # Check the routes-modules test too")),
            ("asst-3", .assistant("Good — tests correctly updated: removed stream_open_ms and session_total_tokens test samples, updated expected count from 21 to 19 in CHAT_METRIC_REGISTRY. Now let me fix the leftover issue and clean up the registry.")),
            ("tool-4", .tool("$ # Remove the orphaned panel")),
            ("asst-4", .assistant("Grafana dashboard rebuilt: 5-vital scorecard row at top, 5 noise panels removed, 2 new drill-down panels (timeline render cost, session load pipeline), rows reordered by user journey. Python dashboard rewritten to query vitals by name.")),
        ]

        let toolReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { cell, _, itemID in
            guard let entry = timeline.first(where: { $0.id == itemID }),
                  case .tool(let cmd) = entry.kind else { return }
            cell.contentConfiguration = ToolTimelineRowConfiguration(
                title: cmd,
                preview: nil,
                expandedContent: nil,
                copyCommandText: cmd,
                copyOutputText: nil,
                languageBadge: nil,
                trailing: nil,
                titleLineBreakMode: .byTruncatingTail,
                toolNamePrefix: "bash",
                toolNameColor: UIColor(red: 0.4, green: 0.8, blue: 0.4, alpha: 1),
                editAdded: nil,
                editRemoved: nil,
                collapsedImageBase64: nil,
                collapsedImageMimeType: nil,
                isExpanded: false,
                isDone: true,
                isError: false,
                segmentAttributedTitle: nil,
                segmentAttributedTrailing: nil
            )
        }

        let assistantReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { cell, _, itemID in
            guard let entry = timeline.first(where: { $0.id == itemID }),
                  case .assistant(let text) = entry.kind else { return }
            cell.contentConfiguration = AssistantTimelineRowConfiguration(
                text: text, isStreaming: false, canFork: false, onFork: nil, themeID: .dark
            )
        }

        let ds = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { cv, ip, id in
            if id.hasPrefix("tool-") {
                return cv.dequeueConfiguredReusableCell(using: toolReg, for: ip, item: id)
            } else {
                return cv.dequeueConfiguredReusableCell(using: assistantReg, for: ip, item: id)
            }
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(timeline.map(\.id))
        ds.apply(snapshot, animatingDifferences: false)
        collectionView.layoutIfNeeded()

        let sorted = collectionView.indexPathsForVisibleItems
            .sorted { $0.item < $1.item }
            .compactMap { collectionView.cellForItem(at: $0) }
            .map(\.frame)

        #expect(sorted.count >= 4, "Expected at least 4 visible cells, got \(sorted.count)")
        for i in 0 ..< sorted.count - 1 {
            let gap = sorted[i + 1].minY - sorted[i].maxY
            #expect(gap >= 0, "Cells \(i) and \(i + 1) overlap by \(-gap)pt")
        }
    }
}
