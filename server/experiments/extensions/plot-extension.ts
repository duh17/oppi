import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";
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

const plotSpecSchema = Type.Object({
  title: Type.Optional(Type.String()),
  dataset: Type.Object({
    rows: Type.Array(Type.Record(Type.String(), scalar), { minItems: 1, maxItems: 5000 }),
  }),
  marks: Type.Array(markSchema, { minItems: 1, maxItems: 32 }),
  axes: Type.Optional(
    Type.Object({
      x: Type.Optional(Type.Object({ label: Type.Optional(Type.String()) })),
      y: Type.Optional(Type.Object({
        label: Type.Optional(Type.String()),
        invert: Type.Optional(Type.Boolean()),
      })),
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
  height: Type.Optional(Type.Number({ minimum: 120, maximum: 480 })),
});

export default function registerPlotTool(pi: ExtensionAPI): void {
  pi.registerTool({
    name: "plot",
    label: "Plot",
    description:
      "Render chart UI in Oppi chat. Pass a chart spec with rows + marks.",
    parameters: Type.Object({
      title: Type.Optional(Type.String()),
      spec: plotSpecSchema,
      fallbackText: Type.Optional(Type.String()),
      fallbackImageDataUri: Type.Optional(Type.String()),
    }),
    async execute(toolCallId, params) {
      const title = params.title ?? params.spec.title ?? "Plot";
      const rows = params.spec.dataset.rows.length;
      const marks = params.spec.marks.length;

      const summary = params.fallbackText
        ?? `Rendered plot \"${title}\" (${marks} mark${marks === 1 ? "" : "s"}, ${rows} row${rows === 1 ? "" : "s"}).`;

      return {
        content: [{ type: "text", text: summary }],
        details: {
          ui: [
            {
              id: `plot-${toolCallId}`,
              kind: "chart",
              version: 1,
              title,
              spec: params.spec,
              fallbackText: params.fallbackText,
              fallbackImageDataUri: params.fallbackImageDataUri,
            },
          ],
        },
      };
    },
  });
}
