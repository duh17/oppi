import { describe, expect, it } from "vitest";
import { sanitizeToolResultDetails } from "../src/visual-schema.js";

function makeValidChart(id: string, rowCount = 2): Record<string, unknown> {
  return {
    id,
    kind: "chart",
    version: 1,
    title: "Pace",
    spec: {
      dataset: {
        rows: Array.from({ length: rowCount }, (_, index) => ({
          x: index,
          pace: 295 - index,
        })),
      },
      marks: [{ type: "line", x: "x", y: "pace", interpolation: "catmullRom" }],
      axes: {
        x: { label: "Distance" },
        y: { label: "Pace", invert: true },
      },
      interaction: {
        xSelection: true,
      },
    },
  };
}

describe("sanitizeToolResultDetails", () => {
  it("sanitizes chart ui payload and preserves non-ui details", () => {
    const details = {
      source: "plot-extension",
      ui: [
        {
          id: "run-1",
          kind: "chart",
          version: 1,
          title: "Run",
          spec: {
            dataset: {
              rows: [
                { x: 0, pace: 295, heartRate: Infinity },
                { x: 1, pace: 292 },
              ],
            },
            marks: [
              { type: "line", x: "x", y: "pace", unknown: true },
              { type: "rule", xValue: 1, label: "1k" },
            ],
            axes: {
              x: { label: "Distance" },
              y: { label: "Pace", invert: true },
            },
            unknownTopLevel: "drop me",
          },
          fallbackText: "fallback",
        },
      ],
    };

    const result = sanitizeToolResultDetails(details);
    const sanitized = result.details as { source?: string; ui?: unknown[] };

    expect(sanitized.source).toBe("plot-extension");
    expect(Array.isArray(sanitized.ui)).toBe(true);
    expect(sanitized.ui?.length).toBe(1);

    const chart = sanitized.ui?.[0] as {
      kind?: string;
      version?: number;
      spec?: { dataset?: { rows?: Array<Record<string, unknown>> } };
    };

    expect(chart.kind).toBe("chart");
    expect(chart.version).toBe(1);

    const rows = chart.spec?.dataset?.rows ?? [];
    expect(rows.length).toBe(2);
    expect(rows[0]?.heartRate).toBeUndefined();
    expect(rows[0]?.x).toBe(0);
    expect(rows[0]?.pace).toBe(295);
  });

  it("drops unsupported chart entries and removes ui when nothing valid remains", () => {
    const result = sanitizeToolResultDetails({
      note: "keep me",
      ui: [
        {
          id: "bad-1",
          kind: "chart",
          version: 1,
          spec: {
            dataset: { rows: [{ x: 1, y: 2 }] },
            marks: [{ type: "heatmap", x: "x", y: "y" }],
          },
        },
      ],
    });

    const sanitized = result.details as { note?: string; ui?: unknown[] };
    expect(sanitized.note).toBe("keep me");
    expect(sanitized.ui).toBeUndefined();
    expect(result.warnings.some((warning) => warning.includes("unsupported"))).toBe(true);
    expect(result.warnings.some((warning) => warning.includes("all details.ui entries"))).toBe(
      true,
    );
  });

  it("caps ui entries and chart rows", () => {
    const uiEntries = Array.from({ length: 10 }, (_, index) =>
      makeValidChart(`chart-${index}`, 6_100),
    );

    const result = sanitizeToolResultDetails({ ui: uiEntries });
    const sanitized = result.details as {
      ui?: Array<{ spec?: { dataset?: { rows?: unknown[] } } }>;
    };

    expect(Array.isArray(sanitized.ui)).toBe(true);
    expect((sanitized.ui?.length ?? 0) > 0).toBe(true);
    expect((sanitized.ui?.length ?? 0) <= 8).toBe(true);

    for (const chart of sanitized.ui ?? []) {
      const rows = chart.spec?.dataset?.rows ?? [];
      expect(rows.length).toBe(5_000);
    }

    expect(result.warnings.some((warning) => warning.includes("capped"))).toBe(true);
  });

  it("sanitizes renderHints and clamps supported ranges", () => {
    const result = sanitizeToolResultDetails({
      ui: [
        {
          id: "hints-1",
          kind: "chart",
          version: 1,
          spec: {
            dataset: {
              rows: [
                { x: 0, y: 5 },
                { x: 1, y: 8 },
              ],
            },
            marks: [{ type: "line", x: "x", y: "y" }],
            renderHints: {
              xAxis: {
                type: "time",
                maxVisibleTicks: 99,
                labelFormat: "DATE-SHORT",
                strategy: "stride",
              },
              yAxis: {
                maxTicks: 1,
                nice: true,
                zeroBaseline: "always",
              },
              legend: {
                mode: "show",
                maxItems: 99,
              },
              grid: {
                vertical: "major",
                horizontal: "none",
              },
            },
          },
        },
      ],
    });

    const sanitized = result.details as {
      ui?: Array<{
        spec?: {
          renderHints?: {
            xAxis?: {
              type?: string;
              maxVisibleTicks?: number;
              labelFormat?: string;
              strategy?: string;
            };
            yAxis?: {
              maxTicks?: number;
              nice?: boolean;
              zeroBaseline?: string;
            };
            legend?: {
              mode?: string;
              maxItems?: number;
            };
            grid?: {
              vertical?: string;
              horizontal?: string;
            };
          };
        };
      }>;
    };

    const hints = sanitized.ui?.[0]?.spec?.renderHints;
    expect(hints?.xAxis).toEqual({
      type: "time",
      maxVisibleTicks: 8,
      labelFormat: "date-short",
      strategy: "stride",
    });
    expect(hints?.yAxis).toEqual({ maxTicks: 2, nice: true, zeroBaseline: "always" });
    expect(hints?.legend).toEqual({ mode: "show", maxItems: 5 });
    expect(hints?.grid).toEqual({ vertical: "major" });

    expect(
      result.warnings.some((warning) =>
        warning.includes("renderHints.xAxis.maxVisibleTicks clamped"),
      ),
    ).toBe(true);
    expect(
      result.warnings.some((warning) => warning.includes("renderHints.yAxis.maxTicks clamped")),
    ).toBe(true);
    expect(
      result.warnings.some((warning) => warning.includes("renderHints.legend.maxItems clamped")),
    ).toBe(true);
    expect(
      result.warnings.some((warning) =>
        warning.includes("dropped invalid renderHints.grid.horizontal"),
      ),
    ).toBe(true);
  });

  it("drops dense category x-axis type hint when scroll is disabled", () => {
    const rows = Array.from({ length: 50 }, (_, index) => ({
      bucket: `day-${index}`,
      value: index,
    }));

    const result = sanitizeToolResultDetails({
      ui: [
        {
          id: "dense-category",
          kind: "chart",
          version: 1,
          spec: {
            dataset: { rows },
            marks: [{ type: "bar", x: "bucket", y: "value" }],
            renderHints: {
              xAxis: {
                type: "category",
                maxVisibleTicks: 6,
              },
            },
          },
        },
      ],
    });

    const sanitized = result.details as {
      ui?: Array<{
        spec?: {
          renderHints?: {
            xAxis?: {
              type?: string;
              maxVisibleTicks?: number;
            };
          };
        };
      }>;
    };

    const xAxisHints = sanitized.ui?.[0]?.spec?.renderHints?.xAxis;
    expect(xAxisHints?.type).toBeUndefined();
    expect(xAxisHints?.maxVisibleTicks).toBe(6);
    expect(
      result.warnings.some((warning) =>
        warning.includes("dropped renderHints.xAxis.type category"),
      ),
    ).toBe(true);
  });

  it("keeps category x-axis type hint when scroll is enabled", () => {
    const rows = Array.from({ length: 50 }, (_, index) => ({
      bucket: `day-${index}`,
      value: index,
    }));

    const result = sanitizeToolResultDetails({
      ui: [
        {
          id: "dense-scrollable-category",
          kind: "chart",
          version: 1,
          spec: {
            dataset: { rows },
            marks: [{ type: "bar", x: "bucket", y: "value" }],
            interaction: {
              scrollableX: true,
            },
            renderHints: {
              xAxis: {
                type: "category",
                maxVisibleTicks: 6,
              },
            },
          },
        },
      ],
    });

    const sanitized = result.details as {
      ui?: Array<{
        spec?: {
          renderHints?: {
            xAxis?: {
              type?: string;
            };
          };
        };
      }>;
    };

    expect(sanitized.ui?.[0]?.spec?.renderHints?.xAxis?.type).toBe("category");
    expect(
      result.warnings.some((warning) =>
        warning.includes("dropped renderHints.xAxis.type category"),
      ),
    ).toBe(false);
  });
});

