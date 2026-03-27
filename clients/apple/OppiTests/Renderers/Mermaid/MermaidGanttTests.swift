import CoreGraphics
import Testing
@testable import Oppi

// MARK: - Parser Tests

@Suite("Mermaid Gantt Parser")
struct MermaidGanttParserTests {

    // MARK: - Directives

    @Test func parsesTitle() {
        let diagram = MermaidGanttParser.parse(lines: [
            "title A Gantt Diagram",
        ])
        #expect(diagram.title == "A Gantt Diagram")
    }

    @Test func parsesDateFormat() {
        let diagram = MermaidGanttParser.parse(lines: [
            "dateFormat YYYY-MM-DD",
        ])
        #expect(diagram.dateFormat == "YYYY-MM-DD")
    }

    @Test func defaultDateFormat() {
        let diagram = MermaidGanttParser.parse(lines: [])
        #expect(diagram.dateFormat == "YYYY-MM-DD")
    }

    @Test func parsesAxisFormat() {
        let diagram = MermaidGanttParser.parse(lines: [
            "axisFormat %m/%d",
        ])
        #expect(diagram.axisFormat == "%m/%d")
    }

    @Test func parsesExcludes() {
        let diagram = MermaidGanttParser.parse(lines: [
            "excludes weekends",
        ])
        #expect(diagram.excludes == ["weekends"])
    }

    @Test func parsesMultipleExcludes() {
        let diagram = MermaidGanttParser.parse(lines: [
            "excludes weekends, 2024-01-01",
        ])
        #expect(diagram.excludes == ["weekends", "2024-01-01"])
    }

    // MARK: - Sections

    @Test func parsesSingleSection() {
        let diagram = MermaidGanttParser.parse(lines: [
            "section Design",
            "Research :done, des1, 2024-01-01, 2024-01-05",
        ])
        #expect(diagram.sections.count == 1)
        #expect(diagram.sections[0].name == "Design")
        #expect(diagram.sections[0].tasks.count == 1)
    }

    @Test func parsesMultipleSections() {
        let diagram = MermaidGanttParser.parse(lines: [
            "section Design",
            "Research :des1, 2024-01-01, 3d",
            "section Implementation",
            "Backend :impl1, 2024-01-08, 5d",
        ])
        #expect(diagram.sections.count == 2)
        #expect(diagram.sections[0].name == "Design")
        #expect(diagram.sections[1].name == "Implementation")
    }

    @Test func tasksWithoutSectionGetDefault() {
        let diagram = MermaidGanttParser.parse(lines: [
            "Research :2024-01-01, 3d",
        ])
        #expect(diagram.sections.count == 1)
        #expect(diagram.sections[0].name == "Default")
    }

    // MARK: - Task parsing basics

    @Test func parsesTaskWithIdAndDates() {
        let diagram = MermaidGanttParser.parse(lines: [
            "section Work",
            "Research :des1, 2024-01-01, 2024-01-05",
        ])
        let task = diagram.sections[0].tasks[0]
        #expect(task.name == "Research")
        #expect(task.id == "des1")
        #expect(task.startDate == "2024-01-01")
        #expect(task.endDate == "2024-01-05")
    }

    @Test func parsesTaskWithDuration() {
        let diagram = MermaidGanttParser.parse(lines: [
            "section Work",
            "Backend :impl1, 2024-01-08, 5d",
        ])
        let task = diagram.sections[0].tasks[0]
        #expect(task.name == "Backend")
        #expect(task.id == "impl1")
        #expect(task.startDate == "2024-01-08")
        #expect(task.duration == "5d")
    }

    @Test func parsesTaskWithAfterDependency() {
        let diagram = MermaidGanttParser.parse(lines: [
            "section Work",
            "Testing :after impl2, 3d",
        ])
        let task = diagram.sections[0].tasks[0]
        #expect(task.name == "Testing")
        #expect(task.afterId == "impl2")
        #expect(task.duration == "3d")
    }

    @Test func parsesTaskWithOnlyStartAndDuration() {
        let diagram = MermaidGanttParser.parse(lines: [
            "section Deploy",
            "Staging :2024-01-20, 2d",
        ])
        let task = diagram.sections[0].tasks[0]
        #expect(task.name == "Staging")
        #expect(task.startDate == "2024-01-20")
        #expect(task.duration == "2d")
    }

    // MARK: - Status markers

    @Test func parsesDoneStatus() {
        let diagram = MermaidGanttParser.parse(lines: [
            "section Work",
            "Research :done, des1, 2024-01-01, 2024-01-05",
        ])
        #expect(diagram.sections[0].tasks[0].status == .done)
    }

    @Test func parsesActiveStatus() {
        let diagram = MermaidGanttParser.parse(lines: [
            "section Work",
            "Prototyping :active, des2, after des1, 3d",
        ])
        let task = diagram.sections[0].tasks[0]
        #expect(task.status == .active)
        #expect(task.afterId == "des1")
    }

