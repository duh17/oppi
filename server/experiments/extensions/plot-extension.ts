import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type, type Static } from "@sinclair/typebox";
import { StringEnum } from "@mariozechner/pi-ai";

const markTypes = [
  "line",
  "area",
  "bar",
  "point",
  "rectangle",
  "rule",
  "sector",
] as const;

const xAxisTypes = ["auto", "time", "numeric", "category"] as const;
const xAxisLabelFormats = ["auto", "date-short", "date-day", "number-short"] as const;
const xAxisStrategies = ["auto", "start-end-weekly", "stride"] as const;
const yAxisZeroBaselines = ["auto", "always", "never"] as const;
const legendModes = ["auto", "show", "hide", "inline"] as const;
const gridVerticalModes = ["none", "major"] as const;
const gridHorizontalModes = ["major"] as const;

export const PLOT_SPEC_HEIGHT_MIN = 120;
export const PLOT_SPEC_HEIGHT_MAX = 480;

const scalar = Type.Union([Type.Number(), Type.String(), Type.Boolean()]);

const markSchema = Type.Object({
  id: Type.Optional(Type.String()),
  type: StringEnum(markTypes),
  x: Type.Optional(Type.String()),
  y: Type.Optional(Type.String()),
  xStart: Type.Optional(Type.String()),
  xEnd: Type.Optional(Type.String()),
  yStart: Type.Optional(Type.String()),
  yEnd: Type.Optional(Type.String()),
  angle: Type.Optional(Type.String()),
  xValue: Type.Optional(Type.Number()),
  yValue: Type.Optional(Type.Number()),
  series: Type.Optional(Type.String()),
  label: Type.Optional(Type.String()),
  interpolation: Type.Optional(
    StringEnum([
      "linear",
      "cardinal",
      "catmullRom",
      "monotone",
      "stepStart",
      "stepCenter",
      "stepEnd",
    ] as const),
  ),
});

const renderHintsSchema = Type.Object({
  xAxis: Type.Optional(
    Type.Object({
      type: Type.Optional(StringEnum(xAxisTypes)),
      maxVisibleTicks: Type.Optional(Type.Number({ minimum: 2, maximum: 8 })),
      labelFormat: Type.Optional(StringEnum(xAxisLabelFormats)),
      strategy: Type.Optional(StringEnum(xAxisStrategies)),
    }),
  ),
  yAxis: Type.Optional(
    Type.Object({
      maxTicks: Type.Optional(Type.Number({ minimum: 2, maximum: 8 })),
      nice: Type.Optional(Type.Boolean()),
      zeroBaseline: Type.Optional(StringEnum(yAxisZeroBaselines)),
    }),
  ),
  legend: Type.Optional(
    Type.Object({
      mode: Type.Optional(StringEnum(legendModes)),
      maxItems: Type.Optional(Type.Number({ minimum: 1, maximum: 5 })),
    }),
  ),
  grid: Type.Optional(
    Type.Object({
      vertical: Type.Optional(StringEnum(gridVerticalModes)),
      horizontal: Type.Optional(StringEnum(gridHorizontalModes)),
    }),
  ),
});

const plotSpecSchema = Type.Object({
  title: Type.Optional(Type.String()),
  dataset: Type.Object({
    rows: Type.Array(Type.Record(Type.String(), scalar), { minItems: 1, maxItems: 5000 }),
  }),
  marks: Type.Array(markSchema, { minItems: 1, maxItems: 32 }),
  axes: Type.Optional(
    Type.Object({
      x: Type.Optional(Type.Object({ label: Type.Optional(Type.String()) })),
      y: Type.Optional(
        Type.Object({
          label: Type.Optional(Type.String()),
          invert: Type.Optional(Type.Boolean()),
        }),
      ),
    }),
  ),
  interaction: Type.Optional(
    Type.Object({
      xSelection: Type.Optional(Type.Boolean()),
      xRangeSelection: Type.Optional(Type.Boolean()),
      scrollableX: Type.Optional(Type.Boolean()),
      xVisibleDomainLength: Type.Optional(Type.Number({ minimum: 0 })),
    }),
  ),
  renderHints: Type.Optional(renderHintsSchema),
  height: Type.Optional(
    Type.Number({ minimum: PLOT_SPEC_HEIGHT_MIN, maximum: PLOT_SPEC_HEIGHT_MAX }),
  ),
});

