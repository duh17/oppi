import SwiftUI

// MARK: - Org Section Tree

/// A section in the org document tree.
/// Each heading creates a section containing its body content and child sections.
struct OrgSection: Identifiable {
    let id = UUID()
    let level: Int
    let heading: OrgBlock?    // nil for the zeroth section (content before first heading)
    let bodyBlocks: [OrgBlock] // non-heading content under this heading
    let children: [OrgSection] // sub-headings
}

/// Initial fold state from `#+STARTUP:` keyword.
enum OrgFoldState {
    /// `overview` — only level-1 headings visible
    case overview
    /// `content` — all headings visible, body hidden
    case content
    /// `showall` / `nofold` — everything expanded
    case showAll
}

// MARK: - Build section tree from flat blocks

/// Convert a flat `[OrgBlock]` into a tree of `OrgSection` grouped by heading level.
func buildOrgSectionTree(_ blocks: [OrgBlock]) -> (sections: [OrgSection], foldState: OrgFoldState) {
    var foldState: OrgFoldState = .showAll

    // Check for #+STARTUP keyword
    for block in blocks {
        if case .keyword(let key, let value) = block, key.uppercased() == "STARTUP" {
            let val = value.lowercased().trimmingCharacters(in: .whitespaces)
            if val.contains("overview") { foldState = .overview }
            else if val.contains("content") { foldState = .content }
            else if val.contains("nofold") || val.contains("showall") { foldState = .showAll }
        }
    }

    var sections: [OrgSection] = []
    var cursor = 0

    // Zeroth section: blocks before first heading
    var zerothBody: [OrgBlock] = []
    while cursor < blocks.count {
        if case .heading = blocks[cursor] { break }
        zerothBody.append(blocks[cursor])
        cursor += 1
    }
    if !zerothBody.isEmpty {
        sections.append(OrgSection(level: 0, heading: nil, bodyBlocks: zerothBody, children: []))
    }

    // Parse headings into tree
    let headingSections = parseHeadingSections(blocks: blocks, cursor: &cursor, parentLevel: 0)
    sections.append(contentsOf: headingSections)

    return (sections, foldState)
}

private func parseHeadingSections(blocks: [OrgBlock], cursor: inout Int, parentLevel: Int) -> [OrgSection] {
    var sections: [OrgSection] = []

    while cursor < blocks.count {
        guard case .heading(let level, _, _, _, _) = blocks[cursor] else {
            break
        }

        // If this heading is at or above parent level, it belongs to the parent
        if level <= parentLevel {
            break
        }

        let heading = blocks[cursor]
        cursor += 1

        // Collect body blocks (non-heading content)
        var body: [OrgBlock] = []
        while cursor < blocks.count {
            if case .heading = blocks[cursor] { break }
            body.append(blocks[cursor])
            cursor += 1
        }

        // Recursively collect child headings (deeper level)
        let children = parseHeadingSections(blocks: blocks, cursor: &cursor, parentLevel: level)

        sections.append(OrgSection(level: level, heading: heading, bodyBlocks: body, children: children))
    }

    return sections
}

// MARK: - Foldable Org View

/// Renders an org document with collapsible heading sections.
/// Content under each heading renders through the markdown pipeline.
struct OrgFoldableContentView: View {
    let sections: [OrgSection]
    let initialFoldState: OrgFoldState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                OrgSectionView(section: section, initialFoldState: initialFoldState)
            }
        }
    }
}

// MARK: - Section View

private struct OrgSectionView: View {
    let section: OrgSection
    let initialFoldState: OrgFoldState
    @State private var isExpanded: Bool = true

    init(section: OrgSection, initialFoldState: OrgFoldState) {
        self.section = section
        self.initialFoldState = initialFoldState
        // Set initial expansion based on fold state
        let expanded: Bool
        switch initialFoldState {
        case .showAll:
            expanded = true
        case .content:
            // Headings visible, body hidden — only expand to show children, not body
            expanded = true
        case .overview:
            // Only level-1 headings visible
            expanded = section.level <= 1
        }
        _isExpanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Heading row (tappable)
            if let heading = section.heading {
                headingRow(heading)
            }

            // Body and children (collapsible)
            if isExpanded {
                // Body content
                if !section.bodyBlocks.isEmpty {
                    let shouldShowBody = initialFoldState != .content || section.heading == nil
                    if shouldShowBody {
                        bodyContent
                    }
                }

                // Child sections
                ForEach(section.children) { child in
                    OrgSectionView(section: child, initialFoldState: initialFoldState)
                }
            } else if !section.children.isEmpty || !section.bodyBlocks.isEmpty {
                // Collapsed indicator
                Text("...")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .padding(.leading, CGFloat(section.level) * 12 + 24)
                    .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func headingRow(_ heading: OrgBlock) -> some View {
        let hasContent = !section.bodyBlocks.isEmpty || !section.children.isEmpty
        Button {
            if hasContent {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if hasContent {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                        .frame(width: 12)
                } else {
                    Spacer().frame(width: 12)
                }

                headingText(heading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, max(0, CGFloat(section.level - 1) * 12))
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func headingText(_ heading: OrgBlock) -> some View {
        if case .heading(_, let keyword, _, let title, let tags) = heading {
            let titleMd = OrgToMarkdownConverter.serializeInlines(title)
            let mdBlocks: [MarkdownBlock] = [.heading(level: section.level, inlines: [
                keyword.map { kw -> MarkdownInline in .strong([.text(kw)]) },
                keyword != nil ? .text(" ") : nil,
                .text(titleMd),
                tags.isEmpty ? nil : .code("  :" + tags.joined(separator: ":") + ":"),
            ].compactMap { $0 })]

            let md = MarkdownBlockSerializer.serialize(mdBlocks)
            MarkdownContentViewWrapper(
                content: md,
                textSelectionEnabled: true,
                plainTextFallbackThreshold: nil
            )
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        let mdBlocks = OrgToMarkdownConverter.convert(section.bodyBlocks)
        let md = MarkdownBlockSerializer.serialize(mdBlocks)

        if !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MarkdownContentViewWrapper(
                content: md,
                textSelectionEnabled: true,
                plainTextFallbackThreshold: nil
            )
            .padding(.leading, CGFloat(section.level) * 12 + 16)
        }
    }
}
