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

    @Test("parses render hints with clamped numeric bounds")
    func fromPlotArgsParsesRenderHints() {
        let spec = PlotChartSpec.fromPlotArgs([
            "spec": .object([
                "dataset": .object([
                    "rows": .array([
                        .object(["x": .number(0), "y": .number(10)]),
                        .object(["x": .number(1), "y": .number(20)]),
                    ]),
                ]),
                "marks": .array([
                    .object(["type": .string("line"), "x": .string("x"), "y": .string("y")]),
                ]),
                "renderHints": .object([
                    "xAxis": .object([
                        "type": .string("numeric"),
                        "maxVisibleTicks": .number(99),
                    ]),
                    "yAxis": .object([
                        "maxTicks": .number(1),
                    ]),
                    "legend": .object([
                        "mode": .string("show"),
                        "maxItems": .number(0),
                    ]),
                    "grid": .object([
                        "vertical": .string("none"),
                        "horizontal": .string("major"),
                    ]),
                ]),
            ]),
        ])

        guard let spec else {
            Issue.record("Expected PlotChartSpec to parse")
            return
        }

        #expect(spec.renderHints?.xAxis?.type == .numeric)
        #expect(spec.renderHints?.xAxis?.maxVisibleTicks == 8)
        #expect(spec.renderHints?.yAxis?.maxTicks == 2)
        #expect(spec.renderHints?.legend?.mode == .show)
        #expect(spec.renderHints?.legend?.maxItems == 1)
        #expect(spec.renderHints?.grid?.vertical == PlotChartSpec.RenderHints.Grid.Vertical.none)
        #expect(spec.renderHints?.grid?.horizontal == .major)
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

@Suite("PlotRenderPolicy")
struct PlotRenderPolicyTests {
    @Test("tick budget clamps to phone-friendly range")
    func tickBudgetClampsToPhoneRange() {
        #expect(PlotRenderPolicy.tickBudget(for: 200) == 4)
        #expect(PlotRenderPolicy.tickBudget(for: 320) == 5)
        #expect(PlotRenderPolicy.tickBudget(for: 390) == 6)
        #expect(PlotRenderPolicy.tickBudget(for: 500) == 6)
    }

    @Test("y-axis major tick target tightens on compact widths")
    func yTickTargetAdjustsForCompactWidths() {
        let spec = makeSpec(
            rows: [
                .object(["x": .number(0), "y": .number(1)]),
                .object(["x": .number(1), "y": .number(2)]),
            ],
            marks: [
                .object([
                    "type": .string("line"),
                    "x": .string("x"),
                    "y": .string("y"),
                ]),
            ]
        )

        #expect(PlotRenderPolicy(spec: spec, viewportWidth: 320).yTickCount == 4)
        #expect(PlotRenderPolicy(spec: spec, viewportWidth: 390).yTickCount == 5)
    }

    @Test("render hints can tighten axis tick budgets")
    func renderHintsCanTightenTickBudgets() {
        let spec = makeSpec(
            rows: [
                .object(["x": .number(0), "y": .number(1)]),
                .object(["x": .number(1), "y": .number(2)]),
                .object(["x": .number(2), "y": .number(3)]),
            ],
            marks: [
                .object([
                    "type": .string("line"),
                    "x": .string("x"),
                    "y": .string("y"),
                ]),
            ],
            extraSpec: [
                "renderHints": .object([
                    "xAxis": .object(["maxVisibleTicks": .number(2)]),
                    "yAxis": .object(["maxTicks": .number(3)]),
                ]),
            ]
        )

        let policy = PlotRenderPolicy(spec: spec, viewportWidth: 390)
        #expect(policy.xTickBudget == 2)
        #expect(policy.yTickCount == 3)
    }

    @Test("x-axis decimation keeps first and last category anchors")
    func categoryXAxisDecimationKeepsAnchors() {
        let rows: [JSONValue] = (0..<12).map { index in
            .object([
                "day": .string("day-\(index)"),
                "value": .number(Double(index) * 1.5),
            ])
        }

        let spec = makeSpec(
            rows: rows,
            marks: [
                .object([
                    "type": .string("bar"),
                    "x": .string("day"),
                    "y": .string("value"),
                ]),
            ]
        )

        let policy = PlotRenderPolicy(spec: spec, viewportWidth: 320)
        switch policy.xTickValues {
        case .category(let labels):
            #expect(labels.count <= policy.xTickBudget)
            #expect(labels.first == "day-0")
            #expect(labels.last == "day-11")
        default:
            Issue.record("Expected categorical x tick labels")
        }
    }

    @Test("x-axis decimation keeps first and last numeric anchors")
    func numericXAxisDecimationKeepsAnchors() {
        let rows: [JSONValue] = (0..<30).map { index in
            .object([
                "x": .number(Double(index)),
                "y": .number(Double(index * 2)),
            ])
        }

        let spec = makeSpec(
            rows: rows,
            marks: [
                .object([
                    "type": .string("line"),
                    "x": .string("x"),
                    "y": .string("y"),
                ]),
            ]
        )

        let policy = PlotRenderPolicy(spec: spec, viewportWidth: 320)
        switch policy.xTickValues {
        case .numeric(let values):
            #expect(values.count <= policy.xTickBudget)
            #expect(values.first == 0)
            #expect(values.last == 29)
        default:
            Issue.record("Expected numeric x tick values")
        }
    }

    @Test("policy exposes visible x tick count for telemetry")
    func policyExposesVisibleXTickCount() {
        let rows: [JSONValue] = (0..<30).map { index in
            .object([
                "x": .number(Double(index)),
                "y": .number(Double(index * 2)),
            ])
        }

        let spec = makeSpec(
            rows: rows,
            marks: [
                .object([
                    "type": .string("line"),
                    "x": .string("x"),
                    "y": .string("y"),
                ]),
            ]
        )

        let policy = PlotRenderPolicy(spec: spec, viewportWidth: 320)
        #expect(policy.xVisibleTickCount <= policy.xTickBudget)
        #expect(policy.autoAdjustmentCount >= 1)
    }

    @Test("x-axis category hint forces categorical tick labels")
    func categoryHintForcesCategoricalTicks() {
        let rows: [JSONValue] = (0..<8).map { index in
            .object([
                "x": .number(Double(index)),
                "y": .number(Double(index * 3)),
            ])
        }

        let spec = makeSpec(
            rows: rows,
            marks: [
                .object([
                    "type": .string("line"),
                    "x": .string("x"),
                    "y": .string("y"),
                ]),
            ],
            extraSpec: [
                "renderHints": .object([
                    "xAxis": .object([
                        "type": .string("category"),
                    ]),
                ]),
            ]
        )

        let policy = PlotRenderPolicy(spec: spec, viewportWidth: 390)
        switch policy.xTickValues {
        case .category(let labels):
            #expect(labels.first == "0")
            #expect(labels.last == "7")
        default:
            Issue.record("Expected category tick values when category hint is set")
        }
    }

    @Test("legend auto policy shows only for two or three series")
    func legendAutoPolicyBySeriesCount() {
        let singleSeries = makeSpec(
            rows: [
                .object(["x": .number(1), "y": .number(2)]),
                .object(["x": .number(2), "y": .number(3)]),
            ],
            marks: [
                .object([
                    "type": .string("line"),
                    "x": .string("x"),
                    "y": .string("y"),
                ]),
            ]
        )

        let threeSeries = makeSpec(
            rows: [
                .object(["x": .number(1), "y": .number(2), "series": .string("A")]),
                .object(["x": .number(1), "y": .number(3), "series": .string("B")]),
                .object(["x": .number(1), "y": .number(4), "series": .string("C")]),
            ],
            marks: [
                .object([
                    "type": .string("line"),
                    "x": .string("x"),
                    "y": .string("y"),
                    "series": .string("series"),
                ]),
            ]
        )

        let fourSeries = makeSpec(
            rows: [
                .object(["x": .number(1), "y": .number(2), "series": .string("A")]),
                .object(["x": .number(1), "y": .number(3), "series": .string("B")]),
                .object(["x": .number(1), "y": .number(4), "series": .string("C")]),
                .object(["x": .number(1), "y": .number(5), "series": .string("D")]),
            ],
            marks: [
                .object([
                    "type": .string("line"),
                    "x": .string("x"),
                    "y": .string("y"),
                    "series": .string("series"),
                ]),
            ]
        )

        #expect(!PlotRenderPolicy(spec: singleSeries, viewportWidth: 390).legendVisible)
        #expect(PlotRenderPolicy(spec: threeSeries, viewportWidth: 390).legendVisible)
        #expect(!PlotRenderPolicy(spec: fourSeries, viewportWidth: 390).legendVisible)
    }

    @Test("legend auto policy ignores rule marks")
    func legendAutoPolicyIgnoresRuleMarks() {
        let spec = makeSpec(
            rows: [
                .object(["x": .number(1), "y": .number(2)]),
                .object(["x": .number(2), "y": .number(3)]),
            ],
            marks: [
                .object([
                    "type": .string("line"),
                    "x": .string("x"),
                    "y": .string("y"),
                ]),
                .object([
                    "type": .string("rule"),
                    "yValue": .number(2.5),
                    "label": .string("threshold"),
                ]),
            ]
        )

        #expect(!PlotRenderPolicy(spec: spec, viewportWidth: 390).legendVisible)
    }

    @Test("legend show hint can force single-series legend")
    func legendShowHintForSingleSeries() {
        let spec = makeSpec(
            rows: [
                .object(["x": .number(1), "y": .number(2)]),
                .object(["x": .number(2), "y": .number(3)]),
            ],
            marks: [
                .object([
                    "type": .string("line"),
                    "x": .string("x"),
                    "y": .string("y"),
                ]),
            ],
            extraSpec: [
                "renderHints": .object([
                    "legend": .object([
                        "mode": .string("show"),
                        "maxItems": .number(2),
                    ]),
                ]),
            ]
        )

        #expect(PlotRenderPolicy(spec: spec, viewportWidth: 390).legendVisible)
    }

    @Test("legend item count reflects visible legend entries")
    func legendItemCountReflectsVisibleEntries() {
        let threeSeries = makeSpec(
            rows: [
                .object(["x": .number(1), "y": .number(2), "series": .string("A")]),
                .object(["x": .number(1), "y": .number(3), "series": .string("B")]),
                .object(["x": .number(1), "y": .number(4), "series": .string("C")]),
            ],
            marks: [
                .object([
                    "type": .string("line"),
                    "x": .string("x"),
                    "y": .string("y"),
                    "series": .string("series"),
                ]),
            ]
        )

        let singleSeries = makeSpec(
            rows: [
                .object(["x": .number(1), "y": .number(2)]),
                .object(["x": .number(2), "y": .number(3)]),
            ],
            marks: [
                .object([
                    "type": .string("line"),
                    "x": .string("x"),
                    "y": .string("y"),
                ]),
            ]
        )

        #expect(PlotRenderPolicy(spec: threeSeries, viewportWidth: 390).legendItemCount == 3)
        #expect(PlotRenderPolicy(spec: singleSeries, viewportWidth: 390).legendItemCount == 0)
    }

    @Test("vertical gridlines are disabled for dense x domains")
    func verticalGridlineDensityPolicy() {
        let sparseRows: [JSONValue] = (0..<4).map { index in
            .object(["x": .number(Double(index)), "y": .number(Double(index + 1))])
        }
        let denseRows: [JSONValue] = (0..<20).map { index in
            .object(["x": .number(Double(index)), "y": .number(Double(index + 1))])
        }

        let marks: [JSONValue] = [
            .object([
                "type": .string("line"),
                "x": .string("x"),
                "y": .string("y"),
            ]),
        ]

        let sparseSpec = makeSpec(rows: sparseRows, marks: marks)
        let denseSpec = makeSpec(rows: denseRows, marks: marks)

        #expect(PlotRenderPolicy(spec: sparseSpec, viewportWidth: 390).showVerticalGridlines)
        #expect(!PlotRenderPolicy(spec: denseSpec, viewportWidth: 390).showVerticalGridlines)
        #expect(PlotRenderPolicy(spec: denseSpec, viewportWidth: 390).showHorizontalGridlines)
    }

    @Test("grid hints can force vertical gridlines off")
    func gridHintsCanDisableVerticalGridlines() {
        let rows: [JSONValue] = (0..<4).map { index in
            .object(["x": .number(Double(index)), "y": .number(Double(index + 1))])
        }

        let spec = makeSpec(
            rows: rows,
            marks: [
                .object([
                    "type": .string("line"),
                    "x": .string("x"),
                    "y": .string("y"),
                ]),
            ],
            extraSpec: [
                "renderHints": .object([
                    "grid": .object([
                        "vertical": .string("none"),
                    ]),
                ]),
            ]
        )

        let policy = PlotRenderPolicy(spec: spec, viewportWidth: 390)
        #expect(!policy.showVerticalGridlines)
        #expect(policy.showHorizontalGridlines)
    }

    @Test("x-axis falls back to automatic ticks when mark has no x key")
    func xAxisFallsBackToAutomaticWhenNoXKey() {
        let spec = makeSpec(
            rows: [
                .object(["value": .number(1)]),
                .object(["value": .number(2)]),
            ],
            marks: [
                .object([
                    "type": .string("rule"),
                    "yValue": .number(1.5),
                ]),
            ]
        )

        let policy = PlotRenderPolicy(spec: spec, viewportWidth: 390)
        #expect(policy.xTickValues == .automatic)
        #expect(!policy.showVerticalGridlines)
    }

    private func makeSpec(
        rows: [JSONValue],
        marks: [JSONValue],
        extraSpec: [String: JSONValue] = [:]
    ) -> PlotChartSpec {
        var specObject: [String: JSONValue] = [
            "dataset": .object([
                "rows": .array(rows),
            ]),
            "marks": .array(marks),
        ]

        for (key, value) in extraSpec {
            specObject[key] = value
        }

        let args: [String: JSONValue] = [
            "spec": .object(specObject),
        ]

        guard let spec = PlotChartSpec.fromPlotArgs(args) else {
            fatalError("Expected PlotChartSpec to parse")
        }

        return spec
    }
}
