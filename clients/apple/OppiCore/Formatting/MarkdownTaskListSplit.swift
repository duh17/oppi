import Foundation

/// Splits task lists around the blocks a reader draws only as their own
/// segments: code blocks, tables and rules.
///
/// A task list draws as one run of text, so a code block or table inside a
/// task item would otherwise not draw at all. Plain lists already lift those
/// blocks into segments of their own; a task list is split here first, so
/// nothing an item holds is dropped. A lifted block, and whatever follows it
/// in its item, loses its indentation under the item.
enum MarkdownTaskListSplit {
    /// `blocks` with every task list that holds such a block split around it,
    /// each piece keeping the source line range of the block it came from.
    static func split(
        _ blocks: [MarkdownBlock],
        lineRanges: [ClosedRange<Int>?]?
    ) -> ([MarkdownBlock], [ClosedRange<Int>?]?) {
        guard blocks.contains(where: needsSplit) else { return (blocks, lineRanges) }
        var expanded: [MarkdownBlock] = []
        var ranges: [ClosedRange<Int>?] = []
        for (index, block) in blocks.enumerated() {
            let range = lineRanges.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            let pieces = split(block)
            expanded.append(contentsOf: pieces)
            ranges.append(contentsOf: repeatElement(range, count: pieces.count))
        }
        return (expanded, lineRanges == nil ? nil : ranges)
    }

    /// One block as the pieces it draws as: a task list split around its
    /// segment blocks, and a plain list whose items hold such a task list with
    /// the pieces spliced into those items, where the plain list draws them.
    private static func split(_ block: MarkdownBlock) -> [MarkdownBlock] {
        guard needsSplit(block) else { return [block] }
        switch block {
        case .taskList(let items):
            return taskListPieces(items)
        case .unorderedList(let items):
            return [.unorderedList(items.map { $0.flatMap(split) })]
        case .orderedList(let start, let items):
            return [.orderedList(start: start, items.map { $0.flatMap(split) })]
        default:
            return [block]
        }
    }

    private static func taskListPieces(_ items: [MarkdownBlock.TaskItem]) -> [MarkdownBlock] {
        var pieces: [MarkdownBlock] = []
        var run: [MarkdownBlock.TaskItem] = []
        for item in items {
            var kept: [MarkdownBlock] = []
            var lifted: [MarkdownBlock] = []
            for block in item.content {
                if case .taskList = block, holdsSegmentBlock(block) {
                    // The nested list's first run of items stays nested.
                    var nested = split(block)[...]
                    if lifted.isEmpty, case .taskList? = nested.first { kept.append(nested.removeFirst()) }
                    lifted.append(contentsOf: nested)
                } else if lifted.isEmpty, !holdsSegmentBlock(block) {
                    kept.append(block)
                } else {
                    lifted.append(contentsOf: split(block))
                }
            }
            run.append(MarkdownBlock.TaskItem(
                checked: item.checked, content: kept, sourceLine: item.sourceLine, isPartial: item.isPartial
            ))
            if !lifted.isEmpty {
                pieces.append(.taskList(run))
                run.removeAll()
                pieces.append(contentsOf: lifted)
            }
        }
        if !run.isEmpty { pieces.append(.taskList(run)) }
        return pieces
    }

    /// Whether `block` is a task list holding a segment block at any depth, or
    /// a plain list with such a task list somewhere in it.
    private static func needsSplit(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .taskList:
            holdsSegmentBlock(block)
        case .unorderedList(let items), .orderedList(_, let items):
            items.contains { $0.contains(where: needsSplit) }
        default:
            false
        }
    }

    /// Whether `block` is, or holds at any depth, a code block, table or rule.
    private static func holdsSegmentBlock(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .codeBlock, .table, .thematicBreak, .math:
            true
        case .taskList(let items):
            items.contains { $0.content.contains(where: holdsSegmentBlock) }
        case .unorderedList(let items), .orderedList(_, let items):
            items.contains { $0.contains(where: holdsSegmentBlock) }
        case .blockQuote(let children):
            children.contains(where: holdsSegmentBlock)
        case .paragraph, .heading, .htmlBlock:
            false
        }
    }
}
