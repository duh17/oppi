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
    expect(
      result.warnings.some((warning) => warning.includes("all details.ui entries")),
    ).toBe(true);
  });

  it("caps ui entries and chart rows", () => {
    const uiEntries = Array.from({ length: 10 }, (_, index) => makeValidChart(`chart-${index}`, 6_100));

    const result = sanitizeToolResultDetails({ ui: uiEntries });
    const sanitized = result.details as { ui?: Array<{ spec?: { dataset?: { rows?: unknown[] } } }> };

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
      result.warnings.some((warning) => warning.includes("renderHints.xAxis.maxVisibleTicks clamped")),
    ).toBe(true);
    expect(result.warnings.some((warning) => warning.includes("renderHints.yAxis.maxTicks clamped"))).toBe(
      true,
    );
    expect(
      result.warnings.some((warning) => warning.includes("renderHints.legend.maxItems clamped")),
    ).toBe(true);
    expect(
      result.warnings.some((warning) => warning.includes("dropped invalid renderHints.grid.horizontal")),
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
      result.warnings.some((warning) => warning.includes("dropped renderHints.xAxis.type category")),
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
      result.warnings.some((warning) => warning.includes("dropped renderHints.xAxis.type category")),
    ).toBe(false);
  });
});
