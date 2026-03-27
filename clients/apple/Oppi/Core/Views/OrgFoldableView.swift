import SwiftUI

// MARK: - Org Section Tree

/// A section in the org document tree.
struct OrgSection: Identifiable {
    let id: Int  // stable index for fold state
    let level: Int
    let heading: OrgBlock?
    let bodyBlocks: [OrgBlock]
    let children: [OrgSection]

    var hasContent: Bool { !bodyBlocks.isEmpty || !children.isEmpty }
}

/// Initial fold state from `#+STARTUP:`.
enum OrgFoldState: Equatable {
    case overview
    case content
    case showAll
}

// MARK: - Build section tree

func buildOrgSectionTree(_ blocks: [OrgBlock]) -> (sections: [OrgSection], foldState: OrgFoldState) {
    var foldState: OrgFoldState = .showAll
    var nextId = 0

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
        let id = nextId; nextId += 1
        sections.append(OrgSection(id: id, level: 0, heading: nil, bodyBlocks: zerothBody, children: []))
    }

    sections.append(contentsOf: parseHeadingSections(blocks: blocks, cursor: &cursor, parentLevel: 0, nextId: &nextId))
    return (sections, foldState)
}

private func parseHeadingSections(blocks: [OrgBlock], cursor: inout Int, parentLevel: Int, nextId: inout Int) -> [OrgSection] {
    var sections: [OrgSection] = []

    while cursor < blocks.count {
        guard case .heading(let level, _, _, _, _) = blocks[cursor], level > parentLevel else { break }

        let heading = blocks[cursor]
        let id = nextId; nextId += 1
        cursor += 1

        var body: [OrgBlock] = []
        while cursor < blocks.count {
            if case .heading = blocks[cursor] { break }
            body.append(blocks[cursor])
            cursor += 1
        }

        let children = parseHeadingSections(blocks: blocks, cursor: &cursor, parentLevel: level, nextId: &nextId)
        sections.append(OrgSection(id: id, level: level, heading: heading, bodyBlocks: body, children: children))
    }

    return sections
}

// MARK: - Generate markdown with fold state

/// Generate markdown for an org section tree, respecting fold state.
/// Collapsed headings show the heading with a collapsed bullet but omit body and children.
/// Heading text includes a tappable link for fold toggle.
func generateOrgMarkdown(
    sections: [OrgSection],
    foldedIds: Set<Int>
) -> String {
    var lines: [String] = []

    func emitSection(_ section: OrgSection) {
        if let heading = section.heading {
            // Emit heading with bullet
            if case .heading(let level, let keyword, _, let title, let tags) = heading {
                let isFolded = foldedIds.contains(section.id)

                let expandedBullets = ["◈", "•", "‣", "◦", "·", "·"]
                let collapsedBullets = ["◇", "◦", "▹", "·", "·", "·"]
                let idx = min(level - 1, expandedBullets.count - 1)
                let bullet: String
                if section.hasContent {
                    bullet = isFolded ? collapsedBullets[idx] : expandedBullets[idx]
                } else {
                    bullet = expandedBullets[idx]
                }

                let prefix = String(repeating: "#", count: min(level, 6))
                var parts = [String]()
                parts.append(bullet)
                if let kw = keyword { parts.append("**\(kw)**") }
                parts.append(OrgToMarkdownConverter.serializeInlines(title))
                if !tags.isEmpty {
                    parts.append(" `:" + tags.joined(separator: ":") + ":`")
                }
                let headingText = parts.joined(separator: " ")

                if section.hasContent {
                    // Wrap heading in a link for fold toggle
                    lines.append("\(prefix) [\(headingText)](oppi://org-fold/\(section.id))")
                } else {
                    lines.append("\(prefix) \(headingText)")
                }

                if !isFolded {
                    // Emit body
                    let bodyMd = MarkdownBlockSerializer.serialize(
                        OrgToMarkdownConverter.convert(section.bodyBlocks)
                    )
                    if !bodyMd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lines.append("")
                        lines.append(bodyMd)
                    }

                    // Emit children
                    for child in section.children {
                        lines.append("")
                        emitSection(child)
                    }
                }
            }
        } else {
            // Zeroth section — just body
            let bodyMd = MarkdownBlockSerializer.serialize(
                OrgToMarkdownConverter.convert(section.bodyBlocks)
            )
            if !bodyMd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(bodyMd)
            }
        }
    }

    for section in sections {
        if !lines.isEmpty { lines.append("") }
        emitSection(section)
    }

    return lines.joined(separator: "\n")
}

// MARK: - Foldable Org View (UIKit-backed, single MarkdownContentViewWrapper)

/// Renders an org document through a single MarkdownContentViewWrapper.
/// Fold state is managed here; toggling regenerates the markdown string.
struct OrgFoldableContentView: View {
    let sections: [OrgSection]
    let initialFoldState: OrgFoldState
    @State private var foldedIds: Set<Int> = []
    @State private var initialized = false

    var body: some View {
        let md = generateOrgMarkdown(sections: sections, foldedIds: foldedIds)
        MarkdownContentViewWrapper(
            content: md,
            textSelectionEnabled: true,
            plainTextFallbackThreshold: nil
        )
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "oppi", url.host == "org-fold",
               let idStr = url.pathComponents.last,
               let sectionId = Int(idStr) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if foldedIds.contains(sectionId) {
                        foldedIds.remove(sectionId)
                    } else {
                        foldedIds.insert(sectionId)
                    }
                }
                return .handled
            }
            return .systemAction
        })
        .onAppear {
            guard !initialized else { return }
            initialized = true
            // Set initial fold state
            switch initialFoldState {
            case .showAll:
                foldedIds = []
            case .content:
                foldedIds = Set(allSectionIds(sections).filter { id in
                    findSection(id: id, in: sections)?.hasContent == true
                })
            case .overview:
                foldedIds = Set(allSectionIds(sections).filter { id in
                    guard let s = findSection(id: id, in: sections) else { return false }
                    return s.level > 1 && s.hasContent
                })
            }
        }
    }

    private func allSectionIds(_ sections: [OrgSection]) -> [Int] {
        sections.flatMap { [$0.id] + allSectionIds($0.children) }
    }

    private func findSection(id: Int, in sections: [OrgSection]) -> OrgSection? {
        for s in sections {
            if s.id == id { return s }
            if let found = findSection(id: id, in: s.children) { return found }
        }
        return nil
    }
}
