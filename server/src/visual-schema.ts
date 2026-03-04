/**
 * Validation + sanitization for dynamic visual payloads in tool result details.
 *
 * v1 focuses on `details.ui[]` entries with `{ kind: "chart", version: 1 }`.
 * Invalid/oversized UI payloads are dropped while preserving non-UI detail fields.
 */

const MAX_UI_ITEMS = 8;
const MAX_UI_BYTES = 256 * 1024;
const MAX_CHART_ROWS = 5_000;
const MAX_CHART_ROW_FIELDS = 64;
const MAX_CHART_MARKS = 64;
const MAX_FIELDS = 64;
const MAX_ID_LENGTH = 128;
const MAX_TEXT_LENGTH = 4_000;
const MAX_FIELD_NAME_LENGTH = 64;
const MAX_ROW_STRING_LENGTH = 256;
const MAX_DATA_URI_LENGTH = 512 * 1024;

export const CHART_HEIGHT_MIN = 120;
export const CHART_HEIGHT_MAX = 480;

const CHART_MARK_TYPES = new Set(["line", "area", "bar", "point", "rectangle", "rule", "sector"]);

const CHART_INTERPOLATIONS = new Set([
  "linear",
  "cardinal",
  "catmullrom",
  "monotone",
  "stepstart",
  "stepcenter",
  "stepend",
]);

const RENDER_HINT_X_AXIS_TYPES = new Set(["auto", "time", "numeric", "category"]);
const RENDER_HINT_X_AXIS_LABEL_FORMATS = new Set([
  "auto",
  "date-short",
  "date-day",
  "number-short",
]);
const RENDER_HINT_X_AXIS_STRATEGIES = new Set(["auto", "start-end-weekly", "stride"]);
const RENDER_HINT_Y_AXIS_ZERO_BASELINES = new Set(["auto", "always", "never"]);
const RENDER_HINT_LEGEND_MODES = new Set(["auto", "show", "hide", "inline"]);
const RENDER_HINT_GRID_VERTICAL_MODES = new Set(["none", "major"]);
const RENDER_HINT_GRID_HORIZONTAL_MODES = new Set(["major"]);
const CATEGORY_DENSITY_WARNING_THRESHOLD = 40;

export interface ToolResultDetailsSanitization {
  details: unknown;
  warnings: string[];
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, unknown>;
}

function finiteNumber(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  return undefined;
}

function boundedString(value: unknown, maxLength = MAX_TEXT_LENGTH): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }

  const trimmed = value.trim();
  if (!trimmed) {
    return undefined;
  }

  if (trimmed.length <= maxLength) {
    return trimmed;
  }

  return trimmed.slice(0, maxLength);
}

