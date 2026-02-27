import Testing
@testable import Oppi

@Suite("PlotChartSpec")
struct PlotChartSpecTests {
    @Test("parses first valid chart from tool details")
    func fromToolDetailsParsesChart() {
        let details: JSONValue = .object([
            "ui": .array([
                .object([
                    "id": .string("chart-1"),
                    "kind": .string("chart"),
                    "version": .number(1),
                    "title": .string("Pace chart"),
                    "fallbackText": .string("fallback"),
                    "spec": .object([
                        "dataset": .object([
                            "rows": .array([
                                .object(["x": .number(0), "pace": .number(295)]),
                                .object(["x": .number(1), "pace": .number(292)]),
                            ]),
                        ]),
                        "marks": .array([
                            .object([
                                "type": .string("line"),
                                "x": .string("x"),
                                "y": .string("pace"),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])

        let payload = PlotChartSpec.fromToolDetails(details)

        #expect(payload != nil)
        #expect(payload?.spec.title == "Pace chart")
        #expect(payload?.spec.rows.count == 2)
        #expect(payload?.spec.marks.count == 1)
        #expect(payload?.fallbackText == "fallback")
    }

    @Test("columnIsNumeric detects numeric columns")
    func columnIsNumericForNumbers() {
        let spec = PlotChartSpec.fromPlotArgs([
            "spec": .object([
                "dataset": .object([
                    "rows": .array([
                        .object(["x": .number(1), "y": .number(10)]),
                        .object(["x": .number(2), "y": .number(20)]),
                    ]),
                ]),
                "marks": .array([
                    .object(["type": .string("bar"), "x": .string("x"), "y": .string("y")]),
                ]),
            ]),
        ])

        guard let spec else {
            Issue.record("Expected PlotChartSpec to parse")
            return
        }
        #expect(spec.columnIsNumeric("x") == true)
        #expect(spec.columnIsNumeric("y") == true)
    }

    @Test("columnIsNumeric detects categorical string columns")
    func columnIsNumericForStrings() {
        let spec = PlotChartSpec.fromPlotArgs([
            "spec": .object([
                "dataset": .object([
                    "rows": .array([
                        .object(["state": .string("Invited"), "count": .number(5)]),
                        .object(["state": .string("Accepted"), "count": .number(3)]),
                    ]),
                ]),
                "marks": .array([
                    .object(["type": .string("bar"), "x": .string("state"), "y": .string("count")]),
                ]),
            ]),
        ])

        guard let spec else {
            Issue.record("Expected PlotChartSpec to parse")
            return
        }
        #expect(spec.columnIsNumeric("state") == false)
        #expect(spec.columnIsNumeric("count") == true)
    }

    @Test("columnIsNumeric treats numeric strings as numeric")
    func columnIsNumericForNumericStrings() {
        let spec = PlotChartSpec.fromPlotArgs([
            "spec": .object([
                "dataset": .object([
                    "rows": .array([
                        .object(["x": .string("1.5"), "y": .number(10)]),
                        .object(["x": .string("2.5"), "y": .number(20)]),
                    ]),
                ]),
                "marks": .array([
                    .object(["type": .string("bar"), "x": .string("x"), "y": .string("y")]),
                ]),
            ]),
        ])

        guard let spec else {
            Issue.record("Expected PlotChartSpec to parse")
            return
        }
        #expect(spec.columnIsNumeric("x") == true)
    }

    @Test("columnIsNumeric returns true for missing key")
    func columnIsNumericForMissingKey() {
        let spec = PlotChartSpec.fromPlotArgs([
            "spec": .object([
                "dataset": .object([
                    "rows": .array([
                        .object(["x": .number(1), "y": .number(10)]),
                    ]),
                ]),
                "marks": .array([
                    .object(["type": .string("bar"), "x": .string("x"), "y": .string("y")]),
                ]),
            ]),
        ])

        guard let spec else {
            Issue.record("Expected PlotChartSpec to parse")
            return
        }
        // No row has "z", defaults to true
        #expect(spec.columnIsNumeric("z") == true)
        #expect(spec.columnIsNumeric(nil) == true)
    }

    @Test("parses categorical bar chart spec from plot args")
    func fromPlotArgsCategoricalBar() {
        let spec = PlotChartSpec.fromPlotArgs([
            "title": .string("Tester States"),
            "spec": .object([
                "dataset": .object([
                    "rows": .array([
                        .object(["state": .string("Invited"), "count": .number(5)]),
                        .object(["state": .string("Accepted"), "count": .number(3)]),
                    ]),
                ]),
                "marks": .array([
                    .object(["type": .string("bar"), "x": .string("state"), "y": .string("count")]),
                ]),
            ]),
        ])

        guard let spec else {
            Issue.record("Expected PlotChartSpec to parse")
            return
        }
        #expect(spec.title == "Tester States")
        #expect(spec.rows.count == 2)
        #expect(spec.marks.count == 1)
        #expect(spec.rows[0].seriesLabel(for: "state") == "Invited")
        #expect(spec.rows[0].number(for: "state") == nil)
        #expect(spec.rows[0].number(for: "count") == 5)
    }

    @Test("ignores unsupported chart version")
    func fromToolDetailsIgnoresUnsupportedVersion() {
        let details: JSONValue = .object([
            "ui": .array([
                .object([
                    "id": .string("chart-1"),
                    "kind": .string("chart"),
                    "version": .number(2),
                    "spec": .object([
                        "dataset": .object([
                            "rows": .array([
                                .object(["x": .number(0), "pace": .number(295)]),
                            ]),
                        ]),
                        "marks": .array([
                            .object(["type": .string("line"), "x": .string("x"), "y": .string("pace")]),
                        ]),
                    ]),
                ]),
            ]),
        ])

        #expect(PlotChartSpec.fromToolDetails(details) == nil)
    }
}
