#if DEBUG
import SwiftUI
import UIKit

// MARK: - Compact turns work strip

struct QuietWorkStripPreview: View {
    private let assistantStartedAt = Date().addingTimeInterval(-7)
    @State private var inspectionFixture = ToolInspectionPreviewFixture.makeReducer()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                mixedEditSession
                mixedInspectionSession
                chatSequence(style: .icons, title: "Icons")
                chatSequence(style: .words, title: "Words")
                WorkStripPreviewCard(style: .icons)
            }
            .padding(16)
        }
        .background(Color.themeBg.ignoresSafeArea())
        .accessibilityIdentifier("screenshot.ready")
    }

    private var mixedEditSession: some View {
        let edits = inspectionFixture.items.filter { inspectionFixture.toolInspection(for: $0)?.activityKind == .fileDiff }
        let projection = QuietTimelineProjection.make(items: edits, isQuiet: true, isBusy: false,
            expandedTurnIDs: [], toolInspection: { inspectionFixture.toolInspection(for: $0) },
            isInteractiveTool: { inspectionFixture.isInteractiveTool($0) })
        return VStack(alignment: .leading, spacing: 10) {
            Text("Mixed requested/result edit totals").font(.caption.weight(.semibold))
            ForEach(projection.rows) { row in
                if case .quietWork(let line) = row {
                    QuietWorkStripRowPreview(workLine: line, style: .words).frame(height: 44)
                }
            }
        }
    }

    private var mixedInspectionSession: some View {
        let projection = QuietTimelineProjection.make(items: inspectionFixture.items, isQuiet: true, isBusy: false,
            expandedTurnIDs: [], toolInspection: { inspectionFixture.toolInspection(for: $0) })
        return VStack(alignment: .leading, spacing: 10) {
            Text("Mixed tool facts: terminal · files · MCP · nested calls")
                .font(.caption.weight(.semibold))
            ForEach(projection.rows) { row in
                switch row {
                case .quietWork(let line):
                    QuietWorkStripRowPreview(workLine: line, style: .icons).frame(height: 44)
                    QuietWorkStripRowPreview(workLine: line, style: .words).frame(height: 44)
                case .item(let item):
                    if case .toolCall = item, let inspection = inspectionFixture.toolInspection(for: item) {
                        Label(inspection.interactionSummary ?? inspection.title, systemImage: inspection.glyph ?? "wrench")
                    }
                }
            }
        }.accessibilityIdentifier("quiet-work-strip.mixed-inspection")
    }

    private func chatSequence(
        style: AppPreferences.ChatDisplay.WorkStripStyle,
        title: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeFgDim)

            userBubble("Keep the sequence behavior and the three visual cases.")
            assistantText("I’ll inspect grouping first, then add the mixed-rank regressions.")
            QuietWorkStripRowPreview(workLine: historicalWorkLine(style: style), style: style)
                .frame(height: 44)
            assistantText("I’ll add failing tests first, then fix grouping.")
            QuietWorkStripRowPreview(workLine: liveThinkingWorkLine(style: style), style: style)
                .frame(height: 44)
            QuietWorkStripRowPreview(workLine: liveWorkLine(style: style), style: style)
                .frame(height: 44)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quiet-work-strip.\(style.rawValue)")
    }

    private func userBubble(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(ThemeRuntimeState.currentPalette().userMessageText)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ThemeRuntimeState.currentPalette().userMessageBg,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }

    private func assistantText(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.themeFg)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func historicalWorkLine(
        style: AppPreferences.ChatDisplay.WorkStripStyle
    ) -> QuietTimelineWorkLine {
        QuietTimelineWorkLine(
            id: "quiet-work-line:historical-\(style.rawValue)",
            turnID: "historical-\(style.rawValue)",
            sourceItemIDs: ["historical-\(style.rawValue)"],
            buckets: [
                .init(kind: .read, count: 8),
                .init(kind: .tooling, count: 5),
                .init(kind: .write, count: 2),
                .init(kind: .edit, count: 1, editStats: .init(added: 18, removed: 4)),
            ],
            displayStyle: style,
            isExpanded: false,
            isLive: false,
            liveStartedAt: nil
        )
    }

    private func liveThinkingWorkLine(
        style: AppPreferences.ChatDisplay.WorkStripStyle
    ) -> QuietTimelineWorkLine {
        QuietTimelineWorkLine(
            id: "quiet-work-line:thinking-\(style.rawValue)",
            turnID: "thinking-\(style.rawValue)",
            sourceItemIDs: ["thinking-\(style.rawValue)"],
            buckets: [],
            displayStyle: style,
            isExpanded: false,
            isLive: true,
            liveStartedAt: assistantStartedAt
        )
    }

    private func liveWorkLine(
        style: AppPreferences.ChatDisplay.WorkStripStyle
    ) -> QuietTimelineWorkLine {
        QuietTimelineWorkLine(
            id: "quiet-work-line:live-\(style.rawValue)",
            turnID: "live-\(style.rawValue)",
            sourceItemIDs: ["live-\(style.rawValue)"],
            buckets: [
                .init(kind: .read, count: 4),
                .init(kind: .tooling, count: 9),
                .init(kind: .write, count: 1),
                .init(kind: .edit, count: 1, editStats: .init(added: 12, removed: 3)),
            ],
            displayStyle: style,
            isExpanded: false,
            isLive: true,
            liveStartedAt: assistantStartedAt
        )
    }
}


private struct QuietWorkStripRowPreview: UIViewRepresentable {
    let workLine: QuietTimelineWorkLine
    let style: AppPreferences.ChatDisplay.WorkStripStyle

    func makeUIView(context: Context) -> QuietWorkLineTimelineRowContentView {
        QuietWorkLineTimelineRowContentView(
            configuration: QuietWorkLineTimelineRowConfiguration(
                workLine: workLine,
                style: style
            )
        )
    }

    func updateUIView(_ uiView: QuietWorkLineTimelineRowContentView, context: Context) {
        uiView.configuration = QuietWorkLineTimelineRowConfiguration(
            workLine: workLine,
            style: style
        )
    }
}
#endif
