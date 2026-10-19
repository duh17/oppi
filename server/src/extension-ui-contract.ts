import type {
  AskQuestion,
  ExtensionUINativeSurface,
  ExtensionUITextSpan,
  ExtensionUINotifyType,
  ExtensionUIWidgetPlacement,
  ServerMessage,
} from "./types.js";
import { terminalLineToTextSpans, terminalLineVisibleText } from "./ansi.js";

export const EXTENSION_UI_FIRE_AND_FORGET_METHODS = new Set([
  "notify",
  "setStatus",
  "setWidget",
  "setTitle",
  "setWorkingIndicator",
  "setWorkingMessage",
  "setWorkingVisible",
  "setHiddenThinkingLabel",
  "setToolsExpanded",
  "set_editor_text",
]);
/**
 * Fire-and-forget methods that set one session's surface or editor state. Their clients are
 * that session's chat, so they travel on its session stream, which replays the persistent ones
 * on subscribe. The global app event stream drops them: one busy session's per-second working
 * text otherwise reaches every client and every screen.
 */
const EXTENSION_UI_SESSION_STREAM_ONLY_METHODS = new Set(
  [...EXTENSION_UI_FIRE_AND_FORGET_METHODS].filter((method) => method !== "notify"),
);
export const EXTENSION_UI_NATIVE_SURFACE_MAX_BYTES = 64 * 1024;
export const EXTENSION_UI_NATIVE_SURFACE_MAX_BLOCKS = 80;
export const EXTENSION_UI_NATIVE_SURFACE_MAX_DEPTH = 6;
export const EXTENSION_UI_NATIVE_SURFACE_MAX_TEXT_BYTES = 32 * 1024;
export const EXTENSION_UI_NATIVE_SURFACE_MAX_SPANS = 320;
export const EXTENSION_UI_NATIVE_SURFACE_MAX_TERMINAL_LINES = 160;
export const EXTENSION_UI_NATIVE_SURFACE_MAX_ACTIVITY_ROWS = 160;
export const EXTENSION_UI_NATIVE_TABLE_MAX_COLUMNS = 32;
export const EXTENSION_UI_NATIVE_TABLE_MAX_ROWS = 200;
export const EXTENSION_UI_NATIVE_TABLE_MAX_CELL_CHARS = 200;
export const EXTENSION_UI_NATIVE_CHART_MAX_LABELS = 48;
export const EXTENSION_UI_NATIVE_CHART_MAX_SERIES = 8;
export const EXTENSION_UI_WORKING_INDICATOR_MAX_FRAMES = 24;
export const EXTENSION_UI_WORKING_INDICATOR_MAX_FRAME_CHARS = 16;
export const EXTENSION_UI_WORKING_INDICATOR_MIN_INTERVAL_MS = 80;
export const EXTENSION_UI_WORKING_INDICATOR_MAX_INTERVAL_MS = 60_000;
export const EXTENSION_UI_WORKING_MESSAGE_MAX_CHARS = 160;
export const EXTENSION_UI_STATUS_TEXT_MAX_CHARS = 160;
// Shared back-pressure for extension-driven animation, progress, and widget redraw snapshots.
// Extensions should send animation frames once and let clients animate locally.
export const EXTENSION_UI_HIGH_FREQUENCY_UPDATE_THROTTLE_MS = 250;
export const EXTENSION_NATIVE_UI_TEXT_FALLBACK_CAPABILITY = "extension-native-ui:v1:text-fallback";
export const EXTENSION_NATIVE_UI_PROMPT_NATIVE_CAPABILITY = "extension-native-ui:v1:prompt-native";
export const EXTENSION_NATIVE_UI_SURFACE_NATIVE_CAPABILITY =
  "extension-native-ui:v1:surface-native";
export const EXTENSION_NATIVE_UI_OSC8_LINKS_CAPABILITY = "extension-native-ui:v1:osc8-links";
export const EXTENSION_NATIVE_UI_SERVER_CAPABILITIES = [
  EXTENSION_NATIVE_UI_TEXT_FALLBACK_CAPABILITY,
  EXTENSION_NATIVE_UI_PROMPT_NATIVE_CAPABILITY,
  EXTENSION_NATIVE_UI_SURFACE_NATIVE_CAPABILITY,
  EXTENSION_NATIVE_UI_OSC8_LINKS_CAPABILITY,
] as const;
export const EXTENSION_NATIVE_UI_RENDER_NATIVE_CAPABILITIES = [
  EXTENSION_NATIVE_UI_TEXT_FALLBACK_CAPABILITY,
  EXTENSION_NATIVE_UI_SURFACE_NATIVE_CAPABILITY,
] as const;

