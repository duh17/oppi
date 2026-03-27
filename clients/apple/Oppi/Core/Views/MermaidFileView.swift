import SwiftUI

/// Rendered Mermaid diagram with source toggle, matching `MarkdownFileView` pattern.
struct MermaidFileView: View {
    let content: String
    let filePath: String?
    let presentation: FileContentPresentation

    @Environment(\.allowsFullScreenExpansion) private var allowsFullScreenExpansion
    @Environment(\.selectedTextPiActionRouter) private var piRouter
    @State private var showRaw = false
    @State private var showFullScreen = false

    private var lineCount: Int {
        content.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var body: some View {
        Group {
            if presentation.usesInlineChrome {
                inlineBody
            } else {
                documentBody
            }
        }
        .sheet(isPresented: $showFullScreen) {
            FullScreenCodeView(
                content: .mermaid(content: content, filePath: filePath),
                selectedTextPiRouter: piRouter
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Inline Body

    private var inlineBody: some View {
        let hasFullScreenAffordance = presentation.allowsExpansionAffordance && allowsFullScreenExpansion

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chart.dots.scatter")
                    .font(.caption)
                    .foregroundStyle(.themePurple)
                Text("Mermaid")
                    .font(.caption2.bold())
                    .foregroundStyle(.themeFgDim)
                Text("\(lineCount) lines")
                    .font(.caption2)
                    .foregroundStyle(.themeComment)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showRaw.toggle() }
                } label: {
                    Text(showRaw ? "Rendered" : "Source")
                        .font(.caption2)
                        .foregroundStyle(.themeBlue)
                }
                .buttonStyle(.plain)

                if hasFullScreenAffordance {
                    Button {
                        showFullScreen = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2)
                            .foregroundStyle(.themeFgDim)
                    }
                    .buttonStyle(.plain)
                }

                CopyButton(content: content)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.themeBgHighlight)

            if showRaw {
                ScrollView([.horizontal, .vertical]) {
                    Text(content)
                        .font(.appCaptionMono)
                        .foregroundStyle(.themeFg)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: presentation.viewportMaxHeight)
            } else {
                MermaidRenderedView(content: content)
                    .padding(10)
                    .frame(maxHeight: presentation.viewportMaxHeight)
            }
        }
        .codeBlockChrome()
        .contextMenu {
            if hasFullScreenAffordance {
                Button("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                    showFullScreen = true
                }
            }
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = content
            }
        }
    }

    // MARK: - Document Body

    private var documentBody: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if showRaw {
                    NativeCodeBodyView(
                        content: content,
                        language: SyntaxLanguage.mermaid.displayName,
                        startLine: 1,
                        selectedTextSourceContext: piRouter != nil
                            ? fileContentSourceContext(filePath: filePath, language: SyntaxLanguage.mermaid.displayName)
                            : nil
                    )
                } else {
                    MermaidRenderedView(content: content)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
            }

            // Floating toolbar
            HStack(spacing: 8) {
                FileShareButton(content: .mermaid(content), style: .capsule)
                    .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showRaw.toggle() }
                } label: {
                    Label(
                        showRaw ? "Rendered" : "Source",
                        systemImage: showRaw ? "chart.dots.scatter" : "curlybraces"
                    )
                    .font(.caption2.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 12)
            .padding(.top, 8)
        }
    }
}

// MARK: - Rendered Content

private struct MermaidRenderedView: View {
    let content: String

    private var renderResult: (CGSize, (CGContext, CGPoint) -> Void) {
        let parser = MermaidParser()
        let renderer = MermaidFlowchartRenderer()
        let diagram = parser.parse(content)
        let config = RenderConfiguration.default(maxWidth: 600)
        let layoutResult = renderer.layout(diagram, configuration: config)
        let size = renderer.boundingBox(layoutResult)
        let draw: (CGContext, CGPoint) -> Void = { ctx, origin in
            renderer.draw(layoutResult, in: ctx, at: origin)
        }
        return (size, draw)
    }

    var body: some View {
        let startNs = ChatTimelinePerf.timestampNs()
        let (size, draw) = renderResult
        let durationMs = ChatTimelinePerf.elapsedMs(since: startNs)
        let _ = {
            if durationMs >= 1 {
                ChatTimelinePerf.recordRenderStrategy(
                    mode: "mermaid_fullscreen",
                    durationMs: durationMs,
                    inputBytes: content.utf8.count
                )
            }
        }()
        ZoomableGraphicalSwiftUIView(size: size, drawBlock: draw)
            .frame(maxWidth: .infinity, minHeight: min(size.height, 400), maxHeight: max(size.height, 400))
    }
}