function makeChartDetails(specOverrides: Record<string, unknown> = {}): unknown {
  return {
    ui: [
      {
        kind: "chart",
        version: 1,
        spec: {
          dataset: {
            rows: [
              { x: 1, y: 10 },
              { x: 2, y: 20 },
            ],
          },
          marks: [{ type: "line", x: "x", y: "y" }],
          ...specOverrides,
        },
      },
    ],
  };
}

function getSpec(result: { details: unknown }): Record<string, unknown> {
  const details = result.details as Record<string, unknown>;
  const ui = details.ui as Record<string, unknown>[];
  return ui[0].spec as Record<string, unknown>;
}

describe("visual-schema colorScale", () => {
  it("preserves valid hex colors", () => {
    const result = sanitizeToolResultDetails(
      makeChartDetails({
        colorScale: { keep: "#00FF00", crash: "#FF0000", discard: "#FFA500" },
      }),
    );
    expect(result.warnings).toEqual([]);
    const spec = getSpec(result);
    expect(spec.colorScale).toEqual({
      keep: "#00FF00",
      crash: "#FF0000",
      discard: "#FFA500",
    });
  });

  it("accepts 3-char hex", () => {
    const result = sanitizeToolResultDetails(makeChartDetails({ colorScale: { a: "#F00" } }));
    expect(result.warnings).toEqual([]);
    expect(getSpec(result).colorScale).toEqual({ a: "#F00" });
  });

  it("accepts 8-char hex (with alpha)", () => {
    const result = sanitizeToolResultDetails(makeChartDetails({ colorScale: { a: "#FF000080" } }));
    expect(result.warnings).toEqual([]);
    expect(getSpec(result).colorScale).toEqual({ a: "#FF000080" });
  });

  it("drops invalid colors with warning", () => {
    const result = sanitizeToolResultDetails(
      makeChartDetails({ colorScale: { a: "red", b: "#FF0000" } }),
    );
    expect(result.warnings).toContain('dropped invalid colorScale color for "a"');
    expect(getSpec(result).colorScale).toEqual({ b: "#FF0000" });
  });

  it("drops non-object colorScale silently", () => {
    const result = sanitizeToolResultDetails(makeChartDetails({ colorScale: "red" }));
    expect(result.warnings).toEqual([]);
    expect(getSpec(result).colorScale).toBeUndefined();
  });

  it("omits empty colorScale", () => {
    const result = sanitizeToolResultDetails(makeChartDetails({ colorScale: {} }));
    expect(getSpec(result).colorScale).toBeUndefined();
  });
});