export interface ExtensionUINativeRenderContext {
  target: "oppi-native-v1";
  capabilities: string[];
  locale?: string;
}

export interface ExtensionUINativeRenderableComponent {
  render(width: number): string[];
  renderNative?(context: ExtensionUINativeRenderContext): ExtensionUINativeSurface | undefined;
  handleInput?(data: string): void;
  invalidate(): void;
  dispose?(): void;
}

export function createExtensionUINativeRenderContext(
  locale?: string,
): ExtensionUINativeRenderContext {
  return {
    target: "oppi-native-v1",
    capabilities: [...EXTENSION_NATIVE_UI_RENDER_NATIVE_CAPABILITIES],
    locale,
  };
}

/** Only the env-gated E2E harness raises the byte cap; every other limit is fixed. */
export interface ExtensionUINativeSurfaceLimitOptions {
  maxBytes?: number;
}

export interface ExtensionUIProtocolRequest {
  id: string;
  method: string;
  title?: string;
  options?: string[];
  message?: string;
  placeholder?: string;
  prefill?: string;
  notifyType?: unknown;
  statusKey?: string;
  statusText?: string;
  widgetKey?: string;
  widgetLines?: string[];
  widgetPlacement?: unknown;
  extensionScopeId?: string;
  extensionDisplayName?: string;
  workingIndicator?: unknown;
  workingVisible?: unknown;
  hiddenThinkingLabel?: string;
  toolsExpanded?: unknown;
  text?: string;
  timeout?: number;
  timeoutAt?: number;
  questions?: AskQuestion[];
  allowCustom?: boolean;
  nativeSurface?: unknown;
}

export interface ExtensionUIWorkingIndicator {
  frames?: string[];
  intervalMs?: number;
}

export interface ExtensionUIResponsePayload {
  id: string;
  value?: string;
  confirmed?: boolean;
  cancelled?: boolean;
}

