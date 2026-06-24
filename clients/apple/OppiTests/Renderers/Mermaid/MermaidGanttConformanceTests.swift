import Testing
@testable import Oppi

// SPEC: https://github.com/mermaid-js/mermaid/blob/develop/packages/mermaid/src/docs/syntax/gantt.md
//
// Tests for gantt features not yet covered.
//
// COVERAGE (new):
// [ ] tickInterval directive
// [ ] weekend directive (with excludes weekends)
// [ ] Vertical markers: vert status
// [ ] Comments in gantt charts (%%)
// [x] Multiple excludes values
// [x] excludes weekends keyword
// [x] weekday directive for week-based tickInterval
// [x] todayMarker directive
// [x] Multiple `after` dependencies and `until` dependencies
// [x] Official duration units including decimals, ms, M, and y
// [x] Click interactions: href and call

@Suite("Gantt Conformance — Missing Features")
struct MermaidGanttConformanceTests {
    let parser = MermaidParser()

    // MARK: - tickInterval

    /// SPEC: ### Axis ticks — `tickInterval 1day`
    @Test func tickIntervalDirective() {
        let result = parser.parse("""
        gantt
            dateFormat YYYY-MM-DD
            tickInterval 1day
            section Tasks
                Task A :2024-01-01, 3d
        """)
        guard case .gantt(let d) = result else {
            Issue.record("Expected gantt")
            return
        }
        #expect(d.tickInterval == "1day")
        // tickInterval should not be parsed as a task.
        #expect(d.sections.first?.tasks.count == 1)
    }

    /// tickInterval with week unit
    @Test func tickIntervalWeek() {
        let result = parser.parse("""
        gantt
            dateFormat YYYY-MM-DD
            tickInterval 1week
            section Tasks
                Task A :2024-01-01, 7d
        """)
        guard case .gantt(let d) = result else {
            Issue.record("Expected gantt")
            return
        }
        #expect(d.tickInterval == "1week")
    }

    // MARK: - Weekend

    /// SPEC: #### Weekend — `weekend friday` with `excludes weekends`
    @Test func weekendDirective() {
        let result = parser.parse("""
        gantt
            dateFormat YYYY-MM-DD
            excludes weekends
            weekend friday
            section Section
                A task :a1, 2024-01-01, 30d
        """)
        guard case .gantt(let d) = result else {
            Issue.record("Expected gantt")
            return
        }
        #expect(d.excludes.contains("weekends"))
        #expect(d.weekend == "friday")
        // "weekend" should not be parsed as a task.
        #expect(d.sections.first?.tasks.count == 1)
    }

    /// SPEC: ### Axis ticks — `weekday monday` with week-based `tickInterval`.
    @Test func weekdayDirectiveForWeekTickInterval() {
        let result = parser.parse("""
        gantt
            dateFormat YYYY-MM-DD
            tickInterval 1week
            weekday monday
            section Tasks
                Task A :2024-01-01, 7d
        """)
        guard case .gantt(let d) = result else {
            Issue.record("Expected gantt")
            return
        }
        #expect(d.tickInterval == "1week")
        #expect(d.weekday == "monday")
    }

    // MARK: - Vertical markers

    /// SPEC: ### Vertical Markers — `vert` status keyword
    @Test func verticalMarker() {
        let result = parser.parse("""
        gantt
            dateFormat HH:mm
            axisFormat %H:%M
            Initial vert : vert, v1, 17:30, 2m
            Task A : 3m
            Task B : 8m
        """)
        guard case .gantt(let d) = result else {
            Issue.record("Expected gantt")
            return
        }
        // The vert marker should be parsed as a task with vert status.
        let vertTask = d.sections.flatMap(\.tasks).first { $0.status == .vert }
        #expect(vertTask != nil, "Should have a task with vert status")
        #expect(vertTask?.name == "Initial vert")
    }

    // MARK: - Durations and dependencies

    /// SPEC: ## Syntax — duration units support ms/s/m/h/d/w/M/y and decimals.
    @Test func durationUnitsFromSpec() {
        let result = parser.parse("""
        gantt
            section Durations
                Milliseconds :500ms
                Seconds      :30s
                Minutes      :30m
                Hours        :4h
                Days         :1.5d
                Weeks        :2w
                Months       :1M
                Years        :1y
        """)
        guard case .gantt(let d) = result else {
            Issue.record("Expected gantt")
            return
        }
        let durations = d.sections.flatMap(\.tasks).map(\.duration)
        #expect(durations == ["500ms", "30s", "30m", "4h", "1.5d", "2w", "1M", "1y"])
    }