    @Test func parsesCriticalStatus() {
        let diagram = MermaidGanttParser.parse(lines: [
            "section Work",
            "Backend :crit, impl1, 2024-01-08, 5d",
        ])
        #expect(diagram.sections[0].tasks[0].status == .critical)
    }

    @Test func parsesMilestoneStatus() {
        let diagram = MermaidGanttParser.parse(lines: [
            "section Deploy",
            "Production :milestone, after impl2, 0d",
        ])
        let task = diagram.sections[0].tasks[0]
        #expect(task.status == .milestone)
        #expect(task.afterId == "impl2")
        #expect(task.duration == "0d")
    }

    @Test func parsesNormalStatus() {
        let diagram = MermaidGanttParser.parse(lines: [
            "section Work",
            "Frontend :impl2, after impl1, 4d",
        ])
        #expect(diagram.sections[0].tasks[0].status == .normal)
    }

    @Test func parsesCritDoneCombination() {
        let diagram = MermaidGanttParser.parse(lines: [
            "section Work",
            "Old task :crit, done, old1, 2024-01-01, 3d",
        ])
        // crit + done → critical takes visual precedence
        #expect(diagram.sections[0].tasks[0].status == .critical)
    }

    // MARK: - After dependencies

    @Test func afterWithIdAndDuration() {
        let diagram = MermaidGanttParser.parse(lines: [
            "section Work",
            "Review :des3, after des2, 1d",
        ])
        let task = diagram.sections[0].tasks[0]
        #expect(task.id == "des3")
        #expect(task.afterId == "des2")
        #expect(task.duration == "1d")
    }

    @Test func afterWithoutId() {
        let diagram = MermaidGanttParser.parse(lines: [
            "section Work",
            "Testing :after impl2, 3d",
        ])
        let task = diagram.sections[0].tasks[0]
        #expect(task.id == nil)
        #expect(task.afterId == "impl2")
        #expect(task.duration == "3d")
    }

    // MARK: - Edge cases

    @Test func emptyInput() {
        let diagram = MermaidGanttParser.parse(lines: [])
        #expect(diagram.sections.isEmpty)
        #expect(diagram.title == nil)
    }

    @Test func blankLinesIgnored() {
        let diagram = MermaidGanttParser.parse(lines: [
            "title Test",
            "",
            "   ",
            "section A",
            "Task :1d",
        ])
        #expect(diagram.title == "Test")
        #expect(diagram.sections.count == 1)
    }

    @Test func indentedLinesHandled() {
        let diagram = MermaidGanttParser.parse(lines: [
            "    title Indented",
            "    section Alpha",
            "    Task One :t1, 2024-01-01, 3d",
        ])
        #expect(diagram.title == "Indented")
        #expect(diagram.sections[0].tasks[0].name == "Task One")
    }

    // MARK: - Full diagram

    @Test func fullDiagramParsesCorrectly() {
        let lines = [
            "title A Gantt Diagram",
            "dateFormat YYYY-MM-DD",
            "axisFormat %m/%d",
            "excludes weekends",
            "",
            "section Design",
            "Research           :done, des1, 2024-01-01, 2024-01-05",
            "Prototyping        :active, des2, after des1, 3d",
            "Review             :des3, after des2, 1d",
            "",
            "section Implementation",
            "Backend            :crit, impl1, 2024-01-08, 5d",
            "Frontend           :impl2, after impl1, 4d",
            "Testing            :after impl2, 3d",
            "",
            "section Deployment",
            "Staging            :2024-01-20, 2d",
            "Production         :milestone, after impl2, 0d",
        ]
        let diagram = MermaidGanttParser.parse(lines: lines)

        #expect(diagram.title == "A Gantt Diagram")
        #expect(diagram.dateFormat == "YYYY-MM-DD")
        #expect(diagram.axisFormat == "%m/%d")
        #expect(diagram.excludes == ["weekends"])
        #expect(diagram.sections.count == 3)

        // Design section
        let design = diagram.sections[0]
        #expect(design.name == "Design")
        #expect(design.tasks.count == 3)
        #expect(design.tasks[0].status == .done)
        #expect(design.tasks[1].status == .active)
        #expect(design.tasks[1].afterId == "des1")
        #expect(design.tasks[2].afterId == "des2")

        // Implementation section
        let impl = diagram.sections[1]
        #expect(impl.name == "Implementation")
        #expect(impl.tasks.count == 3)
        #expect(impl.tasks[0].status == .critical)
        #expect(impl.tasks[1].afterId == "impl1")
        #expect(impl.tasks[2].afterId == "impl2")

        // Deployment section
        let deploy = diagram.sections[2]
        #expect(deploy.name == "Deployment")
        #expect(deploy.tasks.count == 2)
        #expect(deploy.tasks[1].status == .milestone)
    }
}

// MARK: - Renderer Tests

@Suite("Mermaid Gantt Renderer")
struct MermaidGanttRendererTests {
    let config = RenderConfiguration.default(maxWidth: 800)