export interface ExtensionUIAskResult {
  answers: Record<string, string | string[]>;
  allIgnored: boolean;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isTableCell(value: unknown): value is string | number | null {
  return (
    value === null ||
    typeof value === "string" ||
    (typeof value === "number" && Number.isFinite(value))
  );
}

function clipTableCellText(value: string): { value: string; truncated: boolean } {
  if (value.length <= EXTENSION_UI_NATIVE_TABLE_MAX_CELL_CHARS) {
    return { value, truncated: false };
  }
  return {
    value: value.slice(0, EXTENSION_UI_NATIVE_TABLE_MAX_CELL_CHARS),
    truncated: true,
  };
}

function clipTableBlock(block: Record<string, unknown>): Record<string, unknown> | undefined {
  if (
    !Array.isArray(block.columns) ||
    !block.columns.every((column) => typeof column === "string")
  ) {
    return undefined;
  }
  if (
    !Array.isArray(block.rows) ||
    !block.rows.every((row) => Array.isArray(row) && row.every(isTableCell))
  ) {
    return undefined;
  }
  let truncated = block.truncated === true;
  const columns = block.columns.map((column) => {
    const clipped = clipTableCellText(column);
    if (clipped.truncated) truncated = true;
    return clipped.value;
  });
  const columnCount = Math.min(columns.length, EXTENSION_UI_NATIVE_TABLE_MAX_COLUMNS);
  if (columns.length > EXTENSION_UI_NATIVE_TABLE_MAX_COLUMNS) truncated = true;
  const clippedColumns = columns.slice(0, columnCount);
  const maxRows = Math.min(block.rows.length, EXTENSION_UI_NATIVE_TABLE_MAX_ROWS);
  if (block.rows.length > EXTENSION_UI_NATIVE_TABLE_MAX_ROWS) truncated = true;
  const rows: Array<Array<string | number | null>> = [];
  let textChars = clippedColumns.reduce((sum, column) => sum + column.length, 0);
  const textBudget = Math.floor(EXTENSION_UI_NATIVE_SURFACE_MAX_TEXT_BYTES * 0.75);
  for (let rowIndex = 0; rowIndex < maxRows; rowIndex += 1) {
    const row = block.rows[rowIndex] as unknown[];
    if (row.length > columnCount) truncated = true;
    const cells: Array<string | number | null> = [];
    for (let index = 0; index < columnCount; index += 1) {
      const cell = row[index] ?? null;
      if (typeof cell === "string") {
        const clipped = clipTableCellText(cell);
        if (clipped.truncated) truncated = true;
        textChars += clipped.value.length;
        cells.push(clipped.value);
      } else {
        cells.push(cell as string | number | null);
      }
    }
    if (textChars > textBudget && rows.length > 0) {
      truncated = true;
      break;
    }
    rows.push(cells);
  }
  const clipped: Record<string, unknown> = {
    ...block,
    type: "table",
    columns: clippedColumns,
    rows,
  };
  if (truncated) clipped.truncated = true;
  else delete clipped.truncated;
  return clipped;
}

function clipChartBlock(block: Record<string, unknown>): Record<string, unknown> | undefined {
  if (block.kind !== "bar" && block.kind !== "line" && block.kind !== "pie") return undefined;
  if (!Array.isArray(block.labels) || !block.labels.every((label) => typeof label === "string")) {
    return undefined;
  }
  if (!Array.isArray(block.series)) return undefined;
  const series: Array<{ name?: string; values: number[] }> = [];
  for (const entry of block.series) {
    if (!isRecord(entry) || !Array.isArray(entry.values)) return undefined;
    if (!entry.values.every((value) => typeof value === "number" && Number.isFinite(value))) {
      return undefined;
    }
    if (entry.name !== undefined && typeof entry.name !== "string") return undefined;
    series.push({
      ...(typeof entry.name === "string" ? { name: entry.name } : {}),
      values: entry.values,
    });
  }
  let truncated = block.truncated === true;
  const labels = block.labels.map((label) => {
    const clipped = clipTableCellText(label);
    if (clipped.truncated) truncated = true;
    return clipped.value;
  });
  if (labels.length > EXTENSION_UI_NATIVE_CHART_MAX_LABELS) truncated = true;
  if (series.length > EXTENSION_UI_NATIVE_CHART_MAX_SERIES) truncated = true;
  const clippedLabels = labels.slice(0, EXTENSION_UI_NATIVE_CHART_MAX_LABELS);
  const clippedSeries = series.slice(0, EXTENSION_UI_NATIVE_CHART_MAX_SERIES).map((entry) => {
    if (entry.values.length > clippedLabels.length) truncated = true;
    const values = entry.values.slice(0, clippedLabels.length);
    const name = typeof entry.name === "string" ? clipTableCellText(entry.name) : undefined;
    if (name?.truncated) truncated = true;
    return {
      ...(name ? { name: name.value } : {}),
      values,
    };
  });
  if (clippedLabels.length === 0 || clippedSeries.length === 0) return undefined;
  const clipped: Record<string, unknown> = {
    ...block,
    type: "chart",
    kind: block.kind,
    labels: clippedLabels,
    series: clippedSeries,
  };
  if (typeof block.title === "string") {
    const title = clipTableCellText(block.title);
    if (title.truncated) truncated = true;
    clipped.title = title.value;
  } else if (block.title !== undefined) {
    return undefined;
  }
  if (truncated) clipped.truncated = true;
  else delete clipped.truncated;
  return clipped;
}

function clipActivityRows(rows: unknown[]): unknown[] {
  return rows.map((row) => {
    if (!isRecord(row)) return row;
    const next = { ...row };
    if (Array.isArray(row.blocks)) next.blocks = clipNativeBlocks(row.blocks);
    if (Array.isArray(row.children)) next.children = clipActivityRows(row.children);
    return next;
  });
}

function clipNativeBlocks(value: unknown): unknown[] {
  if (!Array.isArray(value)) return [];
  const blocks: unknown[] = [];
  for (const block of value) {
    if (!isRecord(block)) continue;
    if (block.type === "table") {
      const clipped = clipTableBlock(block);
      if (clipped) blocks.push(clipped);
      continue;
    }
    if (block.type === "chart") {
      const clipped = clipChartBlock(block);
      if (clipped) blocks.push(clipped);
      continue;
    }
    if (block.type === "section" && Array.isArray(block.blocks)) {
      blocks.push({ ...block, blocks: clipNativeBlocks(block.blocks) });
      continue;
    }
    if (block.type === "activityList" && Array.isArray(block.rows)) {
      blocks.push({ ...block, rows: clipActivityRows(block.rows) });
      continue;
    }
    blocks.push(block);
  }
  return blocks;
}

function clipNativeSurface(value: Record<string, unknown>): Record<string, unknown> {
  return { ...value, blocks: clipNativeBlocks(value.blocks) };
}

interface NativeSurfaceLimits {
  maxBytes: number;
  maxBlocks: number;
  maxDepth: number;
  maxTextBytes: number;
  maxSpans: number;
  maxTerminalLines: number;
  maxActivityRows: number;
}

interface NativeSurfaceLimitState {
  blocks: number;
  textBytes: number;
  spans: number;
  terminalLines: number;
  activityRows: number;
}

function nativeSurfaceLimits(options: ExtensionUINativeSurfaceLimitOptions): NativeSurfaceLimits {
  return {
    maxBytes: options.maxBytes ?? EXTENSION_UI_NATIVE_SURFACE_MAX_BYTES,
    maxBlocks: EXTENSION_UI_NATIVE_SURFACE_MAX_BLOCKS,
    maxDepth: EXTENSION_UI_NATIVE_SURFACE_MAX_DEPTH,
    maxTextBytes: EXTENSION_UI_NATIVE_SURFACE_MAX_TEXT_BYTES,
    maxSpans: EXTENSION_UI_NATIVE_SURFACE_MAX_SPANS,
    maxTerminalLines: EXTENSION_UI_NATIVE_SURFACE_MAX_TERMINAL_LINES,
    maxActivityRows: EXTENSION_UI_NATIVE_SURFACE_MAX_ACTIVITY_ROWS,
  };
}

function addNativeSurfaceText(
  value: unknown,
  state: NativeSurfaceLimitState,
  limits: NativeSurfaceLimits,
  required = false,
): boolean {
  if (value === undefined || value === null) return !required;
  if (typeof value !== "string") return false;
  state.textBytes += Buffer.byteLength(value, "utf8");
  return state.textBytes <= limits.maxTextBytes;
}

function validateNativeAccessibility(
  value: unknown,
  state: NativeSurfaceLimitState,
  limits: NativeSurfaceLimits,
): boolean {
  if (value === undefined || value === null) return true;
  if (!isRecord(value)) return false;
  return (
    addNativeSurfaceText(value.label, state, limits) &&
    addNativeSurfaceText(value.value, state, limits) &&
    addNativeSurfaceText(value.hint, state, limits)
  );
}

function validateNativeBlockBase(
  block: Record<string, unknown>,
  state: NativeSurfaceLimitState,
  limits: NativeSurfaceLimits,
): boolean {
  return (
    addNativeSurfaceText(block.id, state, limits) &&
    validateNativeAccessibility(block.accessibility, state, limits)
  );
}

function validateNativeSpan(
  value: unknown,
  state: NativeSurfaceLimitState,
  limits: NativeSurfaceLimits,
): boolean {
  if (!isRecord(value)) return false;
  state.spans += 1;
  if (state.spans > limits.maxSpans) return false;
  if (!addNativeSurfaceText(value.text, state, limits, true)) return false;
  if (!addNativeSurfaceText(value.role, state, limits)) return false;
  if (!addNativeSurfaceText(value.link, state, limits)) return false;
  if (value.traits === undefined || value.traits === null) return true;
  if (!Array.isArray(value.traits)) return false;
  return value.traits.every((trait) => addNativeSurfaceText(trait, state, limits, true));
}

function validateNativeSpans(
  value: unknown,
  state: NativeSurfaceLimitState,
  limits: NativeSurfaceLimits,
): boolean {
  return Array.isArray(value) && value.every((span) => validateNativeSpan(span, state, limits));
}

function validateNativeActivityRows(
  value: unknown,
  depth: number,
  state: NativeSurfaceLimitState,
  limits: NativeSurfaceLimits,
): boolean {
  if (!Array.isArray(value)) return false;
  if (depth > limits.maxDepth) return false;

  for (const row of value) {
    if (!isRecord(row)) return false;
    state.activityRows += 1;
    if (state.activityRows > limits.maxActivityRows) return false;

    if (
      !addNativeSurfaceText(row.id, state, limits, true) ||
      !addNativeSurfaceText(row.title, state, limits, true) ||
      !addNativeSurfaceText(row.subtitle, state, limits) ||
      !addNativeSurfaceText(row.detail, state, limits) ||
      !addNativeSurfaceText(row.state, state, limits) ||
      !addNativeSurfaceText(row.link, state, limits)
    ) {
      return false;
    }

    if (
      row.progress !== undefined &&
      (typeof row.progress !== "number" || !Number.isFinite(row.progress))
    ) {
      return false;
    }
    if (
      row.children !== undefined &&
      !validateNativeActivityRows(row.children, depth + 1, state, limits)
    ) {
      return false;
    }
    if (
      row.blocks !== undefined &&
      !(
        Array.isArray(row.blocks) &&
        row.blocks.every((block) => validateNativeBlock(block, depth + 1, state, limits))
      )
    ) {
      return false;
    }
  }

  return true;
}

function validateNativeBlock(
  value: unknown,
  depth: number,
  state: NativeSurfaceLimitState,
  limits: NativeSurfaceLimits,
): boolean {
  if (!isRecord(value)) return false;
  if (depth > limits.maxDepth) return false;
  state.blocks += 1;
  if (state.blocks > limits.maxBlocks) return false;
  if (!validateNativeBlockBase(value, state, limits)) return false;

  switch (value.type) {
    case "text":
      return validateNativeSpans(value.spans, state, limits);
    case "markdown":
      return addNativeSurfaceText(value.markdown, state, limits, true);
    case "section":
      return (
        addNativeSurfaceText(value.title, state, limits) &&
        addNativeSurfaceText(value.subtitle, state, limits) &&
        Array.isArray(value.blocks) &&
        value.blocks.every((block) => validateNativeBlock(block, depth + 1, state, limits))
      );
    case "activityList":
      return validateNativeActivityRows(value.rows, depth + 1, state, limits);
    case "progress":
      return (
        addNativeSurfaceText(value.label, state, limits) &&
        (value.value === undefined ||
          (typeof value.value === "number" && Number.isFinite(value.value))) &&
        (value.indeterminate === undefined || typeof value.indeterminate === "boolean")
      );
    case "terminal": {
      const lines = value.lines;
      if (lines === undefined && typeof value.text !== "string") return false;
      if (!addNativeSurfaceText(value.text, state, limits)) return false;
      if (lines === undefined) return true;
      if (!Array.isArray(lines)) return false;
      state.terminalLines += lines.length;
      return (
        state.terminalLines <= limits.maxTerminalLines &&
        lines.every((line) => validateNativeSpans(line, state, limits))
      );
    }
    case "code":
      return (
        addNativeSurfaceText(value.language, state, limits) &&
        addNativeSurfaceText(value.text, state, limits, true)
      );
    case "divider":
      return true;
    case "spacer":
      return addNativeSurfaceText(value.size, state, limits);
    case "table": {
      if (!Array.isArray(value.columns) || !Array.isArray(value.rows)) return false;
      if (value.truncated !== undefined && typeof value.truncated !== "boolean") return false;
      if (!value.columns.every((column) => addNativeSurfaceText(column, state, limits, true))) {
        return false;
      }
      return value.rows.every(
        (row) =>
          Array.isArray(row) &&
          row.every((cell) => {
            if (cell === null) return true;
            if (typeof cell === "number") return Number.isFinite(cell);
            return addNativeSurfaceText(cell, state, limits, true);
          }),
      );
    }
    case "chart": {
      if (value.kind !== "bar" && value.kind !== "line" && value.kind !== "pie") return false;
      if (!Array.isArray(value.labels) || !Array.isArray(value.series)) return false;
      if (value.truncated !== undefined && typeof value.truncated !== "boolean") return false;
      if (!addNativeSurfaceText(value.title, state, limits)) return false;
      if (!value.labels.every((label) => addNativeSurfaceText(label, state, limits, true))) {
        return false;
      }
      return value.series.every((entry) => {
        if (!isRecord(entry) || !Array.isArray(entry.values)) return false;
        if (!addNativeSurfaceText(entry.name, state, limits)) return false;
        return entry.values.every((item) => typeof item === "number" && Number.isFinite(item));
      });
    }
    default:
      return addNativeSurfaceText(value.type, state, limits);
  }
}

function validateNativeSurfaceShape(
  value: Record<string, unknown>,
  limits: NativeSurfaceLimits,
): boolean {
  const presentation = value.presentation;
  const blocks = value.blocks;
  if (!isRecord(presentation) || !Array.isArray(blocks)) return false;

  const state: NativeSurfaceLimitState = {
    blocks: 0,
    textBytes: 0,
    spans: 0,
    terminalLines: 0,
    activityRows: 0,
  };

  if (!addNativeSurfaceText(value.id, state, limits, true)) return false;
  if (
    !addNativeSurfaceText(presentation.title, state, limits) ||
    !addNativeSurfaceText(presentation.subtitle, state, limits)
  ) {
    return false;
  }

  if (
    value.fallback !== undefined &&
    value.fallback !== null &&
    !validateNativeFallback(value.fallback, state, limits)
  ) {
    return false;
  }

  return blocks.every((block) => validateNativeBlock(block, 1, state, limits));
}

function validateNativeFallback(
  value: unknown,
  state: NativeSurfaceLimitState,
  limits: NativeSurfaceLimits,
): boolean {
  if (!isRecord(value)) return false;
  if (!addNativeSurfaceText(value.text, state, limits)) return false;
  if (value.lines === undefined || value.lines === null) return true;
  if (!Array.isArray(value.lines)) return false;
  state.terminalLines += value.lines.length;
  return (
    state.terminalLines <= limits.maxTerminalLines &&
    value.lines.every((line) => addNativeSurfaceText(line, state, limits, true))
  );
}

export function normalizeExtensionUINativeSurface(
  value: unknown,
  options: ExtensionUINativeSurfaceLimitOptions = {},
): ExtensionUINativeSurface | undefined {
  if (!isRecord(value)) return undefined;
  if (value.version !== 1) return undefined;
  if (typeof value.id !== "string" || value.id.length === 0) return undefined;
  if (value.source !== "widget") return undefined;
  if (!isRecord(value.presentation)) return undefined;
  if (value.presentation.style !== "surfacePanel") return undefined;
  if (!Array.isArray(value.blocks)) return undefined;

  const limits = nativeSurfaceLimits(options);
  const clipped = clipNativeSurface(value);
  if (!validateNativeSurfaceShape(clipped, limits)) return undefined;

  let json: string;
  try {
    json = JSON.stringify(clipped);
  } catch {
    return undefined;
  }

  if (Buffer.byteLength(json, "utf8") > limits.maxBytes) {
    return undefined;
  }

  try {
    return JSON.parse(json) as ExtensionUINativeSurface;
  } catch {
    return undefined;
  }
}

export function canonicalizeExtensionUIWidgetNativeSurface(
  surface: ExtensionUINativeSurface | undefined,
  widgetKey: string | undefined,
): ExtensionUINativeSurface | undefined {
  if (!surface || !widgetKey) return undefined;
  return { ...surface, id: `widget:${widgetKey}`, source: "widget" };
}

export function normalizeExtensionUIWidgetNativeSurface(
  value: unknown,
  widgetKey: string | undefined,
  options: ExtensionUINativeSurfaceLimitOptions = {},
): ExtensionUINativeSurface | undefined {
  return canonicalizeExtensionUIWidgetNativeSurface(
    normalizeExtensionUINativeSurface(value, options),
    widgetKey,
  );
}

export function normalizeExtensionUINotifyType(value: unknown): ExtensionUINotifyType | undefined {
  return value === "info" || value === "warning" || value === "error" ? value : undefined;
}

export function normalizeExtensionUIWidgetPlacement(
  value: unknown,
): ExtensionUIWidgetPlacement | undefined {
  return value === "aboveEditor" || value === "belowEditor" ? value : undefined;
}

function invalidAskResponse(message: string): Error {
  return new Error(`Malformed ask response: ${message}`);
}

function limitDisplayText(value: string, maxChars: number | undefined): string {
  if (maxChars === undefined) return value;
  const chars = Array.from(value);
  if (chars.length <= maxChars) return value;
  return `${chars.slice(0, Math.max(0, maxChars - 1)).join("")}…`;
}

function sanitizeExtensionUIWidgetLines(value: string[] | undefined): string[] | undefined {
  return value?.map((line) => terminalLineVisibleText(line));
}

function sanitizeExtensionUIDisplayText(
  value: string | undefined,
  maxChars?: number,
): string | undefined {
  return value === undefined
    ? undefined
    : limitDisplayText(terminalLineVisibleText(value), maxChars);
}

function sanitizeExtensionUIAskQuestions(
  questions: AskQuestion[] | undefined,
): AskQuestion[] | undefined {
  return questions?.map((question) => ({
    ...question,
    question: terminalLineVisibleText(question.question),
    options: question.options.map((option) => ({
      ...option,
      label: terminalLineVisibleText(option.label),
      description: sanitizeExtensionUIDisplayText(option.description),
    })),
  }));
}

function normalizeExtensionUIWorkingIndicator(
  value: unknown,
): ExtensionUIWorkingIndicator | undefined {
  if (value === undefined) return undefined;
  if (!isRecord(value)) return undefined;

  const indicator: ExtensionUIWorkingIndicator = {};
  if (value.frames !== undefined) {
    if (!Array.isArray(value.frames)) return undefined;
    indicator.frames = value.frames
      .filter((frame): frame is string => typeof frame === "string")
      .slice(0, EXTENSION_UI_WORKING_INDICATOR_MAX_FRAMES)
      .map((frame) =>
        limitDisplayText(
          terminalLineVisibleText(frame),
          EXTENSION_UI_WORKING_INDICATOR_MAX_FRAME_CHARS,
        ),
      );
  }

  if (value.intervalMs !== undefined) {
    if (typeof value.intervalMs !== "number" || !Number.isFinite(value.intervalMs)) {
      return undefined;
    }
    indicator.intervalMs = Math.max(
      EXTENSION_UI_WORKING_INDICATOR_MIN_INTERVAL_MS,
      Math.min(EXTENSION_UI_WORKING_INDICATOR_MAX_INTERVAL_MS, Math.round(value.intervalMs)),
    );
  }

  return indicator.frames === undefined ? undefined : indicator;
}

function nativeTerminalFallbackSurfaceFromWidgetLines(
  widgetKey: string | undefined,
  rawWidgetLines: string[] | undefined,
  sanitizedWidgetLines: string[] | undefined,
): ExtensionUINativeSurface | undefined {
  if (!widgetKey || !rawWidgetLines || !sanitizedWidgetLines) return undefined;

  const parsedLines = rawWidgetLines.map((line) => terminalLineToTextSpans(line));
  const hasNativeTerminalAttributes = parsedLines.some((line) =>
    line.some(
      (span) =>
        Boolean(span.link) ||
        Boolean(span.role) ||
        (Array.isArray(span.traits) && span.traits.length > 0),
    ),
  );
  if (!hasNativeTerminalAttributes) return undefined;

  const fallbackLines = sanitizedWidgetLines.filter(
    (line) => line.trim().length > 0 || line.length > 0,
  );

  return normalizeExtensionUIWidgetNativeSurface(
    {
      version: 1,
      id: `widget:${widgetKey}`,
      source: "widget",
      presentation: {
        style: "surfacePanel",
        title: widgetKey,
      },
      blocks: [
        {
          type: "terminal",
          id: "terminal-fallback",
          lines: parsedLines as ExtensionUITextSpan[][],
        },
      ],
      fallback: { lines: fallbackLines },
    },
    widgetKey,
  );
}

function normalizeAskAnswers(value: string): Record<string, string | string[]> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch (error) {
    throw invalidAskResponse(error instanceof Error ? error.message : String(error));
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw invalidAskResponse("expected a JSON object");
  }

