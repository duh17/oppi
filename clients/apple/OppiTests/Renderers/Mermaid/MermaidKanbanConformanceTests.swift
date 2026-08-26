import CoreGraphics
import CoreText
import Testing
@testable import Oppi

// SPEC: https://mermaid.js.org/syntax/kanban.html
//
// COVERAGE:
// [x] kanban type detection
// [x] columnId[Title] then indented taskId[Description]
// [x] @{ assigned, ticket, priority } with official priority values
// [x] ticketBaseUrl + #TICKET# substitution stored on the task
// [x] leftover priority fails visibly
// [x] gallery fixture layouts inside 360pt
// [x] 360pt cards wrap and stay inside their column
// [x] malformed input does not crash
//
// DEFERRED:
// [ ] tapping ticket links (no link surface on the renderer)
// [ ] ::icon / :::class decorations

@Suite("Kanban Conformance — Mermaid kanban")
struct MermaidKanbanConformanceTests {

    private static let gallery = """
        ---
        config:
          kanban:
            ticketBaseUrl: 'https://example.invalid/browse/#TICKET#'
        ---
        kanban
          backlog[Backlog]
            task1[Collect every diagram type]@{ ticket: MD-1, priority: 'Very High', assigned: 'Chen' }
            task2[Check native vs fallback]@{ ticket: MD-2, priority: 'High' }
          doing[In progress]
            task3[Steer-test on Duh Ifone]@{ ticket: MD-3, assigned: 'Chen' }
          review[Review]
            task4[Fullscreen pinch-zoom]
          done[Done]
            task5[Install Release build]@{ ticket: MD-0, priority: 'Low' }
        """

    @Test func detectsKanbanKeyword() {
        let result = MermaidParser().parse(Self.gallery)
        guard case .kanban = result else {
            Issue.record("Expected kanban, got \(result)")
            return
        }
    }

    @Test func columnsTasksAndMetadata() {
        let result = MermaidParser().parse(Self.gallery)
        guard case .kanban(let diagram) = result else {
            Issue.record("Expected kanban")
            return
        }
        #expect(diagram.ticketBaseUrl == "https://example.invalid/browse/#TICKET#")
        #expect(diagram.columns.map(\.id) == ["backlog", "doing", "review", "done"])
        #expect(diagram.columns.map(\.title) == ["Backlog", "In progress", "Review", "Done"])
        #expect(diagram.columns[0].tasks.count == 2)
        let task1 = diagram.columns[0].tasks[0]
        #expect(task1.id == "task1")
        #expect(task1.description == "Collect every diagram type")
        #expect(task1.ticket == "MD-1")
        #expect(task1.assigned == "Chen")
        #expect(task1.priority == .veryHigh)
        #expect(task1.ticketURL == "https://example.invalid/browse/MD-1")
        #expect(diagram.columns[0].tasks[1].priority == .high)
        #expect(diagram.columns[2].tasks[0].ticket == nil)
        #expect(diagram.columns[3].tasks[0].priority == .low)
    }

