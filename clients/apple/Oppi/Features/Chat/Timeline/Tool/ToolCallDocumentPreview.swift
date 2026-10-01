#if DEBUG
import SwiftUI
import UIKit

/// The existing named-preview QA harness supplies a run-local fixture extracted
/// from a Pi result. Nothing from the owner's session is shipped with the app.
struct ToolCallDocumentPreview: View {
    let direct: Bool
    private let themeID: ThemeID

    init(direct: Bool) {
        self.direct = direct
        themeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light" ? .light : .dark
        ThemeRuntimeState.setThemeID(themeID)
    }

    private struct Reader: Identifiable { let id = UUID(); let content: FullScreenCodeContent }
    @State private var reader: Reader?

    private var configuration: ToolTimelineRowConfiguration? {
        guard let path = ProcessInfo.processInfo.environment["OPPI_UI_VALIDATE_FIXTURE"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let fixture = (direct ? json.objectValue?["direct"] : json)?.objectValue,
              let tool = fixture["tool"]?.stringValue,
              let output = fixture["output"]?.stringValue else { return nil }
        var context = ToolPresentationBuilder.Context(args: fixture["args"]?.objectValue,
            expandedItemIDs: fixture["expanded"]?.boolValue == false ? [] : ["document-preview"], fullOutput: output, isLoadingOutput: false)
        if let display = fixture["display"], let encoded = try? JSONEncoder().encode(display) {
            context.display = try? JSONDecoder().decode(ToolDisplay.self, from: encoded)
        }
        if !direct { context.inputPresentation = .init(fields: ["code": .init(role: "code", language: "javascript")]) }
        context.previewOnly = fixture["previewOnly"]?.boolValue == true
        context.totalBytes = fixture["totalBytes"]?.numberValue.map(Int.init)
        if let calls = fixture["nestedCalls"], let encoded = try? JSONEncoder().encode(calls) {
            context.nestedCalls = try? JSONDecoder().decode(NestedToolCalls.self, from: encoded)
        }
        var config = ToolPresentationBuilder.build(itemID: "document-preview", tool: tool,
            argsSummary: "", outputPreview: output, isError: false, isDone: fixture["isDone"]?.boolValue ?? true, context: context)
        config.openFullScreen = { payload in
            if case .document(let content, _) = payload.kind { reader = Reader(content: content) }
        }
        return config
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(direct ? "Direct MCP sample" : "Coros codemode sample")
                .font(.headline)
                .foregroundStyle(.themeFg)
            if let configuration {
                PreviewRow(configuration: configuration)
            } else {
                Text("Missing run-local tool call fixture").accessibilityIdentifier("tool-document.fixture-missing")
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 30)
        .background(.themeBg)
        .accessibilityIdentifier("screenshot.ready")
        .sheet(item: $reader) { payload in
            FullScreenCodeView(content: payload.content)
                .ignoresSafeArea()
        }
        .environment(\.themeID, themeID)
        .preferredColorScheme(themeID.preferredColorScheme)
    }

    private struct PreviewRow: UIViewRepresentable {
        let configuration: ToolTimelineRowConfiguration
        func makeUIView(context: Context) -> ToolTimelineRowContentView {
            let view = ToolTimelineRowContentView(configuration: configuration)
            view.accessibilityIdentifier = "tool-document.row"
            return view
        }
        func updateUIView(_ view: ToolTimelineRowContentView, context: Context) { view.configuration = configuration }
        func sizeThatFits(_ proposal: ProposedViewSize, uiView: ToolTimelineRowContentView, context: Context) -> CGSize? {
            let width = proposal.width ?? 370
            return uiView.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        }
    }
}
#endif