    private func parseGantt(_ source: String) -> GanttDiagram {
        let allLines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        // Skip the "gantt" header line if present.
        let body = allLines.first?.trimmingCharacters(in: .whitespaces) == "gantt"
            ? Array(allLines.dropFirst())
            : allLines
        return MermaidGanttParser.parse(lines: body)
    }

    @Test func producesNonZeroSize() {
        let diagram = parseGantt("""
            gantt
                section Work
                Task A :t1, 2024-01-01, 3d
                Task B :t2, after t1, 2d
            """)
        let layout = MermaidGanttRenderer.layout(diagram, configuration: config)
        let size = layout.customSize
        #expect(size != nil)
        #expect(size!.width > 0)
        #expect(size!.height > 0)
    }

    @Test func emptyDiagramReturnsPlaceholder() {
        let diagram = GanttDiagram.empty
        let layout = MermaidGanttRenderer.layout(diagram, configuration: config)
        #expect(layout.isPlaceholder)
    }

    @Test func customDrawIsSet() {
        let diagram = parseGantt("""
            gantt
                section A
                Task :1d
            """)
        let layout = MermaidGanttRenderer.layout(diagram, configuration: config)
        #expect(layout.customDraw != nil)
        #expect(!layout.isPlaceholder)
    }

    @Test func drawDoesNotCrash() {
        let diagram = parseGantt("""
            gantt
                title Project Plan
                dateFormat YYYY-MM-DD
                section Design
                Research           :done, des1, 2024-01-01, 2024-01-05
                Prototyping        :active, des2, after des1, 3d
                section Implementation
                Backend            :crit, impl1, 2024-01-08, 5d
                Frontend           :impl2, after impl1, 4d
                section Deployment
                Production         :milestone, after impl2, 0d
            """)
        let layout = MermaidGanttRenderer.layout(diagram, configuration: config)
        let size = layout.customSize ?? CGSize(width: 100, height: 100)

        let ctx = CGContext(
            data: nil,
            width: max(1, Int(size.width)),
            height: max(1, Int(size.height)),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // Should not crash.
        layout.customDraw?(ctx, .zero)
    }

    @Test func multipleSectionsAffectHeight() {
        let one = parseGantt("""
            gantt
                section A
                Task :1d
            """)
        let two = parseGantt("""
            gantt
                section A
                Task 1 :1d
                section B
                Task 2 :1d
                Task 3 :2d
            """)
        let layoutOne = MermaidGanttRenderer.layout(one, configuration: config)
        let layoutTwo = MermaidGanttRenderer.layout(two, configuration: config)
        let sizeOne = layoutOne.customSize!
        let sizeTwo = layoutTwo.customSize!
        #expect(sizeTwo.height > sizeOne.height)
    }

    @Test func titleAddedToLayout() {
        let withTitle = parseGantt("""
            gantt
                title My Project
                section A
                Task :1d
            """)
        let withoutTitle = parseGantt("""
            gantt
                section A
                Task :1d
            """)
        let sizeWith = MermaidGanttRenderer.layout(withTitle, configuration: config).customSize!
        let sizeWithout = MermaidGanttRenderer.layout(withoutTitle, configuration: config).customSize!
        #expect(sizeWith.height > sizeWithout.height)
    }

    @Test func longerDurationsProduceWiderLayout() {
        let short = parseGantt("""
            gantt
                section A
                Task :1d
            """)
        let long = parseGantt("""
            gantt
                section A
                Task :1w
            """)
        let sizeShort = MermaidGanttRenderer.layout(short, configuration: config).customSize!
        let sizeLong = MermaidGanttRenderer.layout(long, configuration: config).customSize!
        #expect(sizeLong.width > sizeShort.width)
    }

    @Test func allStatusTypesRender() {
        let diagram = parseGantt("""
            gantt
                section Statuses
                Normal     :n1, 2024-01-01, 2d
                Active     :active, a1, 2024-01-03, 2d
                Done       :done, d1, 2024-01-01, 2d
                Critical   :crit, c1, 2024-01-05, 2d
                Milestone  :milestone, after c1, 0d
            """)
        let layout = MermaidGanttRenderer.layout(diagram, configuration: config)
        #expect(layout.customSize != nil)
        #expect(layout.customDraw != nil)

        let size = layout.customSize!
        let ctx = CGContext(
            data: nil,
            width: max(1, Int(size.width)),
            height: max(1, Int(size.height)),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        layout.customDraw?(ctx, .zero)
    }

    @Test func rendererUsedThroughFlowchartRenderer() {
        let parser = MermaidParser()
        let renderer = MermaidFlowchartRenderer()
        let diagram = parser.parse("""
            gantt
                section Work
                Task A :t1, 2024-01-01, 3d
            """)
        let layout = renderer.layout(diagram, configuration: config)
        #expect(layout.customSize != nil)
        #expect(layout.customDraw != nil)
        let size = renderer.boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.height > 0)
    }
}
