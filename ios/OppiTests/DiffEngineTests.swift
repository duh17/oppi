import Testing
@testable import Oppi

@Suite("DiffEngine")
struct DiffEngineTests {

    @Test func emptyBoth() {
        let result = DiffEngine.compute(old: "", new: "")
        #expect(result.isEmpty)
    }

    @Test func emptyOldAllAdded() {
        let result = DiffEngine.compute(old: "", new: "a\nb\nc")
        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.kind == .added })
        #expect(result.map(\.text) == ["a", "b", "c"])
    }

    @Test func emptyNewAllRemoved() {
        let result = DiffEngine.compute(old: "a\nb\nc", new: "")
        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.kind == .removed })
        #expect(result.map(\.text) == ["a", "b", "c"])
    }

    @Test func identicalTexts() {
        let text = "line1\nline2\nline3"
        let result = DiffEngine.compute(old: text, new: text)
        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.kind == .context })
    }

    @Test func singleLineChange() {
        let result = DiffEngine.compute(old: "hello", new: "world")
        let removed = result.filter { $0.kind == .removed }
        let added = result.filter { $0.kind == .added }
        #expect(removed.count == 1)
        #expect(removed[0].text == "hello")
        #expect(added.count == 1)
        #expect(added[0].text == "world")
    }

    @Test func contextPreserved() {
        let old = "a\nb\nc"
        let new = "a\nB\nc"
        let result = DiffEngine.compute(old: old, new: new)

        #expect(result.count == 4) // context a, removed b, added B, context c
        #expect(result[0] == DiffLine(kind: .context, text: "a"))
        #expect(result[1] == DiffLine(kind: .removed, text: "b"))
        #expect(result[2] == DiffLine(kind: .added, text: "B"))
        #expect(result[3] == DiffLine(kind: .context, text: "c"))
    }

    @Test func multipleEdits() {
        let old = "a\nb\nc\nd\ne"
        let new = "a\nB\nc\nD\ne"
        let result = DiffEngine.compute(old: old, new: new)

        let context = result.filter { $0.kind == .context }
        let removed = result.filter { $0.kind == .removed }
        let added = result.filter { $0.kind == .added }

        #expect(context.count == 3) // a, c, e
        #expect(removed.count == 2) // b, d
        #expect(added.count == 2)   // B, D
    }

    @Test func insertedLines() {
        let old = "a\nc"
        let new = "a\nb\nc"
        let result = DiffEngine.compute(old: old, new: new)

        #expect(result.count == 3)
        #expect(result[0] == DiffLine(kind: .context, text: "a"))
        #expect(result[1] == DiffLine(kind: .added, text: "b"))
        #expect(result[2] == DiffLine(kind: .context, text: "c"))
    }

    @Test func deletedLines() {
        let old = "a\nb\nc"
        let new = "a\nc"
        let result = DiffEngine.compute(old: old, new: new)

        #expect(result.count == 3)
        #expect(result[0] == DiffLine(kind: .context, text: "a"))
        #expect(result[1] == DiffLine(kind: .removed, text: "b"))
        #expect(result[2] == DiffLine(kind: .context, text: "c"))
    }

    @Test func trailingNewlineHandled() {
        let old = "a\nb\n"
        let new = "a\nc\n"
        let result = DiffEngine.compute(old: old, new: new)

        let removed = result.filter { $0.kind == .removed }
        let added = result.filter { $0.kind == .added }
        #expect(removed.count == 1)
        #expect(removed[0].text == "b")
        #expect(added.count == 1)
        #expect(added[0].text == "c")
    }

    // MARK: - Stats

    @Test func statsCountsCorrectly() {
        let lines = [
            DiffLine(kind: .context, text: "a"),
            DiffLine(kind: .added, text: "b"),
            DiffLine(kind: .added, text: "c"),
            DiffLine(kind: .removed, text: "d"),
        ]
        let (added, removed) = DiffEngine.stats(lines)
        #expect(added == 2)
        #expect(removed == 1)
    }

    @Test func statsEmpty() {
        let (added, removed) = DiffEngine.stats([])
        #expect(added == 0)
        #expect(removed == 0)
    }

    // MARK: - Format

    @Test func formatUnified() {
        let lines = [
            DiffLine(kind: .context, text: "a"),
            DiffLine(kind: .removed, text: "b"),
            DiffLine(kind: .added, text: "B"),
        ]
        let formatted = DiffEngine.formatUnified(lines)
        #expect(formatted == "  a\n- b\n+ B")
    }

    // MARK: - DiffLine.Kind.prefix

    @Test func kindPrefixes() {
        #expect(DiffLine.Kind.context.prefix == " ")
        #expect(DiffLine.Kind.added.prefix == "+")
        #expect(DiffLine.Kind.removed.prefix == "-")
    }
}

// Make DiffLine Equatable for test assertions
extension DiffLine: @retroactive Equatable {
    public static func == (lhs: DiffLine, rhs: DiffLine) -> Bool {
        lhs.kind == rhs.kind && lhs.text == rhs.text
    }
}