  const answers: Record<string, string | string[]> = {};
  for (const [key, answer] of Object.entries(parsed)) {
    if (typeof answer === "string") {
      answers[key] = answer;
      continue;
    }

    if (Array.isArray(answer) && answer.every((item) => typeof item === "string")) {
      answers[key] = answer;
      continue;
    }

    throw invalidAskResponse(`expected string or string[] for "${key}"`);
  }

  return answers;
}

export function parseExtensionUIAskResponse(
  response: ExtensionUIResponsePayload,
): ExtensionUIAskResult {
  if (response.cancelled || !response.value) {
    return { answers: {}, allIgnored: true };
  }

  const answers = normalizeAskAnswers(response.value);
  return {
    answers,
    allIgnored: Object.keys(answers).length === 0,
  };
}

export function parseExtensionUISelectResponse(
  response: ExtensionUIResponsePayload,
): string | undefined {
  return response.cancelled ? undefined : response.value;
}

export function parseExtensionUIConfirmResponse(response: ExtensionUIResponsePayload): boolean {
  return response.cancelled ? false : (response.confirmed ?? false);
}

export function parseExtensionUITextResponse(
  response: ExtensionUIResponsePayload,
): string | undefined {
  return response.cancelled ? undefined : response.value;
}

export function isExtensionUISessionStreamOnlyMethod(method: string): boolean {
  return EXTENSION_UI_SESSION_STREAM_ONLY_METHODS.has(method);
}