describe("visual-schema annotations", () => {
  it("preserves valid annotations", () => {
    const result = sanitizeToolResultDetails(
      makeChartDetails({
        annotations: [
          { x: 5, y: 42.3, text: "Best run", anchor: "top" },
          { x: 1, y: 60, text: "Baseline" },
        ],
      }),
    );
    expect(result.warnings).toEqual([]);
    const annotations = getSpec(result).annotations as Record<string, unknown>[];
    expect(annotations.length).toBe(2);
    expect(annotations[0]).toEqual({ x: 5, y: 42.3, text: "Best run", anchor: "top" });
    expect(annotations[1]).toEqual({ x: 1, y: 60, text: "Baseline" });
  });

  it("validates anchor enum", () => {
    const result = sanitizeToolResultDetails(
      makeChartDetails({
        annotations: [{ x: 1, y: 2, text: "test", anchor: "Leading" }],
      }),
    );
    const annotations = getSpec(result).annotations as Record<string, unknown>[];
    expect(annotations[0].anchor).toBe("leading");
  });

  it("drops annotations missing required fields", () => {
    const result = sanitizeToolResultDetails(
      makeChartDetails({
        annotations: [
          { x: 1, text: "no y" },
          { x: 1, y: 2 },
          { x: 1, y: 2, text: "valid" },
        ],
      }),
    );
    expect(result.warnings).toContain("dropped incomplete annotation (needs x, y, text)");
    const annotations = getSpec(result).annotations as Record<string, unknown>[];
    expect(annotations.length).toBe(1);
    expect(annotations[0].text).toBe("valid");
  });

  it("caps at 10 annotations", () => {
    const many = Array.from({ length: 15 }, (_, i) => ({
      x: i,
      y: i,
      text: `Point ${i}`,
    }));
    const result = sanitizeToolResultDetails(makeChartDetails({ annotations: many }));
    expect(result.warnings).toContain("annotations capped at 10");
    const annotations = getSpec(result).annotations as Record<string, unknown>[];
    expect(annotations.length).toBe(10);
  });

  it("omits empty annotations", () => {
    const result = sanitizeToolResultDetails(makeChartDetails({ annotations: [] }));
    expect(getSpec(result).annotations).toBeUndefined();
  });
});

describe("visual-schema area mark with yStart/yEnd", () => {
  it("accepts area mark with x + yStart + yEnd (no y)", () => {
    const result = sanitizeToolResultDetails({
      ui: [
        {
          kind: "chart",
          version: 1,
          spec: {
            dataset: {
              rows: [
                { x: 1, lo: 5, hi: 15 },
                { x: 2, lo: 8, hi: 18 },
              ],
            },
            marks: [{ type: "area", x: "x", yStart: "lo", yEnd: "hi" }],
          },
        },
      ],
    });
    expect(result.warnings).toEqual([]);
    const spec = getSpec(result);
    const marks = spec.marks as Record<string, unknown>[];
    expect(marks.length).toBe(1);
    expect(marks[0].type).toBe("area");
    expect(marks[0].yStart).toBe("lo");
    expect(marks[0].yEnd).toBe("hi");
  });

  it("rejects area mark with only x (no y and no yStart/yEnd)", () => {
    const result = sanitizeToolResultDetails({
      ui: [
        {
          kind: "chart",
          version: 1,
          spec: {
            dataset: { rows: [{ x: 1 }] },
            marks: [{ type: "area", x: "x" }],
          },
        },
      ],
    });
    expect(result.warnings).toContain("dropped incomplete chart mark (area)");
  });
});
