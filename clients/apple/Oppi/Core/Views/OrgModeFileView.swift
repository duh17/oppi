import SwiftUI

/// Rendered org mode with source toggle, matching `MarkdownFileView` pattern.
///
/// Uses the markdown rendering pipeline for visual output. Org AST is converted
/// to markdown AST via `OrgToMarkdownConverter`, then rendered through the same
/// `MarkdownContentViewWrapper` / `AssistantMarkdownContentView` stack used for
/// `.md` files. This gives org mode identical fonts, colors, code blocks, and
/// spacing as markdown — no separate renderer needed.
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

    /// Convert org content to markdown text for the markdown pipeline.
    private var markdownContent: String {
        let parser = OrgParser()
        let orgBlocks = parser.parse(content)
        let mdBlocks = OrgToMarkdownConverter.convert(orgBlocks)
        return MarkdownBlockSerializer.serialize(mdBlocks)
    }

    /// Parse org content into a foldable section tree.
    private var orgSections: (sections: [OrgSection], foldState: OrgFoldState) {
        let parser = OrgParser()
        let orgBlocks = parser.parse(content)
        return buildOrgSectionTree(orgBlocks)
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
                        let tree = orgSections
                        OrgFoldableContentView(
                            sections: tree.sections,
                            initialFoldState: tree.foldState
                        )
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
                    language: SyntaxLanguage.orgMode.displayName,
                    startLine: 1,
                    selectedTextSourceContext: piRouter != nil
                        ? fileContentSourceContext(filePath: filePath, language: SyntaxLanguage.orgMode.displayName)
                        : nil
                )
            } else {
                ScrollView(.vertical) {
                    let tree = orgSections
                    OrgFoldableContentView(
                        sections: tree.sections,
                        initialFoldState: tree.foldState
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
