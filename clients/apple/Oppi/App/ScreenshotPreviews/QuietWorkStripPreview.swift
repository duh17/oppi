#if DEBUG
import SwiftUI
import UIKit

// MARK: - Compact turns work strip

struct QuietWorkStripPreview: View {
    private let assistantStartedAt = Date().addingTimeInterval(-7)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                toolIconOptions
                chatSequence(style: .icons, title: "Icons")
                chatSequence(style: .words, title: "Words")
                WorkStripPreviewCard(style: .icons)
            }
            .padding(16)
        }
        .background(Color.themeBg.ignoresSafeArea())
        .accessibilityIdentifier("screenshot.ready")
    }

    private var toolIconOptions: some View {
        let candidates = [
            ("wrench", "wrench"),
            ("wrench.fill", "wrench.fill"),
            ("hammer", "hammer"),
            ("hammer.fill", "hammer.fill"),
            ("screwdriver", "screwdriver"),
            ("toolbox", "toolbox"),
        ]
        let reference = [
            "magnifyingglass",
            "pencil",
            "arrow.left.arrow.right",
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Tool icon options — same 13pt as the others")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeFgDim)
            ForEach(candidates, id: \.0) { name, symbol in
                HStack(spacing: 10) {
                    labeledSymbol(symbol)
                    Text("9")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                    ForEach(reference, id: \.self) { other in
                        labeledSymbol(other)
                    }
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.themeFg)
            }
        }
        .accessibilityIdentifier("quiet-work-strip.tool-icons")
    }

    private func labeledSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
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
