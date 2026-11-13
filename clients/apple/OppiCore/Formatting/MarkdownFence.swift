/// The fence of a fenced code block, read from one line's UTF-8 bytes: three
/// or more backticks or tildes after any spaces and tabs. The Markdown glue
/// checks fences around cmark (the table repair skips fenced code, the
/// streaming driver asks whether a fence has closed, and code cleanup finds a
/// stray inner fence); this is the one scanner they share.
enum MarkdownFence {
    /// The fence `line` opens with: its byte, its length, and what follows it
    /// (an info string, or nothing).
    static func opening<Line: Collection<UInt8>>(
        _ line: Line
    ) -> (byte: UInt8, count: Int, rest: Line.SubSequence)? {
        let trimmed = line.drop { $0 == 0x20 || $0 == 0x09 }
        guard let first = trimmed.first, first == UInt8(ascii: "`") || first == UInt8(ascii: "~") else { return nil }
        let count = trimmed.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        return (first, count, trimmed.dropFirst(count))
    }

    /// Whether `line` closes a fence of `byte` at least `count` long: that
    /// fence and nothing after it but blanks.
    static func closes<Line: Collection<UInt8>>(_ line: Line, byte: UInt8, count: Int) -> Bool {
        guard let fence = opening(line), fence.byte == byte, fence.count >= count else { return false }
        return fence.rest.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
    }
}