    /// SPEC: ## Syntax — `after` can name multiple tasks; `until` can end at task IDs.
    @Test func multipleAfterAndUntilDependencies() {
        let result = parser.parse("""
        gantt
            apple :a, 2017-07-20, 1w
            banana :crit, b, 2017-07-23, 1d
            cherry :active, c, after b a, 1d
            kiwi   :d, 2017-07-20, until b c
        """)
        guard case .gantt(let d) = result else {
            Issue.record("Expected gantt")
            return
        }
        let tasks = d.sections.flatMap(\.tasks)
        let cherry = tasks.first { $0.id == "c" }
        let kiwi = tasks.first { $0.id == "d" }
        #expect(cherry?.afterId == "b")
        #expect(cherry?.afterIds == ["b", "a"])
        #expect(cherry?.duration == "1d")
        #expect(kiwi?.startDate == "2017-07-20")
        #expect(kiwi?.untilIds == ["b", "c"])
    }

    // MARK: - Comments

    /// SPEC: ## Comments — `%% comment`
    @Test func commentsInGantt() {
        let result = parser.parse("""
        gantt
            dateFormat YYYY-MM-DD
            %% This is a comment
            section Tasks
                %% Another comment
                Task A :2024-01-01, 3d
        """)
        guard case .gantt(let d) = result else {
            Issue.record("Expected gantt")
            return
        }
        #expect(d.sections.first?.tasks.count == 1)
        #expect(d.sections.first?.tasks.first?.name == "Task A")
    }

    // MARK: - Excludes

    /// Multiple excludes values including specific dates and weekends
    @Test func multipleExcludes() {
        let result = parser.parse("""
        gantt
            dateFormat YYYY-MM-DD
            excludes weekends
            excludes 2024-01-15, 2024-02-14
            excludes 2024-03-01 2024-03-02
            section Tasks
                Task A :2024-01-01, 30d
        """)
        guard case .gantt(let d) = result else {
            Issue.record("Expected gantt")
            return
        }
        #expect(d.excludes.contains("weekends"))
        #expect(d.excludes.contains("2024-01-15"))
        #expect(d.excludes.contains("2024-02-14"))
        #expect(d.excludes.contains("2024-03-01"))
        #expect(d.excludes.contains("2024-03-02"))
    }

    // MARK: - Today marker

    /// SPEC: ## Today marker — accepts `off` or style declarations.
    @Test func todayMarkerDirective() {
        let result = parser.parse("""
        gantt
            todayMarker stroke-width:5px,stroke:#0f0,opacity:0.5
            section Tasks
                Task A :1d
        """)
        guard case .gantt(let d) = result else {
            Issue.record("Expected gantt")
            return
        }
        #expect(d.todayMarker == "stroke-width:5px,stroke:#0f0,opacity:0.5")
    }

    // MARK: - Frontmatter rendering options

    /// SPEC: ## Output in compact mode and Configuration `gantt.topAxis`.
    @Test func frontmatterDisplayModeCompactAndTopAxis() {
        let result = parser.parse("""
        ---
        displayMode: compact
        config:
          gantt:
            topAxis: true
        ---
        gantt
            section Section
                A task       :a1, 2014-01-01, 30d
                Another task :a2, 2014-01-20, 25d
        """)
        guard case .gantt(let d) = result else {
            Issue.record("Expected gantt")
            return
        }
        #expect(d.displayMode == .compact)
        #expect(d.topAxis)
    }

    // MARK: - Interaction

    /// SPEC: ## Interaction — `click taskId href URL` and `click taskId call callback(arguments)`.
    @Test func clickInteractions() {
        let result = parser.parse("""
        gantt
            dateFormat YYYY-MM-DD
            section Clickable
                Visit mermaidjs :active, cl1, 2014-01-07, 3d
                Print arguments :cl2, after cl1, 3d
                Print task :cl3, after cl2, 3d
            click cl1 href "https://mermaid.js.org/"
            click cl2 call printArguments("test1", "test2", test3)
            click cl3 call printTask()
        """)
        guard case .gantt(let d) = result else {
            Issue.record("Expected gantt")
            return
        }
        #expect(d.clicks == [
            GanttClick(taskId: "cl1", action: .href("https://mermaid.js.org/")),
            GanttClick(taskId: "cl2", action: .call("printArguments(\"test1\", \"test2\", test3)")),
            GanttClick(taskId: "cl3", action: .call("printTask()")),
        ])
        #expect(d.sections.first?.tasks.count == 3)
    }

    // MARK: - Combined spec example

    /// Full spec example with multiple features.
    @Test func fullGanttExample() {
        let result = parser.parse("""
        gantt
            title A Gantt Diagram
            dateFormat YYYY-MM-DD
            axisFormat %Y-%m-%d
            tickInterval 1week
            excludes weekends
            section Design
                Research           :done, des1, 2024-01-01, 2024-01-05
                Prototyping        :active, des2, after des1, 5d
            section Implementation
                Coding             :crit, impl1, 2024-01-10, 10d
                Testing            :after impl1, 5d
                Deploy             :milestone, after impl1, 0d
        """)
        guard case .gantt(let d) = result else {
            Issue.record("Expected gantt")
            return
        }
        #expect(d.title == "A Gantt Diagram")
        #expect(d.tickInterval == "1week")
        #expect(d.sections.count == 2)
        #expect(d.sections[0].tasks.count == 2)
        #expect(d.sections[1].tasks.count == 3)
    }
}
