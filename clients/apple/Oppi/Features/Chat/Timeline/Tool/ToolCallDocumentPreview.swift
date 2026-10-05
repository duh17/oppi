#if DEBUG
import SwiftUI
import UIKit

/// Run-local producer fixtures for the existing named-preview QA harness.
/// This paints the real row/reader; it does not prove a live server transport.
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
    @State private var fixturePath: String?

    private var fixture: [String: JSONValue]? {
        guard let path = fixturePath ?? ProcessInfo.processInfo.environment["OPPI_UI_VALIDATE_FIXTURE"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return (direct ? json.objectValue?["direct"] : json)?.objectValue
    }

    private func decode<T: Decodable>(_ value: JSONValue?) -> T? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private var configuration: ToolTimelineRowConfiguration? {
        guard let fixture, let tool = fixture["tool"]?.stringValue,
              let output = fixture["output"]?.stringValue else { return nil }
        var context = ToolPresentationBuilder.Context(args: fixture["args"]?.objectValue, details: fixture["details"],
            expandedItemIDs: fixture["expanded"]?.boolValue == false ? [] : ["document-preview"],
            fullOutput: output, isLoadingOutput: false, callSegments: decode(fixture["callSegments"]))
        context.display = decode(fixture["display"])
        context.inputPresentation = decode(fixture["inputPresentation"])
        if !direct && fixture["inputPresentation"] == nil {
            context.inputPresentation = .init(fields: ["code": .init(role: "code", language: "javascript")])
        }
        context.outputPresentation = decode(fixture["outputPresentation"])
        context.outputAvailability = decode(fixture["outputAvailability"])
        context.previewOnly = fixture["previewOnly"]?.boolValue == true
        context.totalBytes = fixture["totalBytes"]?.numberValue.map(Int.init)
        context.nestedCalls = decode(fixture["nestedCalls"])
        var config = ToolPresentationBuilder.build(itemID: "document-preview", tool: tool,
            argsSummary: "", outputPreview: output, isError: fixture["isError"]?.boolValue ?? false,
            isDone: fixture["isDone"]?.boolValue ?? true, context: context)
        // Fixture bytes replace attachment HTTP fetches, not native media painters.
        if let attachments = fixture["attachmentFixtures"]?.objectValue {
            config.sessionAttachmentFetcher = { id in
                guard let path = attachments[id]?.stringValue else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return try Data(contentsOf: URL(fileURLWithPath: path))
            }
        }
        // A fixture source exercises the production reader's window interface.
        // Actual HTTP HEAD/Range paging remains a separate transport proof.
        if let text = fixture["sidecarOutput"]?.stringValue {
            let bytes = Array(text.utf8)
            let window: @Sendable (Int) -> ToolOutputSidecarWindow? = { start in
                guard start < bytes.count else { return nil }
                let end = min(start + ToolOutputSidecarHTTP.firstWindowBytes, bytes.count)
                return .init(text: String(decoding: bytes[start..<end], as: UTF8.self), endByteOffset: end, totalBytes: bytes.count)
            }
            config.toolOutputSidecarSource = .init(loadFirst: { window(0) }, loadNext: { window($0) })
        }
        // The run-local file replaces the HTTP boundary, not the row's activation policy.
        if let intent = config.currentFileOpenIntent, let path = fixture["currentFileFixture"]?.stringValue {
            config.openCurrentFile = {
                let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "QA current-file fixture unavailable"
                reader = Reader(content: .fromText(text, filePath: intent.path))
            }
        }
        config.openFullScreen = { payload in
            if case .document(let content, _) = payload.kind { reader = Reader(content: content) }
        }
        return config
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(fixture?["label"]?.stringValue ?? (direct ? "Direct MCP sample" : "Tool inspection sample"))
                .font(.headline).foregroundStyle(.themeFg)
                .accessibilityIdentifier("screenshot.ready")
            if let configuration { PreviewRow(configuration: configuration) }
            else { Text("Missing run-local tool call fixture").accessibilityIdentifier("tool-document.fixture-missing") }
            if let next = fixture?["nextFixture"]?.stringValue {
                Button("Complete tool") { fixturePath = next }
                    .accessibilityIdentifier("tool-document.advance")
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 30).background(.themeBg)
        .onAppear {
            if fixture?["fullscreen"]?.boolValue == true, let configuration,
               let content = ToolTimelineRowFullScreenSupport.staticFullScreenContent(
                configuration: configuration, outputCopyText: configuration.copyOutputText, terminalStream: nil) {
                reader = Reader(content: content)
            }
        }
        .fullScreenViewer(
            isPresented: Binding(get: { reader != nil }, set: { if !$0 { reader = nil } }),
            content: reader?.content ?? .plainText(content: "", filePath: nil)
        )
        .environment(\.themeID, themeID).preferredColorScheme(themeID.preferredColorScheme)
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
