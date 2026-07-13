import SwiftUI

// MARK: - Org Section Tree

/// A section in the org document tree.
struct OrgSection: Identifiable, Sendable {
    let id = UUID()
    let level: Int
    let heading: OrgBlock?
    let bodyBlocks: [OrgBlock]
    let children: [OrgSection]
    /// Pre-computed body groups for rendering. Computed once during tree build
    /// so the SwiftUI body evaluation does zero markdown conversion.
    let precomputedBodyGroups: [OrgBodyGroup]

    var hasContent: Bool { !bodyBlocks.isEmpty || !children.isEmpty }
}

/// A body group — either a drawer (rendered natively) or pre-serialized markdown text.
enum OrgBodyGroup: Sendable {
    case drawer(name: String, properties: [OrgDrawerProperty])
    case markdown(String)
}

/// Initial fold state from `#+STARTUP:`.
enum OrgFoldState: Sendable {
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
        sections.append(OrgSection(level: 0, heading: nil, bodyBlocks: zerothBody, children: [], precomputedBodyGroups: computeBodyGroups(zerothBody)))
    }

    sections.append(contentsOf: parseHeadingSections(blocks: blocks, cursor: &cursor, parentLevel: 0))
    return (sections, foldState)
}

/// Pre-compute body groups: split on drawers, convert non-drawer blocks to markdown text.
/// Called during tree build (off main thread via Task.detached).
private func computeBodyGroups(_ blocks: [OrgBlock]) -> [OrgBodyGroup] {
    var groups: [OrgBodyGroup] = []
    var pending: [OrgBlock] = []

    func flushPending() {
        guard !pending.isEmpty else { return }
        let md = OrgToMarkdownConverter.serializeDirectly(pending)
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
        sections.append(OrgSection(level: level, heading: heading, bodyBlocks: body, children: children, precomputedBodyGroups: computeBodyGroups(body)))
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
        if section.heading == nil {
            // Zeroth section — body only, no heading
            sectionBody
        } else {
            // Heading + body. Spacing is 0 because the MarkdownContentViewWrapper
            // already applies paragraphSpacingBefore internally (matching markdown:
            // H1=20pt, H2=16pt, H3=12pt, H4=8pt).
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
            // Native SwiftUI text rendering — avoids MarkdownContentViewWrapper
            // roundtrip (org → markdown string → CommonMark parse → UIKit view).
            // Eliminates one UIKit view creation + Auto Layout per heading.
            OrgNativeHeadingView(
                heading: section.heading ?? .comment(""),
                level: section.level,
                hasContent: section.hasContent,
                isExpanded: isExpanded
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Body + children

    @ViewBuilder
    private var sectionBody: some View {
        // Use pre-computed body groups — conversion done during tree build (off main thread).
        ForEach(Array(section.precomputedBodyGroups.enumerated()), id: \.offset) { _, group in
            switch group {
            case .drawer(let name, let properties):
                OrgDrawerView(name: name, properties: properties)
            case .markdown(let md):
                if !md.isEmpty {
                    MarkdownContentViewWrapper(
                        content: md,
                        textSelectionEnabled: true,
                    )
                }
            }
        }

        // Child sections — no indentation, heading sizes communicate hierarchy
        ForEach(section.children) { child in
            OrgSectionView(section: child, initialFoldState: initialFoldState, depth: depth + 1)
        }
    }
}

// MARK: - Native Heading View

/// Renders an org heading directly as SwiftUI Text — no MarkdownContentViewWrapper.
/// Matches the visual style of markdown headings (font sizes, bold, colors)
/// while avoiding the org → markdown → CommonMark → UIKit roundtrip.
private struct OrgNativeHeadingView: View {
    let heading: OrgBlock
    let level: Int
    let hasContent: Bool
    let isExpanded: Bool

    // Heading font sizes matching markdown pipeline (H1=24, H2=20, H3=17, H4+=15)
    private var fontSize: CGFloat {
        switch level {
        case 1: return 24
        case 2: return 20
        case 3: return 17
        default: return 15
        }
    }

    // Paragraph spacing before heading (matching MarkdownContentViewWrapper)
    private var topPadding: CGFloat {
        switch level {
        case 1: return 20
        case 2: return 16
        case 3: return 12
        default: return 8
        }
    }

    private var bullet: String {
        let expandedBullets = ["◈", "•", "‣", "◦", "·", "·"]
        let collapsedBullets = ["◇", "◦", "▹", "·", "·", "·"]
        let idx = min(level - 1, expandedBullets.count - 1)
        return (hasContent && !isExpanded) ? collapsedBullets[idx] : expandedBullets[idx]
    }

    var body: some View {
        guard case .heading(_, let keyword, _, let title, let tags) = heading else {
            return Text("").eraseToAnyView()
        }

        return buildHeadingText(keyword: keyword, title: title, tags: tags)
            .padding(.top, topPadding)
            .eraseToAnyView()
    }

    private func concatenate(_ lhs: Text, _ rhs: Text) -> Text {
        Text("\(lhs)\(rhs)")
    }

    private func buildHeadingText(keyword: String?, title: [OrgInline], tags: [String]) -> Text {
        var text = Text("\(bullet) ")
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(.themeMdHeading)

        if let kw = keyword {
            text = concatenate(
                text,
                Text("\(kw) ")
                    .font(.system(size: fontSize, weight: .heavy))
                    .foregroundStyle(kw == "DONE" ? ThemeShapeStyle(role: .green) : ThemeShapeStyle(role: .orange))
            )
        }

        for inline in title {
            text = concatenate(text, renderInline(inline, baseSize: fontSize))
        }

        if !tags.isEmpty {
            text = concatenate(text, Text("  "))
            text = concatenate(
                text,
                Text(":" + tags.joined(separator: ":") + ":")
                    .font(.system(size: max(fontSize - 4, 11), design: .monospaced))
                    .foregroundStyle(.themeComment)
            )
        }

        return text
    }

    private func renderInline(_ inline: OrgInline, baseSize: CGFloat) -> Text {
        switch inline {
        case .text(let str):
            return Text(str)
                .font(.system(size: baseSize, weight: .bold))
                .foregroundStyle(.themeMdHeading)
        case .bold(let children):
            return children.reduce(Text("")) { concatenate($0, renderInline($1, baseSize: baseSize)) }
        case .italic(let children):
            let inner = children.reduce(Text("")) { concatenate($0, renderInline($1, baseSize: baseSize)) }
            return inner.italic()
        case .code(let str), .verbatim(let str):
            return Text(str)
                .font(.system(size: max(baseSize - 2, 11), design: .monospaced))
                .foregroundStyle(.themeFg)
        case .underline(let children):
            let inner = children.reduce(Text("")) { concatenate($0, renderInline($1, baseSize: baseSize)) }
            return inner.underline()
        case .strikethrough(let children):
            let inner = children.reduce(Text("")) { concatenate($0, renderInline($1, baseSize: baseSize)) }
            return inner.strikethrough()
        case .link(_, let description):
            let label = description?.map { inlineToString($0) }.joined() ?? "link"
            return Text(label)
                .font(.system(size: baseSize, weight: .bold))
                .foregroundStyle(.themeBlue)
        }
    }

    private func inlineToString(_ inline: OrgInline) -> String {
        switch inline {
        case .text(let s): return s
        case .bold(let c), .italic(let c), .underline(let c), .strikethrough(let c):
            return c.map { inlineToString($0) }.joined()
        case .code(let s), .verbatim(let s): return s
        case .link(let url, let desc): return desc?.map { inlineToString($0) }.joined() ?? url
        }
    }
}

private extension View {
    func eraseToAnyView() -> AnyView { AnyView(self) }
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
