import { describe, expect, it } from "vitest";
import {
  PLOT_SPEC_HEIGHT_MAX,
  PLOT_SPEC_HEIGHT_MIN,
  buildFallbackSummary,
  executePlotTool,
  normalizeForMobile,
} from "../experiments/extensions/plot-extension.js";
import { CHART_HEIGHT_MAX, CHART_HEIGHT_MIN } from "../src/visual-schema.js";

describe("plot extension mobile normalization", () => {
  it("keeps extension and sanitizer height caps aligned", () => {
    expect(PLOT_SPEC_HEIGHT_MIN).toBe(CHART_HEIGHT_MIN);
    expect(PLOT_SPEC_HEIGHT_MAX).toBe(CHART_HEIGHT_MAX);
    expect(PLOT_SPEC_HEIGHT_MAX).toBe(480);
  });

  it("enables horizontal scroll defaults for dense sequential domains", () => {
    const spec = {
      dataset: {
        rows: Array.from({ length: 30 }, (_, index) => ({
          x: index,
          y: 290 - index,
        })),
      },
      marks: [{ type: "line", x: "x", y: "y" }],
    };

    const normalized = normalizeForMobile(spec);

    expect(normalized.spec.interaction?.scrollableX).toBe(true);
    expect(normalized.spec.interaction?.xVisibleDomainLength).toBe(12);
    expect(normalized.spec.renderHints?.legend?.mode).toBe("auto");
    expect(normalized.spec.renderHints?.legend?.maxItems).toBe(3);
    expect(
      normalized.warnings.some((warning) => warning.includes("dense sequential x domain")),
    ).toBe(true);
  });

  it("applies high-cardinality bar safeguards", () => {
    const spec = {
      dataset: {
        rows: Array.from({ length: 50 }, (_, index) => ({
          bucket: `day-${index}`,
          value: index,
        })),
      },
      marks: [{ type: "bar", x: "bucket", y: "value" }],
    };

    const normalized = normalizeForMobile(spec);

    expect(normalized.spec.interaction?.scrollableX).toBe(true);
    expect(normalized.spec.interaction?.xVisibleDomainLength).toBe(14);
    expect(
      normalized.warnings.some((warning) => warning.includes("high-cardinality bar categories")),
    ).toBe(true);
    expect(
      normalized.warnings.some((warning) => warning.includes("consider pre-aggregating")),
    ).toBe(true);
  });

  it("clamps legend maxItems and reports mobile legend limits", () => {
    const spec = {
      dataset: {
        rows: [
          { x: 0, y: 1, series: "a" },
          { x: 0, y: 2, series: "b" },
          { x: 0, y: 3, series: "c" },
          { x: 0, y: 4, series: "d" },
        ],
      },
      marks: [{ type: "line", x: "x", y: "y", series: "series" }],
      renderHints: {
        legend: {
          mode: "show",
          maxItems: 99,
        },
      },
    };

    const normalized = normalizeForMobile(spec);

    expect(normalized.spec.renderHints?.legend?.mode).toBe("show");
    expect(normalized.spec.renderHints?.legend?.maxItems).toBe(3);
    expect(normalized.warnings.some((warning) => warning.includes("clamped legend maxItems"))).toBe(
      true,
    );
    expect(
      normalized.warnings.some((warning) => warning.includes("visible series groups to 3")),
    ).toBe(true);
  });

  it("builds fallback text with mobile adjustment warnings", () => {
    const summary = buildFallbackSummary({
      title: "Pace",
      rows: 42,
      marks: 2,
      warnings: ["enabled horizontal scrolling"],
      fallbackText: "Trend summary",
    });

    expect(summary).toContain("Trend summary");
    expect(summary).toContain("Mobile adjustments:");
    expect(summary).toContain("enabled horizontal scrolling");
  });

  it("executePlotTool always emits fallback text and normalized spec", async () => {
    const response = await executePlotTool("call-1", {
      spec: {
        dataset: {
          rows: Array.from({ length: 30 }, (_, index) => ({ x: index, y: index * 2 })),
        },
        marks: [{ type: "line", x: "x", y: "y" }],
      },
    });

    const ui = response.details.ui[0] as {
      fallbackText?: string;
      spec?: {
        interaction?: {
          scrollableX?: boolean;
          xVisibleDomainLength?: number;
        };
      };
    };

    expect(typeof ui.fallbackText).toBe("string");
    expect(ui.fallbackText?.length ?? 0).toBeGreaterThan(0);
    expect(ui.spec?.interaction?.scrollableX).toBe(true);
    expect(ui.spec?.interaction?.xVisibleDomainLength).toBe(12);
  });
});
