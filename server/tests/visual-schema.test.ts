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
});