function jsonBytes(value: unknown): number {
  try {
    const serialized = JSON.stringify(value);
    if (typeof serialized !== "string") {
      return Number.POSITIVE_INFINITY;
    }
    return Buffer.byteLength(serialized, "utf8");
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

function sanitizeRowValue(value: unknown): string | number | boolean | undefined {
  if (typeof value === "number") {
    return Number.isFinite(value) ? value : undefined;
  }

  if (typeof value === "boolean") {
    return value;
  }

  if (typeof value === "string") {
    if (value.length <= MAX_ROW_STRING_LENGTH) {
      return value;
    }
    return value.slice(0, MAX_ROW_STRING_LENGTH);
  }

  return undefined;
}

function sanitizeChartRows(value: unknown, warnings: string[]): Record<string, unknown>[] {
  if (!Array.isArray(value)) {
    return [];
  }

  const rows: Record<string, unknown>[] = [];
  const cappedRows = value.slice(0, MAX_CHART_ROWS);

  if (value.length > MAX_CHART_ROWS) {
    warnings.push(`chart dataset rows capped at ${MAX_CHART_ROWS}`);
  }

  for (const rawRow of cappedRows) {
    const rowRecord = asRecord(rawRow);
    if (!rowRecord) {
      warnings.push("dropped non-object chart row");
      continue;
    }

    const row: Record<string, unknown> = {};
    let acceptedFields = 0;

    for (const [rawKey, rawValue] of Object.entries(rowRecord)) {
      if (acceptedFields >= MAX_CHART_ROW_FIELDS) {
        warnings.push(`chart row fields capped at ${MAX_CHART_ROW_FIELDS}`);
        break;
      }

      const key = rawKey.trim();
      if (!key || key.length > MAX_FIELD_NAME_LENGTH) {
        continue;
      }

      const sanitizedValue = sanitizeRowValue(rawValue);
      if (sanitizedValue === undefined) {
        continue;
      }

      row[key] = sanitizedValue;
      acceptedFields += 1;
    }

    if (Object.keys(row).length === 0) {
      warnings.push("dropped empty chart row");
      continue;
    }

    rows.push(row);
  }

  return rows;
}

function setOptionalString(
  target: Record<string, unknown>,
  key: string,
  value: unknown,
  maxLength = MAX_TEXT_LENGTH,
): void {
  const parsed = boundedString(value, maxLength);
  if (parsed !== undefined) {
    target[key] = parsed;
  }
}

function setOptionalFiniteNumber(
  target: Record<string, unknown>,
  key: string,
  value: unknown,
): void {
  const parsed = finiteNumber(value);
  if (parsed !== undefined) {
    target[key] = parsed;
  }
}

function sanitizeChartFields(
  value: unknown,
  warnings: string[],
): Record<string, unknown> | undefined {
  const record = asRecord(value);
  if (!record) {
    return undefined;
  }

  const sanitized: Record<string, unknown> = {};
  const entries = Object.entries(record).slice(0, MAX_FIELDS);
  if (Object.keys(record).length > MAX_FIELDS) {
    warnings.push(`chart fields capped at ${MAX_FIELDS}`);
  }

  for (const [rawName, rawField] of entries) {
    const name = rawName.trim();
    if (!name || name.length > MAX_FIELD_NAME_LENGTH) {
      continue;
    }

    const fieldRecord = asRecord(rawField);
    if (!fieldRecord) {
      continue;
    }

    const field: Record<string, unknown> = {};
    setOptionalString(field, "type", fieldRecord.type, 32);
    setOptionalString(field, "label", fieldRecord.label, 120);
    setOptionalString(field, "unit", fieldRecord.unit, 32);

    if (Object.keys(field).length > 0) {
      sanitized[name] = field;
    }
  }

  return Object.keys(sanitized).length > 0 ? sanitized : undefined;
}

function sanitizeChartMark(value: unknown, warnings: string[]): Record<string, unknown> | null {
  const record = asRecord(value);
  if (!record) {
    warnings.push("dropped non-object chart mark");
    return null;
  }

  const type = boundedString(record.type, 32)?.toLowerCase();
  if (!type || !CHART_MARK_TYPES.has(type)) {
    warnings.push("dropped unsupported chart mark type");
    return null;
  }

  const mark: Record<string, unknown> = { type };
  setOptionalString(mark, "id", record.id, MAX_ID_LENGTH);

  setOptionalString(mark, "x", record.x, MAX_FIELD_NAME_LENGTH);
  setOptionalString(mark, "y", record.y, MAX_FIELD_NAME_LENGTH);
  setOptionalString(mark, "xStart", record.xStart, MAX_FIELD_NAME_LENGTH);
  setOptionalString(mark, "xEnd", record.xEnd, MAX_FIELD_NAME_LENGTH);
  setOptionalString(mark, "yStart", record.yStart, MAX_FIELD_NAME_LENGTH);
  setOptionalString(mark, "yEnd", record.yEnd, MAX_FIELD_NAME_LENGTH);
  setOptionalString(mark, "angle", record.angle, MAX_FIELD_NAME_LENGTH);

  setOptionalFiniteNumber(mark, "xValue", record.xValue);
  setOptionalFiniteNumber(mark, "yValue", record.yValue);

  setOptionalString(mark, "series", record.series, MAX_FIELD_NAME_LENGTH);
  setOptionalString(mark, "label", record.label, 120);

  const interpolation = boundedString(record.interpolation, 32)?.toLowerCase();
  if (interpolation && CHART_INTERPOLATIONS.has(interpolation)) {
    mark.interpolation = interpolation;
  }

  const has = (key: string): boolean => typeof mark[key] !== "undefined";

  let isRenderable = true;
  switch (type) {
    case "line":
    case "area":
    case "bar":
    case "point":
      isRenderable = has("x") && has("y");
      break;
    case "rectangle":
      isRenderable = has("xStart") && has("xEnd") && has("yStart") && has("yEnd");
      break;
    case "rule":
      isRenderable = has("xValue") || has("yValue");
      break;
    case "sector":
      isRenderable = has("angle");
      break;
  }

  if (!isRenderable) {
    warnings.push(`dropped incomplete chart mark (${type})`);
    return null;
  }

  return mark;
}

function sanitizeChartMarks(value: unknown, warnings: string[]): Record<string, unknown>[] {
  if (!Array.isArray(value)) {
    return [];
  }

  const marks: Record<string, unknown>[] = [];
  const capped = value.slice(0, MAX_CHART_MARKS);

  if (value.length > MAX_CHART_MARKS) {
    warnings.push(`chart marks capped at ${MAX_CHART_MARKS}`);
  }

  for (const rawMark of capped) {
    const mark = sanitizeChartMark(rawMark, warnings);
    if (mark) {
      marks.push(mark);
    }
  }

  return marks;
}

function sanitizeChartAxis(value: unknown): Record<string, unknown> | undefined {
  const record = asRecord(value);
  if (!record) {
    return undefined;
  }

  const axis: Record<string, unknown> = {};
  setOptionalString(axis, "label", record.label, 120);
  if (typeof record.invert === "boolean") {
    axis.invert = record.invert;
  }

  return Object.keys(axis).length > 0 ? axis : undefined;
}

function sanitizeChartInteraction(value: unknown): Record<string, unknown> | undefined {
  const record = asRecord(value);
  if (!record) {
    return undefined;
  }

  const interaction: Record<string, unknown> = {};
  if (typeof record.xSelection === "boolean") {
    interaction.xSelection = record.xSelection;
  }
  if (typeof record.xRangeSelection === "boolean") {
    interaction.xRangeSelection = record.xRangeSelection;
  }
  if (typeof record.scrollableX === "boolean") {
    interaction.scrollableX = record.scrollableX;
  }

  const visibleDomainLength = finiteNumber(record.xVisibleDomainLength);
  if (visibleDomainLength !== undefined && visibleDomainLength > 0) {
    interaction.xVisibleDomainLength = visibleDomainLength;
  }

  return Object.keys(interaction).length > 0 ? interaction : undefined;
}

function parseRenderHintEnum(
  value: unknown,
  allowed: Set<string>,
  warningKey: string,
  warnings: string[],
): string | undefined {
  const token = boundedString(value, 64)?.toLowerCase();
  if (!token) {
    return undefined;
  }

  if (!allowed.has(token)) {
    warnings.push(`dropped invalid ${warningKey}`);
    return undefined;
  }

  return token;
}

function clampRenderHintInteger(
  value: unknown,
  min: number,
  max: number,
  warningKey: string,
  warnings: string[],
): number | undefined {
  const parsed = finiteNumber(value);
  if (parsed === undefined) {
    return undefined;
  }

  const rounded = Math.round(parsed);
  const clamped = Math.min(max, Math.max(min, rounded));
  if (rounded !== clamped) {
    warnings.push(`${warningKey} clamped to ${clamped} (${min}...${max})`);
  }

  return clamped;
}

function sanitizeChartRenderHints(
  value: unknown,
  warnings: string[],
): Record<string, unknown> | undefined {
  const record = asRecord(value);
  if (!record) {
    return undefined;
  }

  const renderHints: Record<string, unknown> = {};

  const xAxisRecord = asRecord(record.xAxis);
  if (xAxisRecord) {
    const xAxis: Record<string, unknown> = {};

    const type = parseRenderHintEnum(
      xAxisRecord.type,
      RENDER_HINT_X_AXIS_TYPES,
      "renderHints.xAxis.type",
      warnings,
    );
    if (type) {
      xAxis.type = type;
    }

    const maxVisibleTicks = clampRenderHintInteger(
      xAxisRecord.maxVisibleTicks,
      2,
      8,
      "renderHints.xAxis.maxVisibleTicks",
      warnings,
    );
    if (maxVisibleTicks !== undefined) {
      xAxis.maxVisibleTicks = maxVisibleTicks;
    }

    const labelFormat = parseRenderHintEnum(
      xAxisRecord.labelFormat,
      RENDER_HINT_X_AXIS_LABEL_FORMATS,
      "renderHints.xAxis.labelFormat",
      warnings,
    );
    if (labelFormat) {
      xAxis.labelFormat = labelFormat;
    }

    const strategy = parseRenderHintEnum(
      xAxisRecord.strategy,
      RENDER_HINT_X_AXIS_STRATEGIES,
      "renderHints.xAxis.strategy",
      warnings,
    );
    if (strategy) {
      xAxis.strategy = strategy;
    }

    if (Object.keys(xAxis).length > 0) {
      renderHints.xAxis = xAxis;
    }
  }

  const yAxisRecord = asRecord(record.yAxis);
  if (yAxisRecord) {
    const yAxis: Record<string, unknown> = {};

    const maxTicks = clampRenderHintInteger(
      yAxisRecord.maxTicks,
      2,
      8,
      "renderHints.yAxis.maxTicks",
      warnings,
    );
    if (maxTicks !== undefined) {
      yAxis.maxTicks = maxTicks;
    }

    if (typeof yAxisRecord.nice === "boolean") {
      yAxis.nice = yAxisRecord.nice;
    }

    const zeroBaseline = parseRenderHintEnum(
      yAxisRecord.zeroBaseline,
      RENDER_HINT_Y_AXIS_ZERO_BASELINES,
      "renderHints.yAxis.zeroBaseline",
      warnings,
    );
    if (zeroBaseline) {
      yAxis.zeroBaseline = zeroBaseline;
    }

    if (Object.keys(yAxis).length > 0) {
      renderHints.yAxis = yAxis;
    }
  }

  const legendRecord = asRecord(record.legend);
  if (legendRecord) {
    const legend: Record<string, unknown> = {};

    const mode = parseRenderHintEnum(
      legendRecord.mode,
      RENDER_HINT_LEGEND_MODES,
      "renderHints.legend.mode",
      warnings,
    );
    if (mode) {
      legend.mode = mode;
    }

    const maxItems = clampRenderHintInteger(
      legendRecord.maxItems,
      1,
      5,
      "renderHints.legend.maxItems",
      warnings,
    );
    if (maxItems !== undefined) {
      legend.maxItems = maxItems;
    }

    if (Object.keys(legend).length > 0) {
      renderHints.legend = legend;
    }
  }

  const gridRecord = asRecord(record.grid);
  if (gridRecord) {
    const grid: Record<string, unknown> = {};

    const vertical = parseRenderHintEnum(
      gridRecord.vertical,
      RENDER_HINT_GRID_VERTICAL_MODES,
      "renderHints.grid.vertical",
      warnings,
    );
    if (vertical) {
      grid.vertical = vertical;
    }

    const horizontal = parseRenderHintEnum(
      gridRecord.horizontal,
      RENDER_HINT_GRID_HORIZONTAL_MODES,
      "renderHints.grid.horizontal",
      warnings,
    );
    if (horizontal) {
      grid.horizontal = horizontal;
    }

    if (Object.keys(grid).length > 0) {
      renderHints.grid = grid;
    }
  }

  return Object.keys(renderHints).length > 0 ? renderHints : undefined;
}

function primaryXFieldName(marks: Record<string, unknown>[]): string | undefined {
  for (const mark of marks) {
    const x = boundedString(mark.x, MAX_FIELD_NAME_LENGTH);
    if (x) {
      return x;
    }
  }

  return undefined;
}

function domainCardinality(rows: Record<string, unknown>[], field: string): number {
  const seen = new Set<string>();

  for (const row of rows) {
    const value = row[field];
    if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
      seen.add(String(value));
    }
  }

  return seen.size;
}

function enforceRenderHintSafety(
  renderHints: Record<string, unknown>,
  interaction: Record<string, unknown> | undefined,
  rows: Record<string, unknown>[],
  marks: Record<string, unknown>[],
  warnings: string[],
): void {
  const xAxis = asRecord(renderHints.xAxis);
  if (!xAxis || xAxis.type !== "category") {
    return;
  }

  if (interaction?.scrollableX === true) {
    return;
  }

  const xField = primaryXFieldName(marks);
  if (!xField) {
    return;
  }

  const uniqueCount = domainCardinality(rows, xField);
  if (uniqueCount <= CATEGORY_DENSITY_WARNING_THRESHOLD) {
    return;
  }

  delete xAxis.type;
  warnings.push(
    `dropped renderHints.xAxis.type category for dense domain (${uniqueCount}) without scrollableX`,
  );

  if (Object.keys(xAxis).length === 0) {
    delete renderHints.xAxis;
  }
}

function sanitizeChartSpec(value: unknown, warnings: string[]): Record<string, unknown> | null {
  const record = asRecord(value);
  if (!record) {
    warnings.push("dropped chart entry with non-object spec");
    return null;
  }

  const dataset = asRecord(record.dataset);
  const rows = sanitizeChartRows(dataset?.rows ?? record.rows, warnings);
  if (rows.length === 0) {
    warnings.push("dropped chart entry with no valid rows");
    return null;
  }

  const marks = sanitizeChartMarks(record.marks, warnings);
  if (marks.length === 0) {
    warnings.push("dropped chart entry with no valid marks");
    return null;
  }

  const spec: Record<string, unknown> = {
    dataset: { rows },
    marks,
  };

  setOptionalString(spec, "title", record.title, 120);

  const fields = sanitizeChartFields(record.fields, warnings);
  if (fields) {
    spec.fields = fields;
  }

  const axesRecord = asRecord(record.axes);
  const xAxis = sanitizeChartAxis(axesRecord?.x);
  const yAxis = sanitizeChartAxis(axesRecord?.y);
  if (xAxis || yAxis) {
    spec.axes = {
      ...(xAxis ? { x: xAxis } : {}),
      ...(yAxis ? { y: yAxis } : {}),
    };
  }

  const interaction = sanitizeChartInteraction(record.interaction);
  if (interaction) {
    spec.interaction = interaction;
  }

  const renderHints = sanitizeChartRenderHints(record.renderHints, warnings);
  if (renderHints) {
    enforceRenderHintSafety(renderHints, interaction, rows, marks, warnings);
    if (Object.keys(renderHints).length > 0) {
      spec.renderHints = renderHints;
    }
  }

  const height = finiteNumber(record.height);
  if (height !== undefined && height >= CHART_HEIGHT_MIN && height <= CHART_HEIGHT_MAX) {
    spec.height = height;
  }

  return spec;
}

function sanitizeChartUIEntry(
  value: unknown,
  index: number,
  warnings: string[],
): Record<string, unknown> | null {
  const record = asRecord(value);
  if (!record) {
    warnings.push("dropped non-object ui entry");
    return null;
  }

  const kind = boundedString(record.kind, 24)?.toLowerCase();
  const version = finiteNumber(record.version);
  if (kind !== "chart" || version !== 1) {
    warnings.push("dropped unsupported ui entry (kind/version)");
    return null;
  }

  const spec = sanitizeChartSpec(record.spec, warnings);
  if (!spec) {
    return null;
  }

  const id = boundedString(record.id, MAX_ID_LENGTH) ?? `chart-${index + 1}`;

  const sanitized: Record<string, unknown> = {
    id,
    kind: "chart",
    version: 1,
    spec,
  };

  setOptionalString(sanitized, "title", record.title, 120);
  setOptionalString(sanitized, "fallbackText", record.fallbackText, MAX_TEXT_LENGTH);

  const fallbackImageDataUri = boundedString(record.fallbackImageDataUri, MAX_DATA_URI_LENGTH);
  if (
    fallbackImageDataUri &&
    fallbackImageDataUri.startsWith("data:image/") &&
    fallbackImageDataUri.length <= MAX_DATA_URI_LENGTH
  ) {
    sanitized.fallbackImageDataUri = fallbackImageDataUri;
  }

  return sanitized;
}

/**
 * Sanitize tool result details, validating/dropping `details.ui[]` chart payloads.
 * Non-UI fields are preserved as-is.
 */
export function sanitizeToolResultDetails(details: unknown): ToolResultDetailsSanitization {
  const record = asRecord(details);
  if (!record || !("ui" in record)) {
    return { details, warnings: [] };
  }

  const warnings: string[] = [];
  const next: Record<string, unknown> = Object.fromEntries(
    Object.entries(record).filter(([key]) => key !== "ui"),
  );

  const rawUI = record.ui;
  if (!Array.isArray(rawUI)) {
    warnings.push("dropped non-array details.ui payload");
    return { details: next, warnings };
  }

  let budgetUsed = 0;
  const sanitizedUI: Record<string, unknown>[] = [];
  const cappedUI = rawUI.slice(0, MAX_UI_ITEMS);

  if (rawUI.length > MAX_UI_ITEMS) {
    warnings.push(`details.ui capped at ${MAX_UI_ITEMS} entries`);
  }

  for (const [index, entry] of cappedUI.entries()) {
    const sanitizedEntry = sanitizeChartUIEntry(entry, index, warnings);
    if (!sanitizedEntry) {
      continue;
    }

    const bytes = jsonBytes(sanitizedEntry);
    if (bytes > MAX_UI_BYTES) {
      warnings.push("dropped oversized ui entry");
      continue;
    }

    if (budgetUsed + bytes > MAX_UI_BYTES) {
      warnings.push(`details.ui byte budget exceeded (${MAX_UI_BYTES} bytes)`);
      break;
    }

    budgetUsed += bytes;
    sanitizedUI.push(sanitizedEntry);
  }

  if (sanitizedUI.length > 0) {
    next.ui = sanitizedUI;
  } else {
    warnings.push("all details.ui entries were dropped after validation");
  }

  return { details: next, warnings };
}