export function isExtensionUIFireAndForgetMethod(method: string): boolean {
  return EXTENSION_UI_FIRE_AND_FORGET_METHODS.has(method);
}

export function buildExtensionUINotificationMessage(
  req: ExtensionUIProtocolRequest,
  overrides: { statusText?: string } = {},
): ServerMessage {
  const widgetLines = sanitizeExtensionUIWidgetLines(req.widgetLines);
  const nativeSurface =
    req.method === "setWidget"
      ? (normalizeExtensionUIWidgetNativeSurface(req.nativeSurface, req.widgetKey) ??
        nativeTerminalFallbackSurfaceFromWidgetLines(req.widgetKey, req.widgetLines, widgetLines))
      : undefined;

  const message: ServerMessage = {
    type: "extension_ui_notification",
    method: req.method,
    message: sanitizeExtensionUIDisplayText(
      req.message,
      req.method === "setWorkingMessage" ? EXTENSION_UI_WORKING_MESSAGE_MAX_CHARS : undefined,
    ),
    notifyType: normalizeExtensionUINotifyType(req.notifyType),
    statusKey: req.statusKey,
    statusText: sanitizeExtensionUIDisplayText(
      Object.hasOwn(overrides, "statusText") ? overrides.statusText : req.statusText,
      req.method === "setStatus" ? EXTENSION_UI_STATUS_TEXT_MAX_CHARS : undefined,
    ),
    title: sanitizeExtensionUIDisplayText(req.title),
    hiddenThinkingLabel: sanitizeExtensionUIDisplayText(req.hiddenThinkingLabel),
    text: req.text,
    widgetKey: req.widgetKey,
    widgetLines,
    widgetPlacement: normalizeExtensionUIWidgetPlacement(req.widgetPlacement),
    extensionScopeId: sanitizeExtensionUIDisplayText(req.extensionScopeId),
    extensionDisplayName: sanitizeExtensionUIDisplayText(req.extensionDisplayName),
    workingIndicator: normalizeExtensionUIWorkingIndicator(req.workingIndicator),
    workingVisible: typeof req.workingVisible === "boolean" ? req.workingVisible : undefined,
    toolsExpanded: typeof req.toolsExpanded === "boolean" ? req.toolsExpanded : undefined,
  };
  if (nativeSurface) {
    message.nativeSurface = nativeSurface;
  }
  return message;
}

