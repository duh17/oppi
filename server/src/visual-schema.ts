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

const CHART_HEIGHT_MIN = 120;
const CHART_HEIGHT_MAX = 480;

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

const MAX_COLOR_SCALE_ENTRIES = 20;
const MAX_ANNOTATIONS = 10;
const MAX_ANNOTATION_TEXT_LENGTH = 80;
const ANNOTATION_ANCHORS = new Set(["top", "bottom", "leading", "trailing"]);
const HEX_COLOR_RE = /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/;

interface ToolResultDetailsSanitization {
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

/**
 * Fast byte-size estimator for sanitized chart row arrays.
 *
 * Avoids JSON.stringify on large datasets by computing a tight estimate
 * from already-validated values. Numbers/booleans have bounded JSON sizes,
 * strings are length + 2 (quotes). Row overhead is ~{} + commas.
 *
 * Accurate within ~5% of actual JSON size (always overestimates).
 */
/**
 * Fast byte-size estimator for sanitized chart specs.
 *
 * Rows dominate chart payload size. This estimates rows precisely
 * and adds a generous fixed overhead for marks/axes/hints/meta.
 */
/**
 * Estimate JSON byte size of a single sanitized row.
 * Called inline during sanitization to avoid a second traversal.
 */
function estimateRowBytesInline(row: Record<string, unknown>, _fieldCount: number): number {
  let bytes = 3; // { } + trailing comma
  let first = true;
  for (const key in row) {
    if (!first) bytes += 1; // comma
    first = false;
    bytes += key.length + 3; // "key":
    const v = row[key];
    if (typeof v === "number") {
      bytes += 20; // worst case number
    } else if (typeof v === "boolean") {
      bytes += (v as boolean) ? 4 : 5;
    } else if (typeof v === "string") {
      bytes += (v as string).length + 2;
    }
  }
  return bytes;
}

interface SanitizedRows {
  rows: Record<string, unknown>[];
  /** Estimated JSON byte size of the rows array, computed during sanitization. */
  estimatedBytes: number;
}

function sanitizeChartRows(value: unknown, warnings: string[]): SanitizedRows {
  if (!Array.isArray(value)) {
    return { rows: [], estimatedBytes: 2 };
  }

  const len = value.length;
  const cap = len > MAX_CHART_ROWS ? MAX_CHART_ROWS : len;

  if (len > MAX_CHART_ROWS) {
    warnings.push(`chart dataset rows capped at ${MAX_CHART_ROWS}`);
  }

  const rows: Record<string, unknown>[] = [];
  let estimatedBytes = 2; // opening [ and ]

  for (let i = 0; i < cap; i++) {
    const rawRow = value[i];
    if (typeof rawRow !== "object" || rawRow === null || Array.isArray(rawRow)) {
      warnings.push("dropped non-object chart row");
      continue;
    }

    const rowRecord = rawRow as Record<string, unknown>;

    // Fast path: check if the row is already clean (all fields are valid
    // types with clean keys). When true, reuse the input object directly
    // instead of allocating a new one. Byte estimation is fused into the
    // same loop to avoid a second traversal.
    let isClean = true;
    let fieldCount = 0;
    let rowBytes = 3; // { } + trailing comma

    for (const rawKey in rowRecord) {
      fieldCount++;
      if (fieldCount > MAX_CHART_ROW_FIELDS) {
        isClean = false;
        break;
      }

      const keyLen = rawKey.length;
      if (keyLen === 0 || keyLen > MAX_FIELD_NAME_LENGTH) {
        isClean = false;
        break;
      }

      // Check for whitespace that would need trimming
      const fc = rawKey.charCodeAt(0);
      const lc = rawKey.charCodeAt(keyLen - 1);
      if (fc === 0x20 || fc === 0x09 || fc === 0x0a || lc === 0x20 || lc === 0x09 || lc === 0x0a) {
        isClean = false;
        break;
      }

      // Byte estimate: "key": + comma (except first)
      if (fieldCount > 1) rowBytes += 1;
      rowBytes += keyLen + 3;

      const rawValue = rowRecord[rawKey];
      const t = typeof rawValue;
      if (t === "number") {
        if (!Number.isFinite(rawValue as number)) {
          isClean = false;
          break;
        }
        rowBytes += 20;
      } else if (t === "boolean") {
        rowBytes += (rawValue as boolean) ? 4 : 5;
      } else if (t === "string") {
        const sLen = (rawValue as string).length;
        if (sLen > MAX_ROW_STRING_LENGTH) {
          isClean = false;
          break;
        }
        rowBytes += sLen + 2;
      } else {
        isClean = false;
        break;
      }
    }

    if (isClean && fieldCount > 0) {
      rows.push(rowRecord);
      estimatedBytes += rowBytes;
      continue;
    }

    if (fieldCount === 0) {
      warnings.push("dropped empty chart row");
      continue;
    }

    // Slow path: build a sanitized copy
    const row: Record<string, unknown> = {};
    let acceptedFields = 0;

    for (const rawKey in rowRecord) {
      if (acceptedFields >= MAX_CHART_ROW_FIELDS) {
        warnings.push(`chart row fields capped at ${MAX_CHART_ROW_FIELDS}`);
        break;
      }

      const keyLen = rawKey.length;
      if (keyLen === 0 || keyLen > MAX_FIELD_NAME_LENGTH) continue;

      const firstChar = rawKey.charCodeAt(0);
      const lastChar = rawKey.charCodeAt(keyLen - 1);
      let key: string;
      if (
        firstChar === 0x20 ||
        firstChar === 0x09 ||
        firstChar === 0x0a ||
        lastChar === 0x20 ||
        lastChar === 0x09 ||
        lastChar === 0x0a
      ) {
        key = rawKey.trim();
        if (!key || key.length > MAX_FIELD_NAME_LENGTH) continue;
      } else {
        key = rawKey;
      }

      const rawValue = rowRecord[rawKey];
      const t = typeof rawValue;
      if (t === "number") {
        if (!Number.isFinite(rawValue as number)) continue;
        row[key] = rawValue;
      } else if (t === "boolean") {
        row[key] = rawValue;
      } else if (t === "string") {
        const s = rawValue as string;
        row[key] = s.length <= MAX_ROW_STRING_LENGTH ? s : s.slice(0, MAX_ROW_STRING_LENGTH);
      } else {
        continue;
      }

      acceptedFields += 1;
    }

    if (acceptedFields === 0) {
      warnings.push("dropped empty chart row");
      continue;
    }

    rows.push(row);
    // Use estimateRowBytesInline for slow-path rows (rare — only dirty/truncated rows)
    estimatedBytes += estimateRowBytesInline(row, acceptedFields);
  }

  return { rows, estimatedBytes };
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
    case "bar":
    case "point":
      isRenderable = has("x") && has("y");
      break;
    case "area":
      isRenderable = has("x") && (has("y") || (has("yStart") && has("yEnd")));
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

function sanitizeColorScale(
  value: unknown,
  warnings: string[],
): Record<string, string> | undefined {
  const record = asRecord(value);
  if (!record) return undefined;

  const scale: Record<string, string> = {};
  let count = 0;

  for (const [rawKey, rawValue] of Object.entries(record)) {
    if (count >= MAX_COLOR_SCALE_ENTRIES) {
      warnings.push(`colorScale capped at ${MAX_COLOR_SCALE_ENTRIES} entries`);
      break;
    }

    const key = rawKey.trim();
    if (!key || key.length > MAX_FIELD_NAME_LENGTH) continue;

    const color = boundedString(rawValue, 16);
    if (!color || !HEX_COLOR_RE.test(color)) {
      warnings.push(`dropped invalid colorScale color for "${key}"`);
      continue;
    }

    scale[key] = color;
    count++;
  }

  return Object.keys(scale).length > 0 ? scale : undefined;
}

function sanitizeAnnotations(
  value: unknown,
  warnings: string[],
): Record<string, unknown>[] | undefined {
  if (!Array.isArray(value)) return undefined;

  const annotations: Record<string, unknown>[] = [];
  const capped = value.slice(0, MAX_ANNOTATIONS);

  if (value.length > MAX_ANNOTATIONS) {
    warnings.push(`annotations capped at ${MAX_ANNOTATIONS}`);
  }

  for (const rawAnnotation of capped) {
    const record = asRecord(rawAnnotation);
    if (!record) {
      warnings.push("dropped non-object annotation");
      continue;
    }

    const x = finiteNumber(record.x);
    const y = finiteNumber(record.y);
    const text = boundedString(record.text, MAX_ANNOTATION_TEXT_LENGTH);

    if (x === undefined || y === undefined || !text) {
      warnings.push("dropped incomplete annotation (needs x, y, text)");
      continue;
    }

    const annotation: Record<string, unknown> = { x, y, text };

    const anchor = boundedString(record.anchor, 16)?.toLowerCase();
    if (anchor && ANNOTATION_ANCHORS.has(anchor)) {
      annotation.anchor = anchor;
    }

    annotations.push(annotation);
  }

  return annotations.length > 0 ? annotations : undefined;
}

interface SanitizedSpec {
  spec: Record<string, unknown>;
  rowBytes: number;
}

function sanitizeChartSpec(value: unknown, warnings: string[]): SanitizedSpec | null {
  const record = asRecord(value);
  if (!record) {
    warnings.push("dropped chart entry with non-object spec");
    return null;
  }

  const dataset = asRecord(record.dataset);
  const sanitizedRows = sanitizeChartRows(dataset?.rows ?? record.rows, warnings);
  if (sanitizedRows.rows.length === 0) {
    warnings.push("dropped chart entry with no valid rows");
    return null;
  }

  const marks = sanitizeChartMarks(record.marks, warnings);
  if (marks.length === 0) {
    warnings.push("dropped chart entry with no valid marks");
    return null;
  }

  const spec: Record<string, unknown> = {
    dataset: { rows: sanitizedRows.rows },
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
    enforceRenderHintSafety(renderHints, interaction, sanitizedRows.rows, marks, warnings);
    if (Object.keys(renderHints).length > 0) {
      spec.renderHints = renderHints;
    }
  }

  const colorScale = sanitizeColorScale(record.colorScale, warnings);
  if (colorScale) {
    spec.colorScale = colorScale;
  }

  const annotations = sanitizeAnnotations(record.annotations, warnings);
  if (annotations) {
    spec.annotations = annotations;
  }

  const height = finiteNumber(record.height);
  if (height !== undefined && height >= CHART_HEIGHT_MIN && height <= CHART_HEIGHT_MAX) {
    spec.height = height;
  }

  return { spec, rowBytes: sanitizedRows.estimatedBytes };
}

interface SanitizedUIEntry {
  entry: Record<string, unknown>;
  rowBytes: number;
}

function sanitizeChartUIEntry(
  value: unknown,
  index: number,
  warnings: string[],
): SanitizedUIEntry | null {
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

  const specResult = sanitizeChartSpec(record.spec, warnings);
  if (!specResult) {
    return null;
  }

  const id = boundedString(record.id, MAX_ID_LENGTH) ?? `chart-${index + 1}`;

  const sanitized: Record<string, unknown> = {
    id,
    kind: "chart",
    version: 1,
    spec: specResult.spec,
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

  return { entry: sanitized, rowBytes: specResult.rowBytes };
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
  // Build the non-ui copy without Object.entries/fromEntries allocation
  const next: Record<string, unknown> = {};
  for (const key in record) {
    if (key !== "ui") next[key] = record[key];
  }

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
    const result = sanitizeChartUIEntry(entry, index, warnings);
    if (!result) {
      continue;
    }

    // Use pre-computed row bytes + fixed overhead for fast size estimation.
    // Only fall back to exact JSON.stringify when near the budget limit.
    const fixedOverhead = 2048;
    const fallbackText = result.entry.fallbackText;
    const fallbackBytes = typeof fallbackText === "string" ? fallbackText.length + 2 : 0;
    let bytes = result.rowBytes + fixedOverhead + fallbackBytes;

    if (bytes > MAX_UI_BYTES * 0.8) {
      // Near the limit — use exact measurement for safety
      bytes = jsonBytes(result.entry);
    }

    if (bytes > MAX_UI_BYTES) {
      warnings.push("dropped oversized ui entry");
      continue;
    }

    if (budgetUsed + bytes > MAX_UI_BYTES) {
      warnings.push(`details.ui byte budget exceeded (${MAX_UI_BYTES} bytes)`);
      break;
    }

    budgetUsed += bytes;
    sanitizedUI.push(result.entry);
  }

  if (sanitizedUI.length > 0) {
    next.ui = sanitizedUI;
  } else {
    warnings.push("all details.ui entries were dropped after validation");
  }

  return { details: next, warnings };
}
