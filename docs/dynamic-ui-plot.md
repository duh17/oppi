# Dynamic UI in Chat: `plot` Tool Spec (v1)

Goal: support dynamically generated chart UI in Oppi chat from tool outputs, with safe validation and graceful fallbacks.

## Naming

Use extension tool name: **`plot`**.

- Short, model-friendly, and matches the main use case.
- No known built-in or standard `plot` tool signature exists in pi docs/examples, so this is an Oppi-defined contract.

## Transport Contract

### Current implementation

Oppi now supports both paths, in this order:

1. **Primary:** `tool_end.details.ui[]`
2. **Fallback:** `plot` tool args (`args.spec`)

This gives immediate backwards compatibility for older extensions while enabling
server-validated dynamic payloads.

### `tool_end.details` envelope

Use existing `tool_end.details` for richer cross-client compatibility:

```json
{
  "ui": [
    {
      "id": "run-overview-2026-02-24",
      "kind": "chart",
      "version": 1,
      "title": "Run Overview",
      "spec": { "...": "..." },
      "fallbackText": "Unable to render chart"
    }
  ]
}
```

Rules:
- `ui` is optional; when absent, tool behaves as plain text.
- Unknown `kind` or unsupported `version` must not crash rendering.
- Always keep text fallback in `content` and optionally `fallbackText` in details.

## `plot` Tool Signature (extension-side)

```ts
plot({
  title?: string,
  spec: VisualChartV1,
  fallbackText?: string,
  fallbackImageDataUri?: string
}) -> {
  content: [{ type: "text", text: string }],
  details?: {
    ui: [{
      id: string,
      kind: "chart",
      version: 1,
      title?: string,
      spec: VisualChartV1,
      fallbackText?: string,
      fallbackImageDataUri?: string
    }]
  }
}
```

Notes:
- Preferred: include chart payload in `details.ui`.
- Compatibility fallback: include `spec` in tool args (`plot(...)`) so older paths still render.
- `content` should include a compact human summary for LLM context and non-UI clients.

## `VisualChartV1` (flexible chart grammar)

```json
{
  "dataset": {
    "rows": [
      { "x": 0.0, "pace": 295, "hr": 132 },
      { "x": 0.1, "pace": 292, "hr": 136 }
    ]
  },
  "fields": {
    "x": { "type": "number", "label": "Distance", "unit": "km" },
    "pace": { "type": "number", "label": "Pace", "unit": "s/km" },
    "hr": { "type": "number", "label": "Heart Rate", "unit": "bpm" }
  },
  "marks": [
    { "type": "line", "x": "x", "y": "pace", "series": "pace" },
    { "type": "line", "x": "x", "y": "hr", "series": "hr" },
    { "type": "rule", "xValue": 5.0, "label": "5K" }
  ],
  "axes": {
    "x": { "label": "Distance (km)" },
    "y": { "label": "Pace (s/km)", "invert": true }
  },
  "interaction": {
    "xSelection": true,
    "xRangeSelection": true,
    "scrollableX": true
  }
}
```

### Supported mark types (v1)

Map directly to Swift Charts:
- `line` → `LineMark`
- `area` → `AreaMark`
- `bar` → `BarMark`
- `point` → `PointMark`
- `rectangle` → `RectangleMark`
- `rule` → `RuleMark`
- `sector` → `SectorMark`

## Validation & Safety

Server-side validation before forwarding to iOS:

- max payload bytes (e.g. 256KB)
- max rows (e.g. 5k)
- mark type allowlist
- numeric sanity checks (finite values only)
- trim unknown top-level fields

Failure mode:
- keep `content` text
- drop invalid `details.ui`
- log validation reason

## Wiring Plan

### Implemented

1. Extension registers `plot` tool and can return chart payload in `details.ui`.
2. Oppi server validates/sanitizes `details.ui` (size caps, row/mark caps, mark allowlist, finite numbers).
3. iOS stores `tool_end.details` and renders supported `kind=chart, version=1` payloads in expanded rows.
4. If details are absent/invalid, iOS falls back to `args.spec`.
5. If both rich paths fail, Oppi falls back to text output.

## Experimental extension sample

A runnable extension prototype is included at:

- `server/experiments/extensions/plot-extension.ts`

Install for local testing:

```bash
ln -s ~/workspace/oppi/server/experiments/extensions/plot-extension.ts ~/.pi/agent/extensions/plot.ts
```

Enable the `plot` extension in your Oppi workspace settings.

This file is not loaded by default server startup; it is only used when explicitly symlinked/registered as an extension.

## Kypu-first examples

- Pace + HR vs distance/time (multi-line)
- Elevation profile (line/area)
- Lap/segment boundaries (rule marks)
- Best-efforts trend over dates (line/point)
- Distribution histograms (bar)

## Phase 2 (optional)

Add client->server chart interaction events (`pointTap`, `rangeSelect`) if needed for drill-down and dynamic re-query.
