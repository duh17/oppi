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
#endif