const plotToolParamsSchema = Type.Object({
  title: Type.Optional(Type.String()),
  spec: plotSpecSchema,
  fallbackText: Type.Optional(Type.String()),
  fallbackImageDataUri: Type.Optional(Type.String()),
});

type PlotToolParams = Static<typeof plotToolParamsSchema>;
type PlotSpec = PlotToolParams["spec"];
type PlotRow = PlotSpec["dataset"]["rows"][number];
type PlotMark = PlotSpec["marks"][number];

export interface NormalizedPlotSpecResult {
  spec: PlotSpec;
  warnings: string[];
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function cloneSpec(spec: PlotSpec): PlotSpec {
  return {
    ...spec,
    dataset: {
      rows: spec.dataset.rows.map((row) => ({ ...row })),
    },
    marks: spec.marks.map((mark) => ({ ...mark })),
    axes: spec.axes
      ? {
          x: spec.axes.x ? { ...spec.axes.x } : undefined,
          y: spec.axes.y ? { ...spec.axes.y } : undefined,
        }
      : undefined,
    interaction: spec.interaction ? { ...spec.interaction } : undefined,
    renderHints: spec.renderHints
      ? {
          xAxis: spec.renderHints.xAxis ? { ...spec.renderHints.xAxis } : undefined,
          yAxis: spec.renderHints.yAxis ? { ...spec.renderHints.yAxis } : undefined,
          legend: spec.renderHints.legend ? { ...spec.renderHints.legend } : undefined,
          grid: spec.renderHints.grid ? { ...spec.renderHints.grid } : undefined,
        }
      : undefined,
  };
}

function toFiniteNumber(value: unknown): number | undefined {
  if (typeof value === "number") {
    return Number.isFinite(value) ? value : undefined;
  }

  if (typeof value === "string") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : undefined;
  }

  return undefined;
}

function isMonotonicAscending(values: number[]): boolean {
  if (values.length < 2) {
    return false;
  }

  for (let index = 1; index < values.length; index += 1) {
    if (values[index] < values[index - 1]) {
      return false;
    }
  }

  return true;
}

function isSequentialDomain(values: unknown[]): boolean {
  if (values.length < 2) {
    return false;
  }

  const numeric = values.map((value) => toFiniteNumber(value));
  if (numeric.every((value) => typeof value === "number")) {
    return isMonotonicAscending(numeric as number[]);
  }

  const temporal = values.map((value) => {
    if (typeof value !== "string") {
      return Number.NaN;
    }
    return Date.parse(value);
  });

  if (temporal.every((value) => Number.isFinite(value))) {
    return isMonotonicAscending(temporal);
  }

  return false;
}

function getPrimaryXKey(marks: PlotMark[]): string | undefined {
  for (const mark of marks) {
    if (
      (mark.type === "line" || mark.type === "area" || mark.type === "bar" || mark.type === "point")
      && typeof mark.x === "string"
      && mark.x.length > 0
    ) {
      return mark.x;
    }
  }

  return undefined;
}

function getFirstBarXKey(marks: PlotMark[]): string | undefined {
  for (const mark of marks) {
    if (mark.type === "bar" && typeof mark.x === "string" && mark.x.length > 0) {
      return mark.x;
    }
  }

  return undefined;
}

function countSeries(spec: PlotSpec): number {
  const seen = new Set<string>();

  for (const mark of spec.marks) {
    if (mark.type === "rule") {
      continue;
    }

    if (typeof mark.series === "string" && mark.series.length > 0) {
      for (const row of spec.dataset.rows) {
        const rawValue = row[mark.series];
        const token = rawValue === undefined ? "" : String(rawValue);
        if (token.length > 0) {
          seen.add(token);
        }
        if (seen.size > 3) {
          return seen.size;
        }
      }
      continue;
    }

    const fallback = mark.label ?? mark.id ?? mark.type;
    seen.add(fallback);
    if (seen.size > 3) {
      return seen.size;
    }
  }

  return seen.size;
}

function uniqueValueCount(rows: PlotRow[], key: string): number {
  const values = new Set<string>();
  for (const row of rows) {
    const raw = row[key];
    if (raw !== undefined) {
      values.add(String(raw));
    }
  }
  return values.size;
}

function ensureMobileVisibleDomain(
  interaction: NonNullable<PlotSpec["interaction"]>,
  suggested: number,
  warnings: string[],
): void {
  const raw = interaction.xVisibleDomainLength;
  if (typeof raw !== "number" || !Number.isFinite(raw) || raw <= 0) {
    interaction.xVisibleDomainLength = suggested;
    warnings.push(`set x visible domain length to ${suggested}`);
    return;
  }

  const clamped = clamp(raw, 10, 14);
  if (clamped !== raw) {
    interaction.xVisibleDomainLength = clamped;
    warnings.push(`clamped x visible domain length to ${clamped}`);
  }
}

