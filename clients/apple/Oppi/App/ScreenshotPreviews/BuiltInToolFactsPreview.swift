#if DEBUG
import SwiftUI
import UIKit

/// Exercises the production row painter with an older-server payload: no facts.
struct BuiltInToolFactsPreview: View {
    let isEdit: Bool

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(isEdit ? "Old server · Edit" : "Old server · Bash")
                        .font(.title2.weight(.semibold))
                    Text("No inputPresentation or outputPresentation")
                        .font(.caption)
                        .foregroundStyle(.themeFgDim)
                    NativeToolRow(configuration: configuration, width: geometry.size.width - 32)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.themeFg)
                .padding(16)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("screenshot.ready")
            }
        }
        .background(Color.themeBg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var configuration: ToolTimelineRowConfiguration {
        let args: [String: JSONValue] = isEdit
            ? ["path": "Example.swift", "edits": [["oldText": "let value = 1", "newText": "let value = 2\nlet extra = 3"]]]
            : ["command": "printf 'native terminal\\n'\nswift --version"]
        let output = isEdit ? "" : "native terminal\nSwift version 6.2\nTarget: arm64-apple-macosx"
        return ToolPresentationBuilder.build(itemID: "legacy", tool: isEdit ? "edit" : "bash",
            argsSummary: isEdit ? "Example.swift" : "printf; swift --version", outputPreview: output,
            isError: false, isDone: true,
            context: .init(args: args, expandedItemIDs: ["legacy"], fullOutput: output, isLoadingOutput: false))
    }
}

private struct NativeToolRow: UIViewRepresentable {
    let configuration: ToolTimelineRowConfiguration
    let width: CGFloat

    func makeUIView(context: Context) -> ToolTimelineRowContentView {
        ToolTimelineRowContentView(configuration: configuration)
    }

    func updateUIView(_ uiView: ToolTimelineRowContentView, context: Context) {
        uiView.configuration = configuration
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ToolTimelineRowContentView, context: Context) -> CGSize? {
        uiView.bounds.size.width = width
        uiView.layoutIfNeeded()
        return uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
    }
}
/// Both states use the production controller's result-to-tool-row adapter.
struct InputCardDisclosurePreview: View {
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 18) {
                Text("Background result · progressive disclosure").font(.headline)
                Text("Compact").font(.caption).foregroundStyle(.themeFgDim)
                CompletionRowPreview(expanded: false, width: geometry.size.width - 32)
                Text("Expanded · tap output for full screen").font(.caption).foregroundStyle(.themeFgDim)
                CompletionRowPreview(expanded: true, width: geometry.size.width - 32)
                Spacer()
            }
            .padding(16)
            .foregroundStyle(.themeFg)
        }
        .background(Color.themeBg.ignoresSafeArea())
        .accessibilityIdentifier("screenshot.ready")
    }
}

private struct CompletionRowPreview: UIViewRepresentable {
    let expanded: Bool
    let width: CGFloat

    func makeUIView(context: Context) -> UIView {
        let reducer = TimelineReducer()
        let controller = ChatTimelineCollectionHost.Controller()
        controller.reducer = reducer
        controller.toolOutputStore = reducer.toolOutputStore
        if expanded { reducer.expandedItemIDs.insert("result") }
        reducer.toolOutputStore.replace((1...100).map { "Build output line \($0): passed" }.joined(separator: "\n"), for: "result")
        var card = TraceEventPresentation(kind: "custom", title: "Background job bash-60", subtitle: nil,
            status: "completed", body: "npm run check", fields: [.init(label: "Result", value: "Exit 0")], accent: "success")
        card.output = .init(kind: "terminal", entryId: "123", command: "npm run check", truncated: nil)
        let item = ChatItem.customEvent(id: "result", message: "Completed", presentation: card)
        guard let configuration = controller.toolRowConfiguration(itemID: "result", item: item) else {
            return UIView()
        }
        return configuration.makeContentView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        uiView.bounds.size.width = width
        uiView.layoutIfNeeded()
        return uiView.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
    }
}
#endif
