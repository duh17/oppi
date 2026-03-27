import SwiftUI

/// Rendered org mode with source toggle, matching `MarkdownFileView` pattern.
///
/// Uses the markdown rendering pipeline for visual output. Org AST is converted
/// to markdown AST via `OrgToMarkdownConverter`, then rendered through the same
/// `MarkdownContentViewWrapper` / `AssistantMarkdownContentView` stack used for
/// `.md` files. This gives org mode identical fonts, colors, code blocks, and
/// spacing as markdown — no separate renderer needed.
///
/// Performance: section tree is parsed once in `.task(id:)` and cached in `@State`.
/// This avoids re-parsing on every body evaluation (state changes, environment updates)
/// and stabilizes `OrgSection.id` UUIDs for scroll position preservation.
struct OrgModeFileView: View {
    let content: String
    let filePath: String?
    let presentation: FileContentPresentation

    @Environment(\.allowsFullScreenExpansion) private var allowsFullScreenExpansion
    @Environment(\.selectedTextPiActionRouter) private var piRouter
    @State private var showRaw = false
    @State private var showFullScreen = false

    /// Cached section tree — parsed once, stable UUIDs across body re-evaluations.
    @State private var cachedTree: (sections: [OrgSection], foldState: OrgFoldState)?

    private var lineCount: Int {
        content.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// Synchronous parse for first render (before .task completes).
    /// The .task will replace this with a properly cached version for stable UUIDs.
    private var synchronousTree: (sections: [OrgSection], foldState: OrgFoldState) {
        let parser = OrgParser()
        let blocks = parser.parse(content)
        return buildOrgSectionTree(blocks)
    }

    /// Convert org content to markdown text for the markdown pipeline.
    private var markdownContent: String {
        let parser = OrgParser()
        let orgBlocks = parser.parse(content)
        let mdBlocks = OrgToMarkdownConverter.convert(orgBlocks)
        return MarkdownBlockSerializer.serialize(mdBlocks)
    }

    var body: some View {
        Group {
            if presentation.usesInlineChrome {
                inlineBody
            } else {
                documentBody
            }
        }
        .task(id: content) {
            // Parse off the caller's context. OrgParser is Sendable + nonisolated,
            // so the heavy work runs without blocking the main thread.
            let tree = await Task.detached {
                let parser = OrgParser()
                let blocks = parser.parse(content)
                return buildOrgSectionTree(blocks)
            }.value
            cachedTree = tree
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
                        let tree = cachedTree ?? synchronousTree
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
        ZStack(alignment: .topTrailing) {
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
                    let tree = cachedTree ?? synchronousTree
                    ScrollView(.vertical) {
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

            // Floating toolbar
            HStack(spacing: 8) {
                FileShareButton(content: .orgMode(content), style: .capsule)
                    .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showRaw.toggle() }
                } label: {
                    Label(
                        showRaw ? "Reader" : "Source",
                        systemImage: showRaw ? "doc.richtext" : "curlybraces"
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
