import CoreGraphics
import Testing
@testable import Oppi

// SPEC: https://mermaid.js.org/syntax/timeline.html
// Grammar reference (mermaid stopped tagging releases after v11.0.0, so the
// develop branch is the pinned source for the v11.17-era spec page):
// https://github.com/mermaid-js/mermaid/blob/develop/packages/mermaid/src/diagrams/timeline/parser/timeline.jison
//
// Conformance tests for the native Mermaid timeline parser and renderer.
// The parser is called directly with body lines (the shared MermaidParser
// strips the `timeline` header before dispatch) and with full-source lines
// to cover the standalone path. Renderer assertions check structure and
// layout facts (period order, event stacking, bands, sizes), not pixels.

@Suite("Timeline Conformance")
struct MermaidTimelineConformanceTests {

    // MARK: - Spec-page fixtures

    /// SPEC: "An example of a timeline" — social media history, including
    /// the `: Google` continuation line attached to the 2004 period.
    private static let socialMedia = """
    title History of Social Media Platform
    2002 : LinkedIn
    2004 : Facebook
         : Google
    2005 : YouTube
    2006 : Twitter
    """

    /// SPEC: "Grouping of time periods in sections/ages" — the sectioned
    /// Industrial Revolution history example.
    private static let industrialRevolution = """
    title Timeline of Industrial Revolution
    section 17th-20th century
        Industry 1.0 : Machinery, Water power, Steam power
        Industry 2.0 : Electricity, Internal combustion engine, Mass production
        Industry 3.0 : Electronics, Computers, Automation
    section 21st century
        Industry 4.0 : Internet, Robotics, Internet of Things
        Industry 5.0 : Artificial intelligence, Big data, 3D printing
    """

    private static func parse(_ source: String) -> TimelineDiagram {
        MermaidTimelineParser.parse(lines: source.components(separatedBy: .newlines))
    }

    private static func renderLayout(
        _ source: String,
        maxWidth: CGFloat = 360
    ) -> MermaidTimelineRenderer.LayoutModel {
        MermaidTimelineRenderer.buildLayout(
            parse(source),
            configuration: .default(maxWidth: maxWidth)
        )
    }

    // MARK: - Parser: spec examples

    @Test func parsesSocialMediaSpecExample() {
        let diagram = Self.parse(Self.socialMedia)
        #expect(diagram.title == "History of Social Media Platform")

        // Periods before any `section` live in one implicit unnamed section.
        #expect(diagram.sections.count == 1)
        let section = diagram.sections[0]
        #expect(section.name == nil)

        // Period order follows the source, left to right.
        #expect(section.periods.map(\.label) == ["2002", "2004", "2005", "2006"])

        // Events stack top to bottom in source order; the continuation
        // line attaches to the previous period.
        #expect(section.periods[0].events == ["LinkedIn"])
        #expect(section.periods[1].events == ["Facebook", "Google"])
        #expect(section.periods[2].events == ["YouTube"])
        #expect(section.periods[3].events == ["Twitter"])
    }