/**
 * Dialog timeouts are whole milliseconds on the wire. The Apple client decodes them as integers
 * and drops the whole request frame for a value like `1.1 * 1000`. A positive value stays at
 * least 1; anything else means no timeout.
 */
function wireMilliseconds(value: number | undefined): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? Math.max(1, Math.round(value))
    : undefined;
}

export function buildExtensionUIRequestMessage(
  sessionId: string,
  req: ExtensionUIProtocolRequest,
): ServerMessage {
  const timeout = wireMilliseconds(req.timeout);
  const timeoutAt = wireMilliseconds(req.timeoutAt);
  if (req.method === "ask") {
    return {
      type: "extension_ui_request",
      id: req.id,
      sessionId,
      method: req.method,
      questions: sanitizeExtensionUIAskQuestions(req.questions),
      allowCustom: req.allowCustom,
      timeout,
      timeoutAt,
      extensionScopeId: sanitizeExtensionUIDisplayText(req.extensionScopeId),
      extensionDisplayName: sanitizeExtensionUIDisplayText(req.extensionDisplayName),
    };
  }

  return {
    type: "extension_ui_request",
    id: req.id,
    sessionId,
    method: req.method,
    title: sanitizeExtensionUIDisplayText(req.title),
    options: req.options,
    message: sanitizeExtensionUIDisplayText(req.message),
    placeholder: sanitizeExtensionUIDisplayText(req.placeholder),
    prefill: req.prefill,
    timeout,
    timeoutAt,
    extensionScopeId: sanitizeExtensionUIDisplayText(req.extensionScopeId),
    extensionDisplayName: sanitizeExtensionUIDisplayText(req.extensionDisplayName),
  };
}

export function buildExtensionUISettledMessage(sessionId: string, id: string): ServerMessage {
  return {
    type: "extension_ui_settled",
    id,
    sessionId,
  };
}
