import { describe, it, expect } from "vitest";
import { sanitizeToolResultDetails } from "./visual-schema.js";

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
