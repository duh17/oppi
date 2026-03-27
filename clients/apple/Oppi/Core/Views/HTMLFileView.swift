import SwiftUI

// MARK: - HTMLFileView

/// Rendered HTML with source toggle and full-screen support.
///
/// - Document mode: renders WebKit by default with a floating Source/Preview toggle
/// - Inline mode: shows UIKit syntax-highlighted source with a "Preview" button
///   that opens full-screen rendered view (avoids heavy WebKit views inline in
///   the timeline)
struct HTMLFileView: View {
    let content: String
    let filePath: String?
    let presentation: FileContentPresentation

    @Environment(\.allowsFullScreenExpansion) private var allowsFullScreenExpansion
    @Environment(\.selectedTextPiActionRouter) private var piRouter
    @State private var showSource = false
    @State private var showFullScreen = false

    private var lineCount: Int {
        content.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// Pi action handler for WKWebView text selection.
    /// Routes through the environment router when available, falls back to clipboard.
    private var piWebViewHandler: (String, PiQuickAction) -> Void {
        let path = filePath
        let router = piRouter
        return { text, quickAction in
            let request = SelectedTextPiRequest(
                action: quickAction,
                selectedText: text,
                source: fileContentSourceContext(filePath: path, surface: .fullScreenSource)
            )
            if let router {
                router.dispatch(request)
            } else {
                UIPasteboard.general.string = SelectedTextPiPromptFormatter.composeDraftAddition(for: request)
            }
        }
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
                content: .html(content: content, filePath: filePath),
                selectedTextPiRouter: piRouter
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Inline body (tool output context)

    private var inlineBody: some View {
        let hasFullScreenAffordance = presentation.allowsExpansionAffordance && allowsFullScreenExpansion
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let displayLineCount = min(lines.count, FileContentView.maxDisplayLines)
        let isTruncated = lines.count > FileContentView.maxDisplayLines
        let displayContent = lines.prefix(displayLineCount).joined(separator: "\n")

        return VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.caption)
                    .foregroundStyle(.themeCyan)
                Text("HTML")
                    .font(.caption2.bold())
                    .foregroundStyle(.themeFgDim)
                Text("\(lineCount) lines")
                    .font(.caption2)
                    .foregroundStyle(.themeComment)

                Spacer()

                if hasFullScreenAffordance {
                    Button {
                        showFullScreen = true
                    } label: {
                        Label("Preview", systemImage: "eye")
                            .font(.caption2)
                            .foregroundStyle(.themeBlue)
                    }
                    .buttonStyle(.plain)

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

            // Source code (always source in inline mode for performance)
            NativeCodeBodyView(
                content: displayContent,
                language: "html",
                startLine: 1,
                maxHeight: presentation.viewportMaxHeight
            )

            if isTruncated {
                TruncationNotice(showing: displayLineCount, total: lines.count)
            }
        }
        .codeBlockChrome()
        .contextMenu {
            if hasFullScreenAffordance {
                Button("Preview HTML", systemImage: "eye") {
                    showFullScreen = true
                }
                Button("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                    showFullScreen = true
                }
            }
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = content
            }
        }
    }

    // MARK: - Document body (file browser, remote file)

    private var documentBody: some View {
        ZStack(alignment: .topTrailing) {
            if showSource {
                NativeCodeBodyView(
                    content: content,
                    language: "html",
                    startLine: 1,
                    selectedTextSourceContext: piRouter != nil
                        ? fileContentSourceContext(filePath: filePath, language: "html")
                        : nil
                )
            } else {
                HTMLWebView(
                    htmlString: content,
                    baseFileName: filePath ?? "preview.html",
                    piActionHandler: piWebViewHandler
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .bottom)
            }

            // Floating toolbar
            HStack(spacing: 8) {
                FileShareButton(content: .html(content), style: .capsule)
                    .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showSource.toggle() }
                } label: {
                    Label(
                        showSource ? "Preview" : "Source",
                        systemImage: showSource ? "eye" : "curlybraces"
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