export function normalizeForMobile(input: PlotSpec): NormalizedPlotSpecResult {
  const spec = cloneSpec(input);
  const warnings: string[] = [];
  const rows = spec.dataset.rows;

  spec.renderHints ??= {};
  spec.renderHints.legend ??= {};

  if (!spec.renderHints.legend.mode) {
    spec.renderHints.legend.mode = "auto";
  }

  const rawLegendMax = spec.renderHints.legend.maxItems;
  if (typeof rawLegendMax !== "number" || !Number.isFinite(rawLegendMax)) {
    spec.renderHints.legend.maxItems = 3;
  } else {
    const clampedLegendMax = clamp(Math.round(rawLegendMax), 1, 3);
    if (clampedLegendMax !== rawLegendMax) {
      warnings.push(`clamped legend maxItems to ${clampedLegendMax}`);
    }
    spec.renderHints.legend.maxItems = clampedLegendMax;
  }

  const primaryXKey = getPrimaryXKey(spec.marks);
  if (rows.length > 24 && primaryXKey) {
    const values = rows
      .map((row) => row[primaryXKey])
      .filter((value) => typeof value !== "undefined");

    if (isSequentialDomain(values)) {
      spec.interaction ??= {};
      if (spec.interaction.scrollableX !== true) {
        spec.interaction.scrollableX = true;
        warnings.push("enabled horizontal scrolling for dense sequential x domain");
      }

      ensureMobileVisibleDomain(spec.interaction, 12, warnings);
    }
  }

  const barXKey = getFirstBarXKey(spec.marks);
  if (barXKey) {
    const categoryCount = uniqueValueCount(rows, barXKey);
    if (categoryCount > 40) {
      spec.interaction ??= {};
      if (spec.interaction.scrollableX !== true) {
        spec.interaction.scrollableX = true;
        warnings.push("enabled horizontal scrolling for high-cardinality bar categories");
      }

      ensureMobileVisibleDomain(spec.interaction, 14, warnings);
      warnings.push("bar domain is dense; consider pre-aggregating or binning data");
    }
  }

  const seriesCount = countSeries(spec);
  if (seriesCount > 3) {
    warnings.push("legend defaults limit visible series groups to 3 on mobile");
  }

  return {
    spec,
    warnings: [...new Set(warnings)],
  };
}

export function buildFallbackSummary(options: {
  title: string;
  rows: number;
  marks: number;
  warnings: string[];
  fallbackText?: string;
}): string {
  const baseSummary = `Rendered plot \"${options.title}\" (${options.marks} mark${options.marks === 1 ? "" : "s"}, ${options.rows} row${options.rows === 1 ? "" : "s"}).`;
  const trimmedFallback = options.fallbackText?.trim();
  const prefix = trimmedFallback && trimmedFallback.length > 0 ? trimmedFallback : baseSummary;

  if (options.warnings.length === 0) {
    return prefix;
  }

  return `${prefix} Mobile adjustments: ${options.warnings.join("; ")}.`;
}

export async function executePlotTool(toolCallId: string, params: PlotToolParams) {
  const normalization = normalizeForMobile(params.spec);
  const title = params.title ?? normalization.spec.title ?? "Plot";
  const rows = normalization.spec.dataset.rows.length;
  const marks = normalization.spec.marks.length;

  const fallbackText = buildFallbackSummary({
    title,
    rows,
    marks,
    warnings: normalization.warnings,
    fallbackText: params.fallbackText,
  });

  return {
    content: [{ type: "text", text: fallbackText }],
    details: {
      ui: [
        {
          id: `plot-${toolCallId}`,
          kind: "chart",
          version: 1,
          title,
          spec: normalization.spec,
          fallbackText,
          fallbackImageDataUri: params.fallbackImageDataUri,
        },
      ],
    },
  };
}

export default function registerPlotTool(pi: ExtensionAPI): void {
  pi.registerTool({
    name: "plot",
    label: "Plot",
    description:
      "Render chart UI in Oppi chat. Pass a chart spec with rows + marks.",
    parameters: plotToolParamsSchema,
    async execute(toolCallId, params) {
      return executePlotTool(toolCallId, params as PlotToolParams);
    },
  });
}
