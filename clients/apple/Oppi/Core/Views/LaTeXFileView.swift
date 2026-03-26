import SwiftUI

/// Rendered LaTeX math with source toggle, matching `MarkdownFileView` pattern.
struct LaTeXFileView: View {
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
                content: .latex(content: content, filePath: filePath),
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
                Image(systemName: "function")
                    .font(.caption)
                    .foregroundStyle(.themeGreen)
                Text("LaTeX")
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

            ScrollView([.horizontal, .vertical]) {
                Group {
                    if showRaw {
                        Text(content)
                            .font(.appCaptionMono)
                            .foregroundStyle(.themeFg)
                    } else {
                        LaTeXRenderedView(content: content)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: presentation.viewportMaxHeight)
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
        Group {
            if showRaw {
                NativeCodeBodyView(
                    content: content,
                    language: SyntaxLanguage.latex.displayName,
                    startLine: 1,
                    selectedTextSourceContext: piRouter != nil
                        ? fileContentSourceContext(filePath: filePath, language: SyntaxLanguage.latex.displayName)
                        : nil
                )
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LaTeXRenderedView(content: content)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
            }
        }
    }
}

// MARK: - Rendered Content

private struct LaTeXRenderedView: View {
    let content: String

    private var renderResult: (CGSize, (CGContext, CGPoint) -> Void) {
        let parser = TeXMathParser()
        let renderer = MathCoreGraphicsRenderer()
        let nodes = parser.parse(content)
        let config = RenderConfiguration.default(maxWidth: 600)
        let layoutResult = renderer.layout(nodes, configuration: config)
        let size = renderer.boundingBox(layoutResult)
        let draw: (CGContext, CGPoint) -> Void = { ctx, origin in
            renderer.draw(layoutResult, in: ctx, at: origin)
        }
        return (size, draw)
    }

    var body: some View {
        let (size, draw) = renderResult
        GraphicalRendererSwiftUIView(size: size, drawBlock: draw)
            .frame(width: max(size.width, 1), height: max(size.height, 1))
    }
}
