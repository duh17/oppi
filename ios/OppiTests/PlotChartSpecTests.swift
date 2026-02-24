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
