import Foundation

/// Which top-level blocks of an Org document a reader shows when some
/// headings are folded. A heading's section is everything after it up to the
/// next heading of the same or a higher level (a lower star count), so a
/// folded heading hides its sub-headings with its body.
///
/// A heading is named by its ordinal: its 1-based place among the document's
/// top-level headings. Unlike a source line, an ordinal survives a task edit
/// (a checkbox, a state, a planning line) that moves the lines below it, so a
/// reader keeps its folds across a save.
enum OrgFolding {
    /// Each top-level heading's ordinal, by the source line it starts on.
    static func ordinals(of blocks: [LocatedOrgBlock]) -> [Int: Int] {
        var ordinals: [Int: Int] = [:]
        for located in blocks {
            if case .heading = located.block { ordinals[located.line] = ordinals.count + 1 }
        }
        return ordinals
    }

    /// The blocks under each foldable heading, keyed by the heading's source
    /// line. A heading with nothing under it is not foldable and is left out.
    static func sections(of blocks: [LocatedOrgBlock]) -> [Int: Range<Int>] {
        var sections: [Int: Range<Int>] = [:]
        // Headings whose section is still open, shallowest first.
        var open: [(level: Int, line: Int, start: Int)] = []
        func close(at end: Int, downTo level: Int) {
            while let last = open.last, last.level >= level {
                open.removeLast()
                if end > last.start { sections[last.line] = last.start..<end }
            }
        }
        for (index, located) in blocks.enumerated() {
            guard case .heading(let level, _, _, _, _) = located.block else { continue }
            close(at: index, downTo: level)
            open.append((level, located.line, index + 1))
        }
        close(at: blocks.count, downTo: Int.min)
        return sections
    }

    /// Indices of the blocks left showing once the headings on `folded` lines
    /// hide their sections.
    static func visibleIndices(
        of blocks: [LocatedOrgBlock],
        sections: [Int: Range<Int>],
        folded: Set<Int>
    ) -> [Int] {
        guard !folded.isEmpty else { return Array(blocks.indices) }
        var visible: [Int] = []
        var index = 0
        while index < blocks.count {
            visible.append(index)
            if case .heading = blocks[index].block,
               folded.contains(blocks[index].line),
               let section = sections[blocks[index].line] {
                index = section.upperBound
            } else {
                index += 1
            }
        }
        return visible
    }
}