    @Test func parsesSectionedHistorySpecExample() {
        let diagram = Self.parse(Self.industrialRevolution)
        #expect(diagram.title == "Timeline of Industrial Revolution")

        // Sections keep their declaration order.
        #expect(diagram.sections.map(\.name) == ["17th-20th century", "21st century"])
        #expect(
            diagram.sections[0].periods.map(\.label)
                == ["Industry 1.0", "Industry 2.0", "Industry 3.0"]
        )
        #expect(
            diagram.sections[1].periods.map(\.label)
                == ["Industry 4.0", "Industry 5.0"]
        )
        #expect(
            diagram.sections[0].periods[0].events
                == ["Machinery, Water power, Steam power"]
        )
        #expect(
            diagram.sections[1].periods[1].events
                == ["Artificial intelligence, Big data, 3D printing"]
        )
    }

    // MARK: - Parser: grammar behavior

    /// Grammar: `task2: event2: event3` yields one period with two events,
    /// matching the upstream timeline.spec.js expectations.
    @Test func multipleInlineEvents() {
        let diagram = Self.parse("""
        section abc-123
        task1 : event1
        task2 : event2 : event3
        """)
        let periods = diagram.sections[0].periods
        #expect(periods.count == 2)
        #expect(periods[0].events == ["event1"])
        #expect(periods[1].events == ["event2", "event3"])
    }

    /// Grammar: continuation lines starting with `:` append events to the
    /// most recent period.
    @Test func continuationLinesAttachToPreviousPeriod() {
        let diagram = Self.parse("""
        section abc-123
        task1 : event1
        task2 : event2 : event3
              : event4 : event5
        """)
        let periods = diagram.sections[0].periods
        #expect(periods.count == 2)
        #expect(periods[0].events == ["event1"])
        #expect(periods[1].events == ["event2", "event3", "event4", "event5"])
    }

    @Test func periodsBeforeAnySectionUseImplicitSection() {
        let diagram = Self.parse("""
        2002 : LinkedIn
        section Growth
        2004 : Facebook
        """)
        #expect(diagram.sections.count == 2)
        #expect(diagram.sections[0].name == nil)
        #expect(diagram.sections[0].periods.map(\.label) == ["2002"])
        #expect(diagram.sections[1].name == "Growth")
        #expect(diagram.sections[1].periods.map(\.label) == ["2004"])
    }

    /// Grammar: a bare text line is a period with no events. This is how
    /// the spec page's `Release Personal Tier` line parses.
    @Test func barePeriodLineHasNoEvents() {
        let diagram = Self.parse("""
        section 2023 Q1
        Release Personal Tier
        Bullet 1 : sub-point 1a
        """)
        let periods = diagram.sections[0].periods
        #expect(periods.count == 2)
        #expect(periods[0].label == "Release Personal Tier")
        #expect(periods[0].events.isEmpty)
        #expect(periods[1].label == "Bullet 1")
        #expect(periods[1].events == ["sub-point 1a"])
    }

    /// Grammar: a colon separates events only when followed by whitespace
    /// or end of line, so clock times stay inside the event text.
    @Test func colonNotFollowedBySpaceStaysInEventText() {
        let diagram = Self.parse("Meet : 10:30 sync : follow-up")
        let period = diagram.sections[0].periods[0]
        #expect(period.label == "Meet")
        #expect(period.events == ["10:30 sync", "follow-up"])
    }

    /// SPEC: "Direction (v11.14.0+)" — official header tokens are `LR`
    /// (default) and `TD`. `timeline-beta` is accepted as a timeline alias.
    @Test func officialDirectionTokensAreParsed() {
        for header in ["timeline", "timeline LR", "timeline TD", "timeline-beta", "timeline-beta TD"] {
            let diagram = Self.parse("\(header)\ntitle T\n2001 : A")
            #expect(diagram.title == "T")
            let periods = diagram.sections.flatMap(\.periods)
            #expect(periods.map(\.label) == ["2001"])
        }
        #expect(Self.parse("timeline TD\n2001 : A").direction == .TD)
        #expect(Self.parse("timeline-beta TD\n2001 : A").direction == .TD)
        #expect(Self.parse("timeline LR\n2001 : A").direction == .LR)
        #expect(Self.parse("2001 : A").direction == .LR)
    }

    /// Official lexer only has `timeline LR` / `timeline TD`. Leftover
    /// tokens such as `RL` / `TB` are period text, not a silent LR draw.
    @Test func leftoverTimelineOrientationsBecomePeriodText() {
        let rl = Self.parse("timeline RL\n2001 : A")
        #expect(rl.direction == .LR)
        #expect(rl.sections.flatMap(\.periods).map(\.label) == ["RL", "2001"])

        let tb = Self.parse("timeline TB\n2001 : A")
        #expect(tb.direction == .LR)
        #expect(tb.sections.flatMap(\.periods).map(\.label) == ["TB", "2001"])
    }

    @Test func sharedParserAcceptsTimelineBetaTD() {
        let result = MermaidParser().parse("timeline-beta TD\n2001 : A\n2002 : B")
        guard case .timeline(let diagram) = result else {
            Issue.record("Expected timeline for timeline-beta, got \(result)")
            return
        }
        #expect(diagram.direction == .TD)
        #expect(diagram.sections.flatMap(\.periods).map(\.label) == ["2001", "2002"])
    }

    @Test func commentsAreIgnored() {
        let diagram = Self.parse("""
        %% full-line comment
        title T %% trailing comment
        2001 : A
        # full-line hash comment
        2002 : B
        """)
        #expect(diagram.title == "T")
        #expect(diagram.sections[0].periods.map(\.label) == ["2001", "2002"])
    }

    @Test func sectionNameStopsAtColon() {
        // Official lexer: `"section"\s[^:\n]+`.
        let diagram = Self.parse("section 2023 Q1: extra\ntask1 : event1")
        #expect(diagram.sections[0].name == "2023 Q1")
    }

    /// SPEC: `<br>` forces a line break in long periods and events.
    @Test func brTagsArePreservedAsNewlines() {
        let diagram = Self.parse("Planning<br>Launch : kickoff<br/>go-live<br />done")
        let period = diagram.sections[0].periods[0]
        #expect(period.label == "Planning\nLaunch")
        #expect(period.events == ["kickoff\ngo-live\ndone"])

        // Wide canvas so wrapping is not the source of the newline.
        let model = Self.renderLayout(
            "Planning<br>Launch : kickoff<br/>go-live",
            maxWidth: 800
        )
        let placed = model.sections[0].periods[0]
        #expect(placed.label == "Planning\nLaunch")
        #expect(placed.wrappedLabel.contains("\n"))
        #expect(placed.eventBoxes[0].text.contains("\n"))
    }

    /// Official grammar recognizes only `accTitle:`, `accDescr:`, and
    /// `accDescr {`. A period that merely starts with those letters stays.
    @Test func onlyColonOrBraceAccessibilityDirectivesAreSkipped() {
        let diagram = Self.parse("""
        accTitle: Accessible timeline
        accDescr: Hidden description
        accDescr {
          more hidden text
        }
        accTitle rollout : shipped
        """)
        #expect(diagram.sections.count == 1)
        let periods = diagram.sections[0].periods
        #expect(periods.map(\.label) == ["accTitle rollout"])
        #expect(periods[0].events == ["shipped"])
    }

    // MARK: - Renderer: layout facts

    @Test func layoutProducesNonEmptyCanvas() {
        let diagram = Self.parse(Self.socialMedia)
        let layout = MermaidTimelineRenderer.layout(
            diagram,
            configuration: .default(maxWidth: 360)
        )
        #expect(!layout.isPlaceholder)
        #expect(layout.customDraw != nil)
        let size = layout.customSize ?? .zero
        #expect(size.width > 0)
        #expect(size.height > 0)
        // A small timeline fills the bubble width.
        #expect(size.width >= 360)
    }

    @Test func periodsAreOrderedAlongSpineAndEventsStackBelow() {
        let model = Self.renderLayout(Self.socialMedia)

        let periods = model.sections.flatMap(\.periods)
        #expect(periods.count == 4)

        // Period order follows source order along the spine.
        for (earlier, later) in zip(periods, periods.dropFirst()) {
            #expect(earlier.centerX < later.centerX)
        }

        // The 2004 continuation event stacks under the first event.
        let stacked = periods[1]
        #expect(stacked.eventBoxes.count == 2)
        #expect(stacked.eventBoxes[0].frame.minY < stacked.eventBoxes[1].frame.minY)

        // Every event box hangs below the spine, one per parsed event.
        for period in periods {
            #expect(period.eventBoxes.count == period.events.count)
            for box in period.eventBoxes {
                #expect(box.frame.minY >= model.spineY)
                #expect(box.frame.height > 0)
            }
        }
        #expect(model.size.height > model.spineY)
    }

    @Test func namedSectionsGetDisjointColorBands() {
        let model = Self.renderLayout(Self.industrialRevolution)

        #expect(model.sections.count == 2)
        #expect(model.sections[0].name == "17th-20th century")
        #expect(model.sections[1].name == "21st century")

        // Bands sit side by side in declaration order without overlapping.
        let bands = model.sections.map(\.bandFrame)
        #expect(bands[0].width > 0 && bands[0].height > 0)
        #expect(bands[0].maxX <= bands[1].minX)

        // Periods live inside their own band and keep their section color.
        for section in model.sections {
            #expect(!section.periods.isEmpty)
            for period in section.periods {
                #expect(section.bandFrame.contains(period.columnFrame.origin))
                #expect(section.bandFrame.maxX >= period.columnFrame.maxX)
                #expect(period.colorIndex == section.colorIndex)
            }
        }

        // Distinct section colors.
        #expect(model.sections[0].colorIndex != model.sections[1].colorIndex)
    }

    @Test func sectionlessDiagramColorsEachPeriodDifferently() {
        // SPEC: with no sections, each period gets its own color scheme.
        let model = Self.renderLayout(Self.socialMedia)
        let colorIndexes = model.sections.flatMap(\.periods).map(\.colorIndex)
        #expect(colorIndexes == [0, 1, 2, 3])
    }

    @Test func longEventTextIsWrappedAndTruncatedWithEllipsis() {
        let longEvent = Array(repeating: "milestone", count: 40).joined(separator: " ")
        let model = Self.renderLayout("section S\n2001 : \(longEvent)")

        let period = model.sections[0].periods[0]
        #expect(period.eventBoxes.count == 1)
        let box = period.eventBoxes[0]
        let lines = box.text.components(separatedBy: "\n")
        #expect(lines.count <= 4)
        #expect(box.text.contains("…"))
        // The box stays within its column.
        #expect(box.frame.width <= period.columnFrame.width + 0.5)
        #expect(box.frame.height > 0)
    }

    @Test func wideTimelineMayExceedBubbleWidth() {
        // Wide diagrams grow past `maxWidth`; the inline view scales to
        // fit and fullscreen zoom is the inspection path.
        let source = (1...10).map { "P\($0) : event \($0)" }.joined(separator: "\n")
        let model = Self.renderLayout(source, maxWidth: 360)
        #expect(model.size.width > 360)
        let periods = model.sections.flatMap(\.periods)
        #expect(periods.count == 10)
    }

    @Test func titleAndSectionHeadingsWrapWithinMaxWidth() {
        let longTitle = "This is an extremely long timeline title that would overflow a phone bubble if the renderer never wrapped or truncated it"
        let longSection = "This is an extremely long section heading about the first industrial age"
        let longModel = Self.renderLayout("""
        title \(longTitle)
        section \(longSection)
        2001 : A
        section Short
        2002 : B
        """, maxWidth: 360)
        let shortModel = Self.renderLayout("""
        title Short
        section S
        2001 : A
        section T
        2002 : B
        """, maxWidth: 360)

        guard let titleFrame = longModel.titleFrame,
              let wrappedTitle = longModel.wrappedTitle,
              let headingFrame = longModel.sections[0].headingFrame,
              let wrappedName = longModel.sections[0].wrappedName
        else {
            Issue.record("Expected title and section heading frames")
            return
        }

        #expect(titleFrame.maxX <= longModel.size.width + 0.5)
        #expect(titleFrame.width <= 360)
        #expect(wrappedTitle.contains("\n") || wrappedTitle.contains("…"))
        #expect(longModel.size.height > shortModel.size.height)

        #expect(headingFrame.maxX <= longModel.sections[0].bandFrame.maxX + 0.5)
        #expect(headingFrame.minX >= longModel.sections[0].bandFrame.minX - 0.5)
        #expect(wrappedName.contains("\n") || wrappedName.contains("…"))
        // Must not spill into the next section band.
        #expect(headingFrame.maxX <= longModel.sections[1].bandFrame.minX + 0.5)
    }

    @Test func spineContinuesAcrossSectionsWithDirectionalCue() {
        let model = Self.renderLayout(Self.industrialRevolution)
        #expect(model.sections.count == 2)
        guard let firstCenter = model.sections[0].periods.first?.centerX,
              let lastCenter = model.sections[1].periods.last?.centerX
        else {
            Issue.record("Expected periods in both sections")
            return
        }
        let firstBand = model.sections[0].bandFrame
        let secondBand = model.sections[1].bandFrame

        // One spine interval covers every period and the gap between sections.
        #expect(model.spineStartX <= firstCenter)
        #expect(model.spineEndX >= lastCenter)
        #expect(model.spineStartX < firstBand.maxX)
        #expect(model.spineEndX > secondBand.minX)
        #expect(model.spineEndX > firstBand.maxX)

        // Terminal arrow points forward past the last period.
        #expect(model.spineArrowTipX > model.spineEndX)
        #expect(model.spineArrowTipX <= model.size.width + 0.5)
    }

    /// SPEC: `timeline TD` is top-down chronology, not a silent LR spine.
    @Test func tdTimelineRendersTopDownChronology() {
        let model = Self.renderLayout("""
        timeline TD
        title History of Social Media Platform
        2002 : LinkedIn
        2004 : Facebook
             : Google
        2005 : YouTube
        2006 : Twitter
        """)
        #expect(model.direction == .TD)

        let periods = model.sections.flatMap(\.periods)
        #expect(periods.map(\.label) == ["2002", "2004", "2005", "2006"])

        // Chronology reads top to bottom along one vertical spine.
        for (earlier, later) in zip(periods, periods.dropFirst()) {
            #expect(earlier.centerY < later.centerY)
            #expect(abs(earlier.centerX - later.centerX) < 24)
        }
        #expect(model.spineStartY < model.spineEndY)
        #expect(abs(model.spineStartX - model.spineEndX) < 0.5)
        #expect(abs(model.spineX - model.spineStartX) < 0.5)
        #expect(model.spineArrowTipY > model.spineEndY)

        // Events hang to the right of the spine, still stacked in source order.
        let stacked = periods[1]
        #expect(stacked.eventBoxes.count == 2)
        #expect(stacked.eventBoxes[0].frame.minY < stacked.eventBoxes[1].frame.minY)
        for period in periods {
            #expect(period.eventBoxes.count == period.events.count)
            for box in period.eventBoxes {
                #expect(box.frame.minX >= model.spineX - 0.5)
                #expect(box.frame.height > 0)
            }
        }
    }

    @Test func timelineBetaTDRendersTopDownNotLR() {
        let model = Self.renderLayout("""
        timeline-beta TD
        2001 : A
        2002 : B
        2003 : C
        """)
        #expect(model.direction == .TD)
        let periods = model.sections.flatMap(\.periods)
        #expect(periods.count == 3)
        #expect(periods[0].centerY < periods[1].centerY)
        #expect(periods[1].centerY < periods[2].centerY)
        #expect(abs(periods[0].centerX - periods[2].centerX) < 24)
    }

    @Test func tdNamedSectionsStackVertically() {
        let model = Self.renderLayout("""
        timeline TD
        \(Self.industrialRevolution)
        """)
        #expect(model.direction == .TD)
        #expect(model.sections.count == 2)
        #expect(model.sections[0].bandFrame.maxY <= model.sections[1].bandFrame.minY + 0.5)
        #expect(model.sections[0].bandFrame.minX >= model.sections[1].bandFrame.minX - 0.5)
    }

    @Test func emptyTimelineIsPlaceholder() {
        let layout = MermaidTimelineRenderer.layout(
            TimelineDiagram.empty,
            configuration: .default()
        )
        #expect(layout.isPlaceholder)
    }
}
