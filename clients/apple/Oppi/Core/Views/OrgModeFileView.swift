import SwiftUI

/// Rendered org mode with source toggle, matching `MarkdownFileView` pattern.
struct OrgModeFileView: View {
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
                content: .orgMode(content: content, filePath: filePath),
                selectedTextPiRouter: piRouter
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Inline Body

    private var inlineBody: some View {
        let hasFullScreenAffordance = presentation.allowsExpansionAffordance && allowsFullScreenExpansion
        let inlineSelectionEnabled = ExpandableInlineTextSelectionPolicy.allowsInlineSelection(
            hasFullScreenAffordance: hasFullScreenAffordance
        )

        return VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "doc.richtext")
                    .font(.caption)
                    .foregroundStyle(.themeCyan)
                Text("Org Mode")
                    .font(.caption2.bold())
                    .foregroundStyle(.themeFgDim)
                Text("\(lineCount) lines")
                    .font(.caption2)
                    .foregroundStyle(.themeComment)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showRaw.toggle() }
                } label: {
                    Text(showRaw ? "Reader" : "Source")
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

            // Content
            ScrollView(.vertical) {
                Group {
                    if showRaw {
                        Text(content)
                            .font(.appCaptionMono)
                            .foregroundStyle(.themeFg)
                            .applyInlineTextSelectionPolicy(inlineSelectionEnabled)
                    } else {
                        OrgModeRenderedView(content: content, textSelectionEnabled: inlineSelectionEnabled)
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
                    language: SyntaxLanguage.orgMode.name,
                    startLine: 1,
                    selectedTextSourceContext: piRouter != nil
                        ? fileContentSourceContext(filePath: filePath, language: SyntaxLanguage.orgMode.name)
                        : nil
                )
            } else {
                ScrollView(.vertical) {
                    OrgModeRenderedView(
                        content: content,
                        textSelectionEnabled: true
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Rendered Content Wrapper

/// Wraps OrgParser + OrgAttributedStringRenderer into a UITextView-backed SwiftUI view.
private struct OrgModeRenderedView: View {
    let content: String
    let textSelectionEnabled: Bool

    @State private var attributedString: NSAttributedString?

    var body: some View {
        Group {
            if let attrStr = attributedString {
                AttributedStringTextView(
                    attributedString: attrStr,
                    textSelectionEnabled: textSelectionEnabled
                )
            } else {
                Text(content)
                    .font(.appCaption)
                    .foregroundStyle(.themeFg)
            }
        }
        .task(id: content) {
            await renderOrgContent()
        }
    }

    private func renderOrgContent() async {
        let source = content
        let result = await Task.detached {
            let parser = OrgParser()
            let renderer = OrgAttributedStringRenderer()
            let blocks = parser.parse(source)
            let config = RenderConfiguration(
                baseFontSize: 15,
                displayScale: 2.0,
                maxWidth: 600
            )
            return renderer.renderAttributedString(blocks, configuration: config)
        }.value
        attributedString = result
    }
}

/// UITextView wrapper for displaying attributed strings with proper link handling.
private struct AttributedStringTextView: UIViewRepresentable {
    let attributedString: NSAttributedString
    let textSelectionEnabled: Bool

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isSelectable = textSelectionEnabled
        textView.dataDetectorTypes = .link
        textView.attributedText = attributedString
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.attributedText = attributedString
        textView.isSelectable = textSelectionEnabled
    }
}
