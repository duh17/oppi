import SwiftUI

// MARK: - Org Section Tree

/// A section in the org document tree.
struct OrgSection: Identifiable {
    let id = UUID()
    let level: Int
    let heading: OrgBlock?
    let bodyBlocks: [OrgBlock]
    let children: [OrgSection]

    var hasContent: Bool { !bodyBlocks.isEmpty || !children.isEmpty }
}

/// Initial fold state from `#+STARTUP:`.
enum OrgFoldState {
    case overview  // only level-1 headings
    case content   // all headings, body hidden initially
    case showAll   // everything expanded
}

// MARK: - Build section tree

func buildOrgSectionTree(_ blocks: [OrgBlock]) -> (sections: [OrgSection], foldState: OrgFoldState) {
    var foldState: OrgFoldState = .showAll

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

    // Zeroth section
    var zerothBody: [OrgBlock] = []
    while cursor < blocks.count {
        if case .heading = blocks[cursor] { break }
        zerothBody.append(blocks[cursor])
        cursor += 1
    }
    if !zerothBody.isEmpty {
        sections.append(OrgSection(level: 0, heading: nil, bodyBlocks: zerothBody, children: []))
    }

    sections.append(contentsOf: parseHeadingSections(blocks: blocks, cursor: &cursor, parentLevel: 0))
    return (sections, foldState)
}

private func parseHeadingSections(blocks: [OrgBlock], cursor: inout Int, parentLevel: Int) -> [OrgSection] {
    var sections: [OrgSection] = []

    while cursor < blocks.count {
        guard case .heading(let level, _, _, _, _) = blocks[cursor], level > parentLevel else { break }

        let heading = blocks[cursor]
        cursor += 1

        var body: [OrgBlock] = []
        while cursor < blocks.count {
            if case .heading = blocks[cursor] { break }
            body.append(blocks[cursor])
            cursor += 1
        }

        let children = parseHeadingSections(blocks: blocks, cursor: &cursor, parentLevel: level)
        sections.append(OrgSection(level: level, heading: heading, bodyBlocks: body, children: children))
    }

    return sections
}

// MARK: - Foldable Org View

struct OrgFoldableContentView: View {
    let sections: [OrgSection]
    let initialFoldState: OrgFoldState

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                OrgSectionView(section: section, initialFoldState: initialFoldState, depth: 0)
            }
        }
    }
}

// MARK: - Section View

private struct OrgSectionView: View {
    let section: OrgSection
    let initialFoldState: OrgFoldState
    let depth: Int
    @State private var isExpanded: Bool

    init(section: OrgSection, initialFoldState: OrgFoldState, depth: Int) {
        self.section = section
        self.initialFoldState = initialFoldState
        self.depth = depth

        let expanded: Bool
        switch initialFoldState {
        case .showAll: expanded = true
        case .content: expanded = false
        case .overview: expanded = section.level <= 1
        }
        // Zeroth section (no heading) is always expanded
        if section.heading == nil { _isExpanded = State(initialValue: true) }
        else { _isExpanded = State(initialValue: expanded) }
    }

    var body: some View {
        // Zeroth section — just render body, no heading
        if section.heading == nil {
            sectionBody
        } else {
            VStack(alignment: .leading, spacing: 0) {
                headingRow
                if isExpanded {
                    sectionBody
                }
            }
        }
    }

    // MARK: - Heading row

    private var headingRow: some View {
        Button {
            if section.hasContent {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }
        } label: {
            // Render the entire heading (including fold indicator) as one markdown
            // block through the markdown pipeline. This guarantees the chevron
            // aligns with the text since it's part of the same text flow.
            MarkdownContentViewWrapper(
                content: headingMarkdown,
                textSelectionEnabled: false,
                plainTextFallbackThreshold: nil
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var headingMarkdown: String {
        guard case .heading(let level, let keyword, _, let title, let tags) = section.heading else {
            return ""
        }
        var inlines = [MarkdownInline]()

        // Fold indicator as part of the heading text
        if section.hasContent {
            let indicator = isExpanded ? "▾ " : "▸ "
            inlines.append(.text(indicator))
        }

        if let kw = keyword {
            inlines.append(.strong([.text(kw)]))
            inlines.append(.text(" "))
        }
        inlines.append(contentsOf: title.map { OrgToMarkdownConverter.convertSingleInline($0) })
        if !tags.isEmpty {
            inlines.append(.text("  "))
            inlines.append(.code(":" + tags.joined(separator: ":") + ":"))
        }
        let mdBlocks: [MarkdownBlock] = [.heading(level: min(level, 6), inlines: inlines)]
        return MarkdownBlockSerializer.serialize(mdBlocks)
    }

    // MARK: - Body + children

    @ViewBuilder
    private var sectionBody: some View {
        // Split body blocks: drawers get special UI, everything else goes through markdown.
        let groups = groupBodyBlocks(section.bodyBlocks)
        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
            switch group {
            case .drawer(let name, let properties):
                OrgDrawerView(name: name, properties: properties)
                    .padding(.leading, 16)
            case .markdown(let md):
                if !md.isEmpty {
                    MarkdownContentViewWrapper(
                        content: md,
                        textSelectionEnabled: true,
                        plainTextFallbackThreshold: nil
                    )
                    .padding(.leading, 16)
                }
            }
        }

        // Child sections
        ForEach(section.children) { child in
            OrgSectionView(section: child, initialFoldState: initialFoldState, depth: depth + 1)
                .padding(.leading, 12)
        }
    }

    private enum BodyGroup {
        case drawer(name: String, properties: [OrgDrawerProperty])
        case markdown(String)
    }

    private func groupBodyBlocks(_ blocks: [OrgBlock]) -> [BodyGroup] {
        var groups: [BodyGroup] = []
        var pending: [OrgBlock] = []

        func flushPending() {
            guard !pending.isEmpty else { return }
            let mdBlocks = OrgToMarkdownConverter.convert(pending)
            let md = MarkdownBlockSerializer.serialize(mdBlocks)
            let trimmed = md.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                groups.append(.markdown(trimmed))
            }
            pending = []
        }

        for block in blocks {
            if case .drawer(let name, let props) = block {
                flushPending()
                groups.append(.drawer(name: name, properties: props))
            } else {
                pending.append(block)
            }
        }
        flushPending()
        return groups
    }
}

// MARK: - Collapsible Drawer View

private struct OrgDrawerView: View {
    let name: String
    let properties: [OrgDrawerProperty]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .medium))
                    Text(name)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(.themeComment)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(properties.enumerated()), id: \.offset) { _, prop in
                        HStack(spacing: 0) {
                            Text(":\(prop.key):")
                                .foregroundStyle(.themePurple)
                            Text(" \(prop.value)")
                                .foregroundStyle(.themeFgDim)
                        }
                        .font(.system(size: 12, design: .monospaced))
                    }
                }
                .padding(.leading, 14)
                .padding(.bottom, 4)
            }
        }
    }
}

// Uses .themeMdHeading, .themeGreen, .themeOrange from the existing theme color extensions.
