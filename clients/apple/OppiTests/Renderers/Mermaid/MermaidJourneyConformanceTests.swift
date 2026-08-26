import CoreGraphics
import Testing
@testable import Oppi

// SPEC: https://mermaid.js.org/syntax/userJourney.html
//
// COVERAGE:
// [x] journey type detection
// [x] title
// [x] section
// [x] Task name: <score 1-5>: actor, actor
// [x] gallery fixture parses and layouts inside 360pt
// [x] leftover score outside 1-5 fails visibly
// [x] malformed input does not crash
// [x] empty journey is a placeholder
//
// DEFERRED:
// [ ] accTitle / accDescr

@Suite("Journey Conformance — Mermaid userJourney")
struct MermaidJourneyConformanceTests {

    private static let gallery = """
        journey
          title My working day
          section Go to work
            Make tea: 5: Me
            Go upstairs: 3: Me
            Do work: 1: Me, Cat
          section Go home
            Go downstairs: 5: Me
            Sit down: 5: Me
        """

    @Test func detectsJourneyKeyword() {
        let result = MermaidParser().parse(Self.gallery)
        guard case .journey = result else {
            Issue.record("Expected journey, got \(result)")
            return
        }
    }

    @Test func officialTaskSyntax() {
        let diagram = MermaidJourneyParser.parse(lines: Self.gallery.components(separatedBy: "\n"))
        #expect(diagram.title == "My working day")
        #expect(diagram.sections.count == 2)
        #expect(diagram.sections[0].name == "Go to work")
        #expect(diagram.sections[0].tasks.map(\.name) == ["Make tea", "Go upstairs", "Do work"])
        #expect(diagram.sections[0].tasks.map(\.score) == [5, 3, 1])
        #expect(diagram.sections[0].tasks[2].actors == ["Me", "Cat"])
        #expect(diagram.sections[1].name == "Go home")
        #expect(diagram.sections[1].tasks.map(\.score) == [5, 5])
        #expect(diagram.error == nil)
    }

    @Test func galleryLayoutsWithin360() {
        let result = MermaidParser().parse(Self.gallery)
        guard case .journey(let diagram) = result else {
            Issue.record("Expected journey")
            return
        }
        let layout = layoutJourney(diagram, maxWidth: 360)
        #expect(layout.isPlaceholder == false)
        guard let size = layout.customSize else {
            Issue.record("Expected customSize")
            return
        }
        #expect(size.width > 0)
        #expect(size.width <= 360)
        #expect(size.height > 0)
        #expect(layout.nodeLabels["$title"] == "My working day")
        #expect(layout.graphResult.nodePositions["section-0"] != nil)
        #expect(layout.graphResult.nodePositions["task-0-0"] != nil)
        #expect(draw(layout) != nil)
    }

    @Test func dispatcherRendersJourneyWithoutPlaceholder() {
        let layout = MermaidRenderer().layout(
            MermaidParser().parse(Self.gallery),
            configuration: .default(maxWidth: 360)
        )
        #expect(layout.isPlaceholder == false)
        let size = MermaidRenderer().boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.width <= 360)
    }

    @Test func scoreOutsideRangeFailsVisibly() {
        let diagram = MermaidJourneyParser.parse(lines: [
            "journey",
            "    title Bad",
            "    section Work",
            "        Make tea: 9: Me",
        ])
        #expect(diagram.error?.localizedCaseInsensitiveContains("score") == true)
        let layout = layoutJourney(diagram, maxWidth: 360)
        #expect(layout.isPlaceholder)
        #expect(layout.placeholderText?.localizedCaseInsensitiveContains("score") == true)
    }

    @Test func emptyJourneyIsPlaceholder() {
        let layout = layoutJourney(.empty, maxWidth: 360)
        #expect(layout.isPlaceholder)
    }

    @Test func commentsAndBlanksIgnored() {
        let diagram = MermaidJourneyParser.parse(lines: [
            "%% comment",
            "journey",
            "",
            "    title Demo",
            "    section A",
            "        Task: 2: Alice",
        ])
        #expect(diagram.title == "Demo")
        #expect(diagram.sections.first?.tasks.first?.actors == ["Alice"])
    }

    @Test func malformedDoesNotCrash() {
        _ = MermaidParser().parse("journey\n    : :")
        _ = MermaidJourneyParser.parse(lines: ["journey", "    section"])
        _ = MermaidJourneyParser.parse(lines: ["journey", "    Task without score"])
    }
}

private func layoutJourney(
    _ diagram: JourneyDiagram,
    maxWidth: CGFloat
) -> MermaidFlowchartRenderer.FlowchartLayout {
    MermaidJourneyRenderer.layout(diagram, configuration: .default(maxWidth: maxWidth))
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