    @Test func officialPriorityValues() {
        let diagram = MermaidKanbanParser.parse(lines: [
            "kanban",
            "  todo[Todo]",
            "    a[A]@{ priority: 'Very High' }",
            "    b[B]@{ priority: High }",
            "    c[C]@{ priority: 'Low' }",
            "    d[D]@{ priority: 'Very Low' }",
        ])
        #expect(diagram.columns[0].tasks.map(\.priority) == [
            .veryHigh, .high, .low, .veryLow,
        ])
    }

    @Test func leftoverPriorityFailsVisibly() {
        let diagram = MermaidKanbanParser.parse(lines: [
            "kanban",
            "  todo[Todo]",
            "    a[A]@{ priority: 'Urgent' }",
        ])
        let layout = layoutKanban(diagram, maxWidth: 360)
        #expect(layout.isPlaceholder)
        #expect(layout.placeholderText?.localizedCaseInsensitiveContains("priority") == true)
        #expect(layout.placeholderText?.localizedCaseInsensitiveContains("Urgent") == true)
    }

    @Test func galleryLayoutsWithin360() {
        let result = MermaidParser().parse(Self.gallery)
        guard case .kanban(let diagram) = result else {
            Issue.record("Expected kanban")
            return
        }
        let layout = layoutKanban(diagram, maxWidth: 360)
        #expect(layout.isPlaceholder == false)
        guard let size = layout.customSize else {
            Issue.record("Expected customSize")
            return
        }
        #expect(size.width <= 360)
        #expect(size.height > 0)
        #expect(layout.graphResult.nodePositions["column-0"] != nil)
        #expect(layout.graphResult.nodePositions["task-0-0"] != nil)
        #expect(layout.nodeLabels["$ticket-0-0"] == "MD-1")
        #expect(draw(layout) != nil)
    }

    @Test func galleryCardsStayInsideColumnsAt360() {
        let result = MermaidParser().parse(Self.gallery)
        guard case .kanban(let diagram) = result else {
            Issue.record("Expected kanban")
            return
        }
        let layout = layoutKanban(diagram, maxWidth: 360)
        guard let size = layout.customSize else {
            Issue.record("Expected customSize")
            return
        }
        #expect(layout.isPlaceholder == false)
        #expect(size.width <= 360)

        let positions = layout.graphResult.nodePositions
        let columns = (0..<4).compactMap { positions["column-\($0)"] }
        #expect(columns.count == 4)
        for (index, column) in columns.enumerated() {
            #expect(column.minX >= -0.5, "column-\(index) clips left")
            #expect(column.maxX <= size.width + 0.5, "column-\(index) overflows width")
            if index > 0 {
                #expect(column.minX + 0.5 >= columns[index - 1].maxX, "column-\(index) overlaps previous")
            }
        }

        let bodyFont = CTFontCreateWithName("Helvetica" as CFString, 14 * 0.8, nil)
        let titleFont = CTFontCreateWithName("Helvetica" as CFString, 14 * 0.95, nil)
        for c in 0..<4 {
            guard let column = positions["column-\(c)"] else { continue }
            if let title = layout.nodeLabels["$column-\(c)"] {
                let titleSize = MermaidTextUtils.measureText(
                    title, font: titleFont, fontSize: 14 * 0.95
                )
                #expect(titleSize.width <= column.width - 8 + 1, "column-\(c) title overflows")
            }
            var t = 0
            while let card = positions["task-\(c)-\(t)"] {
                #expect(card.minX >= column.minX - 0.5, "task-\(c)-\(t) leaves its column")
                #expect(card.maxX <= column.maxX + 0.5, "task-\(c)-\(t) overflows its column")
                #expect(card.maxX <= size.width + 0.5, "task-\(c)-\(t) overflows canvas")
                guard let textFrame = positions["task-\(c)-\(t)-text"] else {
                    Issue.record("Expected task-\(c)-\(t)-text inside the card")
                    t += 1
                    continue
                }
                #expect(textFrame.minX >= card.minX - 0.5)
                #expect(textFrame.maxX <= card.maxX + 0.5)
                if let label = layout.nodeLabels["$task-\(c)-\(t)"] {
                    let textSize = MermaidTextUtils.measureText(
                        label, font: bodyFont, fontSize: 14 * 0.8
                    )
                    #expect(textSize.width <= card.width - 12 + 1, "task-\(c)-\(t) text wider than card")
                }
                t += 1
            }
        }

        let firstCard = layout.nodeLabels["$task-0-0"] ?? ""
        #expect(firstCard.contains("Collect"))
        #expect(firstCard.contains("\n"), "long kanban cards must wrap at 360pt")
        #expect(draw(layout) != nil)
    }

    @Test func dispatcherRendersKanbanWithoutPlaceholder() {
        let layout = MermaidRenderer().layout(
            MermaidParser().parse(Self.gallery),
            configuration: .default(maxWidth: 360)
        )
        #expect(layout.isPlaceholder == false)
    }

    @Test func emptyKanbanIsPlaceholder() {
        let layout = layoutKanban(.empty, maxWidth: 360)
        #expect(layout.isPlaceholder)
    }

    @Test func malformedDoesNotCrash() {
        _ = MermaidParser().parse("kanban\n  [no-id]")
        _ = MermaidKanbanParser.parse(lines: ["kanban", "    task without column"])
        _ = MermaidKanbanParser.parse(lines: ["kanban", "  col[Col]", "    t[T]@{ assigned: }"])
    }
}

private func layoutKanban(
    _ diagram: KanbanDiagram,
    maxWidth: CGFloat
) -> MermaidFlowchartRenderer.FlowchartLayout {
    MermaidKanbanRenderer.layout(diagram, configuration: .default(maxWidth: maxWidth))
}

private func draw(_ layout: MermaidFlowchartRenderer.FlowchartLayout) -> Bool? {
    guard let size = layout.customSize, let draw = layout.customDraw else { return nil }
    let width = max(Int(ceil(size.width)), 1)
    let height = max(Int(ceil(size.height)), 1)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(
            data: raw.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        draw(ctx, .zero)
        return true
    }
    return ok ? true : nil
}
