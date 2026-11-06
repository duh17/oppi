import {
  EXTENSION_UI_NATIVE_CHART_MAX_LABELS,
  EXTENSION_UI_NATIVE_CHART_MAX_SERIES,
  normalizeExtensionUINativeSurface,
  type ExtensionUIProtocolRequest,
} from "./extension-ui-contract.js";
import { isExtensionUISurfaceIconName } from "./extension-surface-icons.js";
import { projectNodeToV1, v1PillSubtitle, v1TextBlock } from "./extension-surface-projection.js";
import type {
  ExtensionUIAccessibility,
  ExtensionUIBlocksComposite,
  ExtensionUISurface,
  ExtensionUISurfaceActionDefinition,
  ExtensionUISurfaceAtom,
  ExtensionUISurfaceCompositeKind,
  ExtensionUISurfaceNode,
  ExtensionUISurfaceNodeAction,
  ExtensionUISurfacePill,
  ExtensionUISurfaceSection,
  ExtensionUISurfaceState,
  ExtensionUISurfaceStateKind,
  ExtensionUISurfaceTone,
  ExtensionUINativeSurface,
  ExtensionUITextSpan,
} from "./types.js";

/**
 * Composable extension surfaces, version 2: validation, patch merge, and the v1 projection.
 *
 * A surface is JSON the host draws with views it already ships. The extension supplies data, the
 * action ids it offers, and the words for loading, empty, and failure; it cannot restyle or
 * reorder anything. Everything here is a pure function over untrusted JSON: a surface that breaks
 * a rule is dropped whole (`undefined`), never repaired into something the author did not write.
 */

export const EXTENSION_UI_SURFACE_VERSION = 2;
export const EXTENSION_UI_SURFACE_MAX_BYTES = 64 * 1024;
export const EXTENSION_UI_SURFACE_MAX_SECTIONS = 8;
/** Steps, checklist items, and table rows share one row cap. */
export const EXTENSION_UI_SURFACE_MAX_ITEMS = 200;
export const EXTENSION_UI_SURFACE_MAX_COLUMNS = 32;
export const EXTENSION_UI_SURFACE_MAX_CELL_CHARS = 200;
// Depth: a surface holds sections, a section holds atoms in the slots its composite names, and
// an atom holds nothing. Two containers is the whole shape, so the schema is the cap. A blocks
// body is the exception and carries its own depth, node, and fan-out caps below.
export const EXTENSION_UI_SURFACE_MAX_ACTIONS = 40;
/** A blocks body's deepest node; the body root is depth 1. */
export const EXTENSION_UI_SURFACE_MAX_NODE_DEPTH = 5;
/** Every node any blocks section or the pill carries, across the surface. */
export const EXTENSION_UI_SURFACE_MAX_NODES = 300;
export const EXTENSION_UI_SURFACE_MAX_ROW_CHILDREN = 12;
/** A node's words: longer than a title, shorter than the surface's fallback text. */
export const EXTENSION_UI_SURFACE_MAX_NODE_TEXT_CHARS = 500;
export const EXTENSION_UI_SURFACE_MAX_KEY_VALUES = 24;
/** The values one tap may carry, after the host merges what the node declared on top of them. */
export const EXTENSION_UI_SURFACE_MAX_ACTION_VALUES = 32;
/**
 * One fewer than a tap may carry: the host merges a toggle's own `value` on top of what the node
 * declared, so a node that declared the full cap could never send its tap.
 */
export const EXTENSION_UI_SURFACE_MAX_NODE_ACTION_VALUES =
  EXTENSION_UI_SURFACE_MAX_ACTION_VALUES - 1;
/** The pill is a surface-level region, and `pill` is not a section id anywhere: reserved. */
export const EXTENSION_UI_SURFACE_PILL_COMPOSITE_ID = "pill";
/** Actions a surface accepts per client per minute; beyond it the card shows an error. */
export const EXTENSION_UI_SURFACE_ACTION_RATE_LIMIT = 60;
export const EXTENSION_UI_SURFACE_ACTION_RATE_WINDOW_MS = 60_000;
export const EXTENSION_UI_SURFACE_MAX_TITLE_CHARS = 200;
export const EXTENSION_UI_SURFACE_MAX_FALLBACK_CHARS = 2_000;
export const EXTENSION_UI_SURFACE_MAX_ATOMS = 8;
export const EXTENSION_UI_SURFACE_MAX_SPANS = 320;
/** The composites that share one base: header, state, actions, fallback, tone. */
const CLOSED_COMPOSITES = [
  "statusCard",
  "checklist",
  "dataTable",
  "actionBar",
] as const satisfies readonly ExtensionUISurfaceCompositeKind[];
const TONES: readonly ExtensionUISurfaceTone[] = [
  "neutral",
  "accent",
  "success",
  "warning",
  "danger",
];
const STATES: readonly ExtensionUISurfaceStateKind[] = ["loading", "empty", "failure", "content"];
const ITEM_STATES = ["queued", "running", "success", "warning", "error", "inactive"] as const;
const ATOM_TYPES = ["text", "markdown", "progress", "divider", "spacer"] as const;
const ELAPSED_FORMATS = ["clock", "short"] as const;
/** The latest instant a JS Date holds: a `since` past it is not a time. */
const MAX_EPOCH_MS = 8.64e15;
const NODE_TYPES = [
  "row",
  "stack",
  "group",
  "text",
  "markdown",
  "badge",
  "icon",
  "elapsed",
  "progress",
  "keyValue",
  "table",
  "chart",
  "code",
  "divider",
  "spacer",
  "button",
  "toggle",
  "menu",
] as const;
/** The primitives that are a control of their own: their tap is their required `action`. */
const CONTROL_NODE_TYPES: ReadonlySet<string> = new Set(["button", "toggle", "menu"]);
/** The primitives that are a tap target as a whole, through their own `action`. */
const TAPPABLE_NODE_TYPES: ReadonlySet<string> = new Set(["row", "stack", "text", "badge"]);
/** The primitives whose look carries a `tone`; every other kind has no colour of its own. */
const TONED_NODE_TYPES: ReadonlySet<string> = new Set([
  "text",
  "badge",
  "icon",
  "progress",
  "elapsed",
]);
/** The primitives that can be drawn as unusable: a control, or a tappable region. */
const DISABLEABLE_NODE_TYPES: ReadonlySet<string> = new Set([
  "row",
  "stack",
  "text",
  "badge",
  "button",
  "toggle",
  "menu",
]);
/** The primitives that can carry a selection: the active item of a set. */
const SELECTABLE_NODE_TYPES: ReadonlySet<string> = new Set(["row", "text", "badge", "button"]);
const NODE_SPACING = ["tight", "normal"] as const;
const NODE_ALIGNS = ["leading", "center", "trailing", "spread"] as const;
const TEXT_STYLES = ["body", "headline", "caption", "mono"] as const;
const NODE_ROLES = ["primary", "secondary", "destructive"] as const;
/** What a pill may hold: one line of inline facts, never a control. */
const PILL_NODE_TYPES = ["icon", "text", "badge", "elapsed", "progress"] as const;
/** Stable ids become accessibility identifiers on the device: no spaces, no separators we own. */
const STABLE_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function text(value: unknown, maxChars: number, required: true): string;
function text(value: unknown, maxChars: number, required?: false): string | undefined;
function text(value: unknown, maxChars: number, required = false): string | undefined {
  if (value === undefined || value === null) {
    if (required) throw new SurfaceShapeError("a required string is missing");
    return undefined;
  }
  if (typeof value !== "string") throw new SurfaceShapeError("a string field is not a string");
  if (required && value.trim().length === 0) throw new SurfaceShapeError("a string field is empty");
  if (Array.from(value).length > maxChars)
    throw new SurfaceShapeError(`a string field exceeds ${maxChars} characters`);
  return value;
}

function stableId(value: unknown): string {
  if (typeof value !== "string" || !STABLE_ID.test(value))
    throw new SurfaceShapeError("an id is not a stable identifier");
  return value;
}

function oneOf<T extends string>(values: readonly T[], value: unknown, fallback?: T): T {
  if (value === undefined || value === null) {
    if (fallback !== undefined) return fallback;
    throw new SurfaceShapeError("a required enum is missing");
  }
  if (typeof value !== "string" || !values.includes(value as T))
    throw new SurfaceShapeError(`"${String(value)}" is not one of ${values.join(", ")}`);
  return value as T;
}

function list(value: unknown, max: number, what: string): unknown[] {
  if (!Array.isArray(value)) throw new SurfaceShapeError(`${what} is not an array`);
  if (value.length > max) throw new SurfaceShapeError(`${what} exceeds ${max} entries`);
  return value;
}

/** Thrown inside the validator; the normalizer turns it into a dropped surface. */
class SurfaceShapeError extends Error {}

interface SurfaceLimitState {
  spans: number;
  nodes: number;
  nodeIds: Set<string>;
}

function atom(value: unknown, state: SurfaceLimitState): ExtensionUISurfaceAtom {
  if (!isRecord(value)) throw new SurfaceShapeError("an atom is not an object");
  const type = oneOf(ATOM_TYPES, value.type);
  switch (type) {
    case "text": {
      const spans = list(value.spans, EXTENSION_UI_SURFACE_MAX_SPANS, "atom spans");
      const parsed: ExtensionUITextSpan[] = spans.map((span) => {
        state.spans += 1;
        if (state.spans > EXTENSION_UI_SURFACE_MAX_SPANS)
          throw new SurfaceShapeError(
            `the surface exceeds ${EXTENSION_UI_SURFACE_MAX_SPANS} text spans`,
          );
        if (!isRecord(span)) throw new SurfaceShapeError("a span is not an object");
        const role =
          span.role === undefined
            ? undefined
            : oneOf(
                [
                  "primary",
                  "secondary",
                  "muted",
                  "accent",
                  "success",
                  "warning",
                  "danger",
                  "code",
                ] as const,
                span.role,
              );
        const traits =
          span.traits === undefined
            ? undefined
            : list(span.traits, 8, "span traits").map((trait) =>
                oneOf(
                  ["bold", "italic", "monospaced", "strikethrough", "underline"] as const,
                  trait,
                ),
              );
        return {
          text: text(span.text, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS, true),
          ...(role ? { role } : {}),
          ...(traits ? { traits } : {}),
          ...(span.link === undefined
            ? {}
            : { link: text(span.link, EXTENSION_UI_SURFACE_MAX_FALLBACK_CHARS) }),
        };
      });
      return { type, spans: parsed };
    }
    case "markdown":
      return {
        type,
        markdown: text(value.markdown, EXTENSION_UI_SURFACE_MAX_FALLBACK_CHARS, true),
      };
    case "progress": {
      if (
        value.value !== undefined &&
        (typeof value.value !== "number" || !Number.isFinite(value.value) || value.value < 0)
      )
        throw new SurfaceShapeError("a progress value is not a finite non-negative number");
      return {
        type,
        ...(value.label === undefined
          ? {}
          : { label: text(value.label, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS) }),
        ...(value.value === undefined ? {} : { value: value.value as number }),
      };
    }
    case "divider":
      return { type };
    case "spacer":
      return {
        type,
        ...(value.size === undefined
          ? {}
          : { size: oneOf(["small", "medium", "large"] as const, value.size) }),
      };
  }
}

function state(value: unknown): ExtensionUISurfaceState {
  if (!isRecord(value)) throw new SurfaceShapeError("a composite state is not an object");
  const kind = oneOf(STATES, value.kind);
  const title = text(value.title, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS);
  const message = text(value.message, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS);
  // The host draws empty and failure from the author's words, so both are required there.
  if ((kind === "empty" || kind === "failure") && (title === undefined || message === undefined))
    throw new SurfaceShapeError(`a "${kind}" state needs title and message`);
  return { kind, ...(title ? { title } : {}), ...(message ? { message } : {}) };
}

function actionRef(value: unknown, actions: Record<string, unknown>): string {
  const actionId = stableId(value);
  if (!Object.hasOwn(actions, actionId))
    throw new SurfaceShapeError(`action "${actionId}" is not in the surface's action table`);
  return actionId;
}

/** A tap a node offers: the action id, the values it sends, and its declared pending state. */
function nodeAction(
  value: unknown,
  actions: Record<string, unknown>,
): ExtensionUISurfaceNodeAction {
  if (!isRecord(value)) throw new SurfaceShapeError("a node action is not an object");
  let values: Record<string, string | number | boolean> | undefined;
  if (value.values !== undefined) {
    if (!isRecord(value.values)) throw new SurfaceShapeError("action values are not an object");
    const entries = Object.entries(value.values);
    if (entries.length > EXTENSION_UI_SURFACE_MAX_NODE_ACTION_VALUES)
      throw new SurfaceShapeError(
        `action values exceed ${EXTENSION_UI_SURFACE_MAX_NODE_ACTION_VALUES} entries`,
      );
    values = {};
    for (const [key, entry] of entries) {
      if (typeof entry === "string") {
        text(entry, EXTENSION_UI_SURFACE_MAX_NODE_TEXT_CHARS);
        values[key] = entry;
        continue;
      }
      if (typeof entry === "boolean") {
        values[key] = entry;
        continue;
      }
      if (typeof entry === "number" && Number.isFinite(entry)) {
        values[key] = entry;
        continue;
      }
      throw new SurfaceShapeError("an action value is not a string, number, or boolean");
    }
  }
  let pending: ExtensionUISurfaceNodeAction["pending"];
  if (value.pending !== undefined) {
    if (!isRecord(value.pending))
      throw new SurfaceShapeError("a node action's pending state is not an object");
    const disabled =
      value.pending.disabled === undefined
        ? undefined
        : list(value.pending.disabled, EXTENSION_UI_SURFACE_MAX_ACTIONS, "pending.disabled").map(
            (entry) => actionRef(entry, actions),
          );
    pending = {
      ...(value.pending.title === undefined
        ? {}
        : { title: text(value.pending.title, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS) }),
      ...(disabled ? { disabled } : {}),
    };
  }
  return {
    id: actionRef(value.id, actions),
    ...(values ? { values } : {}),
    ...(pending ? { pending } : {}),
  };
}

function accessibility(value: unknown): { label?: string; value?: string; hint?: string } {
  if (!isRecord(value)) throw new SurfaceShapeError("accessibility is not an object");
  return {
    ...(value.label === undefined
      ? {}
      : { label: text(value.label, EXTENSION_UI_SURFACE_MAX_NODE_TEXT_CHARS) }),
    ...(value.value === undefined
      ? {}
      : { value: text(value.value, EXTENSION_UI_SURFACE_MAX_NODE_TEXT_CHARS) }),
    ...(value.hint === undefined
      ? {}
      : { hint: text(value.hint, EXTENSION_UI_SURFACE_MAX_NODE_TEXT_CHARS) }),
  };
}

function iconName(value: unknown): string {
  if (typeof value !== "string" || !isExtensionUISurfaceIconName(value))
    throw new SurfaceShapeError(`"${String(value)}" is not an allowed icon name`);
  return value;
}

function nodeText(value: unknown): string {
  return text(value, EXTENSION_UI_SURFACE_MAX_NODE_TEXT_CHARS, true);
}

interface NodeBaseFields {
  id?: string;
  accessibility?: ExtensionUIAccessibility;
}

function nodeBase(value: Record<string, unknown>, state: SurfaceLimitState): NodeBaseFields {
  let id: string | undefined;
  if (value.id !== undefined) {
    id = stableId(value.id);
    if (state.nodeIds.has(id)) throw new SurfaceShapeError(`duplicate node id "${id}"`);
    state.nodeIds.add(id);
  }
  return {
    ...(id === undefined ? {} : { id }),
    ...(value.accessibility === undefined
      ? {}
      : { accessibility: accessibility(value.accessibility) }),
  };
}

function children(
  value: unknown,
  state: SurfaceLimitState,
  actions: Record<string, unknown>,
  depth: number,
): ExtensionUISurfaceNode[] {
  const entries = list(value, EXTENSION_UI_SURFACE_MAX_ROW_CHILDREN, "node children");
  if (entries.length === 0) throw new SurfaceShapeError("a layout node has no children");
  return entries.map((entry) => node(entry, state, actions, depth + 1));
}

/**
 * One node of a blocks tree. A node is a primitive the host draws — no font, colour, size, or
 * offset exists — and it counts against the surface's depth, node, fan-out, and action caps.
 */
function node(
  value: unknown,
  state: SurfaceLimitState,
  actions: Record<string, unknown>,
  depth: number,
): ExtensionUISurfaceNode {
  if (!isRecord(value)) throw new SurfaceShapeError("a node is not an object");
  if (depth > EXTENSION_UI_SURFACE_MAX_NODE_DEPTH)
    throw new SurfaceShapeError(
      `a blocks body is deeper than ${EXTENSION_UI_SURFACE_MAX_NODE_DEPTH} nodes`,
    );
  state.nodes += 1;
  if (state.nodes > EXTENSION_UI_SURFACE_MAX_NODES)
    throw new SurfaceShapeError(`the surface exceeds ${EXTENSION_UI_SURFACE_MAX_NODES} nodes`);
  const type = oneOf(NODE_TYPES, value.type);
  const base = nodeBase(value, state);
  // An action is behaviour and a tone is the host's paint: a kind that cannot honour one is
  // refused rather than published with the field quietly gone. A key the schema never names is
  // still dropped, because an unknown key is a newer build's, not a mistake in this one.
  if (value.action !== undefined && !TAPPABLE_NODE_TYPES.has(type) && !CONTROL_NODE_TYPES.has(type))
    throw new SurfaceShapeError(`a "${type}" node cannot offer an action`);
  if (value.tone !== undefined && !TONED_NODE_TYPES.has(type))
    throw new SurfaceShapeError(`a "${type}" node does not take a tone`);
  if (value.disabled !== undefined && !DISABLEABLE_NODE_TYPES.has(type))
    throw new SurfaceShapeError(`a "${type}" node does not take a disabled state`);
  if (value.selected !== undefined && !SELECTABLE_NODE_TYPES.has(type))
    throw new SurfaceShapeError(`a "${type}" node does not take a selected state`);
  const tappable = value.action === undefined ? {} : { action: nodeAction(value.action, actions) };
  const tone = value.tone === undefined ? {} : { tone: oneOf(TONES, value.tone) };
  const selected =
    value.selected === undefined ? {} : { selected: boolean(value.selected, "selected") };
  const disabled =
    value.disabled === undefined ? {} : { disabled: boolean(value.disabled, "disabled") };
  switch (type) {
    case "row":
      return {
        ...base,
        type,
        children: children(value.children, state, actions, depth),
        ...(value.spacing === undefined ? {} : { spacing: oneOf(NODE_SPACING, value.spacing) }),
        ...(value.align === undefined ? {} : { align: oneOf(NODE_ALIGNS, value.align) }),
        ...selected,
        ...disabled,
        ...tappable,
      };
    case "stack":
      return {
        ...base,
        type,
        children: children(value.children, state, actions, depth),
        ...(value.spacing === undefined ? {} : { spacing: oneOf(NODE_SPACING, value.spacing) }),
        ...disabled,
        ...tappable,
      };
    case "group":
      return {
        ...base,
        type,
        title: nodeText(value.title),
        ...(value.collapsed === undefined
          ? {}
          : { collapsed: boolean(value.collapsed, "collapsed") }),
        children: children(value.children, state, actions, depth),
      };
    case "text":
      return {
        ...base,
        type,
        text: nodeText(value.text),
        ...(value.style === undefined ? {} : { style: oneOf(TEXT_STYLES, value.style) }),
        ...tone,
        ...selected,
        ...disabled,
        ...tappable,
      };
    case "markdown":
      return {
        ...base,
        type,
        markdown: text(value.markdown, EXTENSION_UI_SURFACE_MAX_NODE_TEXT_CHARS, true),
      };
    case "badge":
      return {
        ...base,
        type,
        text: nodeText(value.text),
        ...tone,
        ...(value.icon === undefined ? {} : { icon: iconName(value.icon) }),
        ...selected,
        ...disabled,
        ...tappable,
      };
    case "icon":
      return { ...base, type, name: iconName(value.name), ...tone };
    case "elapsed": {
      if (
        typeof value.since !== "number" ||
        !Number.isFinite(value.since) ||
        value.since < 0 ||
        value.since > MAX_EPOCH_MS
      )
        throw new SurfaceShapeError("an elapsed since is not an epoch in milliseconds");
      return {
        ...base,
        type,
        since: value.since,
        ...(value.style === undefined ? {} : { style: oneOf(TEXT_STYLES, value.style) }),
        ...tone,
        ...(value.format === undefined ? {} : { format: oneOf(ELAPSED_FORMATS, value.format) }),
      };
    }
    case "progress": {
      let progressValue: number | undefined;
      if (value.value !== undefined) {
        if (typeof value.value !== "number" || !Number.isFinite(value.value))
          throw new SurfaceShapeError("a progress value is not a finite number");
        if (value.value < 0 || value.value > 1)
          throw new SurfaceShapeError("a progress value is outside 0–1");
        progressValue = value.value;
      }
      return {
        ...base,
        type,
        ...(progressValue === undefined ? {} : { value: progressValue }),
        ...(value.kind === undefined ? {} : { kind: oneOf(["bar", "ring"] as const, value.kind) }),
        ...(value.label === undefined
          ? {}
          : { label: text(value.label, EXTENSION_UI_SURFACE_MAX_NODE_TEXT_CHARS) }),
        ...tone,
      };
    }
    case "keyValue": {
      const pairs = list(value.pairs, EXTENSION_UI_SURFACE_MAX_KEY_VALUES, "key/value pairs").map(
        (pair) => {
          if (!isRecord(pair)) throw new SurfaceShapeError("a key/value pair is not an object");
          return {
            key: text(pair.key, EXTENSION_UI_SURFACE_MAX_NODE_TEXT_CHARS, true),
            value: text(pair.value, EXTENSION_UI_SURFACE_MAX_NODE_TEXT_CHARS, true),
            ...(pair.tone === undefined ? {} : { tone: oneOf(TONES, pair.tone) }),
          };
        },
      );
      if (pairs.length === 0) throw new SurfaceShapeError("a key/value node has no pairs");
      return { ...base, type, pairs };
    }
    case "table": {
      const columns = list(value.columns, EXTENSION_UI_SURFACE_MAX_COLUMNS, "table columns").map(
        (column) => text(column, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS, true),
      );
      if (columns.length === 0) throw new SurfaceShapeError("a table has no columns");
      const rows = list(value.rows, EXTENSION_UI_SURFACE_MAX_ITEMS, "table rows").map((row) => {
        if (!isRecord(row)) throw new SurfaceShapeError("a table row is not an object");
        const cells = list(row.cells, columns.length, "table cells").map((cell) => {
          if (cell === null) return null;
          if (typeof cell === "number") {
            if (!Number.isFinite(cell)) throw new SurfaceShapeError("a numeric cell is not finite");
            return cell;
          }
          if (typeof cell !== "string")
            throw new SurfaceShapeError("a cell is not a string, number, or null");
          return text(cell, EXTENSION_UI_SURFACE_MAX_CELL_CHARS, true);
        });
        const rowActions =
          row.actions === undefined
            ? undefined
            : list(row.actions, EXTENSION_UI_SURFACE_MAX_ACTIONS, "row actions").map((entry) =>
                nodeAction(entry, actions),
              );
        // A tap names the node and the row: a row with actions has to be nameable.
        if (rowActions && row.id === undefined)
          throw new SurfaceShapeError("a table row with actions has no id");
        if (rowActions && base.id === undefined)
          throw new SurfaceShapeError("a table with row actions has no id");
        return {
          ...(row.id === undefined ? {} : { id: stableId(row.id) }),
          cells,
          ...(rowActions ? { actions: rowActions } : {}),
        };
      });
      uniqueIds(
        rows.flatMap((row) => (row.id === undefined ? [] : [{ id: row.id }])),
        "table row",
      );
      return {
        ...base,
        type,
        columns,
        rows,
        ...(value.truncated === undefined
          ? {}
          : { truncated: boolean(value.truncated, "truncated") }),
      };
    }
    case "chart": {
      const labels = list(value.labels, EXTENSION_UI_NATIVE_CHART_MAX_LABELS, "chart labels").map(
        (label) => text(label, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS, true),
      );
      const series = list(value.series, EXTENSION_UI_NATIVE_CHART_MAX_SERIES, "chart series").map(
        (entry) => {
          if (!isRecord(entry)) throw new SurfaceShapeError("a chart series is not an object");
          const values = list(entry.values, labels.length, "chart values").map((point) => {
            if (typeof point !== "number" || !Number.isFinite(point))
              throw new SurfaceShapeError("a chart point is not a finite number");
            return point;
          });
          return {
            ...(entry.name === undefined
              ? {}
              : { name: text(entry.name, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS) }),
            values,
          };
        },
      );
      if (labels.length === 0) throw new SurfaceShapeError("a chart has no labels");
      if (series.length === 0) throw new SurfaceShapeError("a chart has no series");
      return {
        ...base,
        type,
        kind: oneOf(["bar", "line", "pie"] as const, value.kind),
        ...(value.title === undefined
          ? {}
          : { title: text(value.title, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS) }),
        labels,
        series,
        ...(value.truncated === undefined
          ? {}
          : { truncated: boolean(value.truncated, "truncated") }),
      };
    }
    case "code":
      return {
        ...base,
        type,
        ...(value.language === undefined
          ? {}
          : { language: text(value.language, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS) }),
        text: text(value.text, EXTENSION_UI_SURFACE_MAX_NODE_TEXT_CHARS, true),
      };
    case "divider":
      return { ...base, type };
    case "spacer":
      return {
        ...base,
        type,
        ...(value.size === undefined
          ? {}
          : { size: oneOf(["small", "medium", "large"] as const, value.size) }),
      };
    case "button":
      return {
        ...base,
        type,
        id: requiredNodeId(base),
        title: nodeText(value.title),
        ...(value.role === undefined ? {} : { role: oneOf(NODE_ROLES, value.role) }),
        ...(value.icon === undefined ? {} : { icon: iconName(value.icon) }),
        ...selected,
        ...disabled,
        action: nodeAction(value.action, actions),
      };
    case "toggle":
      return {
        ...base,
        type,
        id: requiredNodeId(base),
        title: nodeText(value.title),
        value: boolean(value.value, "a toggle's value"),
        ...disabled,
        action: nodeAction(value.action, actions),
      };
    case "menu": {
      const items = list(value.items, EXTENSION_UI_SURFACE_MAX_ROW_CHILDREN, "menu items").map(
        (item) => {
          if (!isRecord(item)) throw new SurfaceShapeError("a menu item is not an object");
          return {
            ...(item.id === undefined ? {} : { id: stableId(item.id) }),
            title: nodeText(item.title),
            ...(item.role === undefined ? {} : { role: oneOf(NODE_ROLES, item.role) }),
            action: nodeAction(item.action, actions),
          };
        },
      );
      if (items.length === 0) throw new SurfaceShapeError("a menu has no items");
      return {
        ...base,
        type,
        id: requiredNodeId(base),
        ...(value.title === undefined
          ? {}
          : { title: text(value.title, EXTENSION_UI_SURFACE_MAX_NODE_TEXT_CHARS) }),
        ...(value.icon === undefined ? {} : { icon: iconName(value.icon) }),
        ...disabled,
        items,
      };
    }
  }
}

/** A control is a tap target on its own: it cannot be tapped through a shared id. */
function requiredNodeId(base: NodeBaseFields): string {
  if (base.id === undefined) throw new SurfaceShapeError("an interactive node has no id");
  return base.id;
}

function pillOf(
  value: unknown,
  state: SurfaceLimitState,
  actions: Record<string, unknown>,
): ExtensionUISurfacePill {
  if (!isRecord(value)) throw new SurfaceShapeError("a pill is not an object");
  if (!isRecord(value.content)) throw new SurfaceShapeError("a pill content is not an object");
  if (value.content.type !== "row")
    throw new SurfaceShapeError("a pill content is a row of inline nodes");
  // The row is the pill's tap target, so it cannot also be a tap target of its own.
  if (value.content.action !== undefined)
    throw new SurfaceShapeError("a pill cannot hold a row with its own action");
  const content = node(value.content, state, actions, 1);
  if (content.type !== "row")
    throw new SurfaceShapeError("a pill content is a row of inline nodes");
  for (const child of content.children) {
    if (!(PILL_NODE_TYPES as readonly string[]).includes(child.type))
      throw new SurfaceShapeError(`a pill cannot hold a "${child.type}" node`);
    // A pill decides its own tap: a child that offers its own would be two taps in one target.
    if ("action" in child && child.action !== undefined)
      throw new SurfaceShapeError("a pill cannot hold a node with its own action");
  }
  const tap = value.tap;
  // The row and every child are a clean inline line: nothing in it offers a tap of its own.
  const pillContent = content as unknown as ExtensionUISurfacePill["content"];
  if (tap === "drawer") return { content: pillContent, tap };
  if (!isRecord(tap)) throw new SurfaceShapeError('a pill tap is "drawer" or an action');
  return { content: pillContent, tap: { action: nodeAction(tap.action, actions) } };
}

function actionIds(value: unknown, actions: Record<string, unknown>): string[] | undefined {
  if (value === undefined || value === null) return undefined;
  return list(value, EXTENSION_UI_SURFACE_MAX_ACTIONS, "composite actions").map((id) => {
    const actionId = stableId(id);
    if (!Object.hasOwn(actions, actionId))
      throw new SurfaceShapeError(`action "${actionId}" is not in the surface's action table`);
    return actionId;
  });
}

function compositeBase(
  value: Record<string, unknown>,
  actions: Record<string, unknown>,
): {
  id: string;
  header: { title: string; subtitle?: string };
  state: ExtensionUISurfaceState;
  actions?: string[];
  fallback: { text: string };
  tone?: ExtensionUISurfaceTone;
} {
  if (!isRecord(value.header)) throw new SurfaceShapeError("a composite header is not an object");
  if (!isRecord(value.fallback))
    throw new SurfaceShapeError("a composite fallback is not an object");
  const ids = actionIds(value.actions, actions);
  return {
    id: stableId(value.id),
    header: {
      title: text(value.header.title, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS, true),
      ...(value.header.subtitle === undefined
        ? {}
        : { subtitle: text(value.header.subtitle, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS) }),
    },
    state: state(value.state),
    ...(ids ? { actions: ids } : {}),
    fallback: {
      text: text(value.fallback.text, EXTENSION_UI_SURFACE_MAX_FALLBACK_CHARS, true),
    },
    ...(value.tone === undefined ? {} : { tone: oneOf(TONES, value.tone) }),
  };
}

function uniqueIds(values: readonly { id: string }[], what: string): void {
  const seen = new Set<string>();
  for (const entry of values) {
    if (seen.has(entry.id)) throw new SurfaceShapeError(`duplicate ${what} id "${entry.id}"`);
    seen.add(entry.id);
  }
}

/** A tree of primitives: the same shared fields, with an optional header and a body. */
function blocksSection(
  value: Record<string, unknown>,
  actions: Record<string, unknown>,
  limits: SurfaceLimitState,
): ExtensionUIBlocksComposite {
  if (!isRecord(value.fallback))
    throw new SurfaceShapeError("a composite fallback is not an object");
  if (value.state !== undefined && !isRecord(value.state))
    throw new SurfaceShapeError("a composite state is not an object");
  const ids = actionIds(value.actions, actions);
  let header: { title: string; subtitle?: string } | undefined;
  if (value.header !== undefined) {
    if (!isRecord(value.header)) throw new SurfaceShapeError("a composite header is not an object");
    header = {
      title: text(value.header.title, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS, true),
      ...(value.header.subtitle === undefined
        ? {}
        : { subtitle: text(value.header.subtitle, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS) }),
    };
  }
  return {
    composite: "blocks",
    id: stableId(value.id),
    ...(header ? { header } : {}),
    state: value.state === undefined ? { kind: "content" } : state(value.state),
    ...(ids ? { actions: ids } : {}),
    fallback: { text: text(value.fallback.text, EXTENSION_UI_SURFACE_MAX_FALLBACK_CHARS, true) },
    ...(value.tone === undefined ? {} : { tone: oneOf(TONES, value.tone) }),
    body: node(value.body, limits, actions, 1),
  };
}

function section(
  value: unknown,
  actions: Record<string, unknown>,
  limits: SurfaceLimitState,
): ExtensionUISurfaceSection {
  if (!isRecord(value)) throw new SurfaceShapeError("a section is not an object");
  if (value.composite === "blocks") return blocksSection(value, actions, limits);
  const composite = oneOf(CLOSED_COMPOSITES, value.composite);
  const base = compositeBase(value, actions);
  switch (composite) {
    case "statusCard": {
      const steps =
        value.steps === undefined
          ? undefined
          : list(value.steps, EXTENSION_UI_SURFACE_MAX_ITEMS, "statusCard steps").map((step) => {
              if (!isRecord(step)) throw new SurfaceShapeError("a step is not an object");
              const extra =
                step.extra === undefined
                  ? undefined
                  : list(step.extra, EXTENSION_UI_SURFACE_MAX_ATOMS, "step extra atoms").map(
                      (item) => atom(item, limits),
                    );
              return {
                id: stableId(step.id),
                title: text(step.title, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS, true),
                state: oneOf(ITEM_STATES, step.state),
                ...(step.detail === undefined
                  ? {}
                  : { detail: text(step.detail, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS) }),
                ...(extra ? { extra } : {}),
              };
            });
      if (steps) uniqueIds(steps, "step");
      return {
        ...base,
        composite,
        phase: oneOf(ITEM_STATES, value.phase),
        ...(steps ? { steps } : {}),
      };
    }
    case "checklist": {
      const items = list(value.items, EXTENSION_UI_SURFACE_MAX_ITEMS, "checklist items").map(
        (item) => {
          if (!isRecord(item)) throw new SurfaceShapeError("a checklist item is not an object");
          return {
            id: stableId(item.id),
            title: text(item.title, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS, true),
            state: oneOf(ITEM_STATES, item.state),
            ...(item.detail === undefined
              ? {}
              : { detail: text(item.detail, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS) }),
          };
        },
      );
      uniqueIds(items, "checklist item");
      return { ...base, composite, items };
    }
    case "dataTable": {
      const columns = list(
        value.columns,
        EXTENSION_UI_SURFACE_MAX_COLUMNS,
        "dataTable columns",
      ).map((column) => {
        if (!isRecord(column)) throw new SurfaceShapeError("a column is not an object");
        return {
          id: stableId(column.id),
          title: text(column.title, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS, true),
          ...(column.kind === undefined
            ? {}
            : { kind: oneOf(["text", "number"] as const, column.kind) }),
        };
      });
      uniqueIds(columns, "column");
      const columnIds = new Set(columns.map((column) => column.id));
      const rows = list(value.rows, EXTENSION_UI_SURFACE_MAX_ITEMS, "dataTable rows").map((row) => {
        if (!isRecord(row)) throw new SurfaceShapeError("a row is not an object");
        if (!isRecord(row.cells)) throw new SurfaceShapeError("a row's cells are not an object");
        const cells: Record<string, string | number | null> = {};
        for (const [columnId, cell] of Object.entries(row.cells)) {
          if (!columnIds.has(columnId))
            throw new SurfaceShapeError(`a cell names unknown column "${columnId}"`);
          if (cell === null) {
            cells[columnId] = null;
            continue;
          }
          if (typeof cell === "number") {
            if (!Number.isFinite(cell)) throw new SurfaceShapeError("a numeric cell is not finite");
            cells[columnId] = cell;
            continue;
          }
          if (typeof cell !== "string")
            throw new SurfaceShapeError("a cell is not a string, number, or null");
          if (Array.from(cell).length > EXTENSION_UI_SURFACE_MAX_CELL_CHARS)
            throw new SurfaceShapeError(
              `a cell exceeds ${EXTENSION_UI_SURFACE_MAX_CELL_CHARS} characters`,
            );
          cells[columnId] = cell;
        }
        const rowActions = actionIds(row.actions, actions);
        return {
          id: stableId(row.id),
          cells,
          ...(rowActions ? { actions: rowActions } : {}),
        };
      });
      uniqueIds(rows, "row");
      const sort =
        value.sort === undefined
          ? undefined
          : (() => {
              if (!isRecord(value.sort)) throw new SurfaceShapeError("sort is not an object");
              const columnId = stableId(value.sort.columnId);
              if (!columnIds.has(columnId))
                throw new SurfaceShapeError(`sort names unknown column "${columnId}"`);
              return {
                columnId,
                ...(value.sort.descending === undefined
                  ? {}
                  : { descending: boolean(value.sort.descending, "sort.descending") }),
              };
            })();
      const selectedRowId =
        value.selectedRowId === undefined
          ? undefined
          : (() => {
              const id = stableId(value.selectedRowId);
              if (!rows.some((row) => row.id === id))
                throw new SurfaceShapeError(`selectedRowId "${id}" is not a row`);
              return id;
            })();
      return {
        ...base,
        composite,
        columns,
        rows,
        ...(sort ? { sort } : {}),
        ...(selectedRowId ? { selectedRowId } : {}),
      };
    }
    case "actionBar":
      return { ...base, composite };
  }
}

function boolean(value: unknown, what: string): boolean {
  if (typeof value !== "boolean") throw new SurfaceShapeError(`${what} is not a boolean`);
  return value;
}

function actionTable(value: unknown): Record<string, ExtensionUISurfaceActionDefinition> {
  if (!isRecord(value)) throw new SurfaceShapeError("the action table is not an object");
  const entries = Object.entries(value);
  if (entries.length > EXTENSION_UI_SURFACE_MAX_ACTIONS)
    throw new SurfaceShapeError(
      `the action table exceeds ${EXTENSION_UI_SURFACE_MAX_ACTIONS} entries`,
    );
  const actions: Record<string, ExtensionUISurfaceActionDefinition> = {};
  for (const [id, entry] of entries) {
    stableId(id);
    if (!isRecord(entry)) throw new SurfaceShapeError("an action is not an object");
    let pending: ExtensionUISurfaceActionDefinition["pending"];
    if (entry.pending !== undefined) {
      if (!isRecord(entry.pending))
        throw new SurfaceShapeError("an action's pending state is not an object");
      const disabled =
        entry.pending.disabled === undefined
          ? undefined
          : list(entry.pending.disabled, EXTENSION_UI_SURFACE_MAX_ACTIONS, "pending.disabled").map(
              (disabledId) => {
                const actionId = stableId(disabledId);
                if (!Object.hasOwn(value, actionId))
                  throw new SurfaceShapeError(
                    `pending.disabled names unknown action "${actionId}"`,
                  );
                return actionId;
              },
            );
      pending = {
        ...(entry.pending.title === undefined
          ? {}
          : { title: text(entry.pending.title, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS) }),
        ...(disabled ? { disabled } : {}),
      };
    }
    actions[id] = {
      title: text(entry.title, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS, true),
      ...(entry.role === undefined
        ? {}
        : { role: oneOf(["primary", "secondary", "destructive"] as const, entry.role) }),
      ...(pending ? { pending } : {}),
    };
  }
  return actions;
}

function validateSurface(value: unknown): ExtensionUISurface {
  if (!isRecord(value)) throw new SurfaceShapeError("a surface is not an object");
  if (value.version !== EXTENSION_UI_SURFACE_VERSION)
    throw new SurfaceShapeError(`a surface is not version ${EXTENSION_UI_SURFACE_VERSION}`);
  if (!isRecord(value.placement)) throw new SurfaceShapeError("placement is not an object");
  // Slice 1 draws `strip` only; any other placement is refused rather than drawn wrong.
  const kind = oneOf(["strip"] as const, value.placement.kind);
  if (!isRecord(value.header)) throw new SurfaceShapeError("the surface header is not an object");
  if (!isRecord(value.fallback))
    throw new SurfaceShapeError("the surface fallback is not an object");
  const actions = actionTable(value.actions);
  const lifecycle = oneOf(["persistent", "oneShot"] as const, value.lifecycle);
  const timeoutAt =
    value.timeoutAt === undefined
      ? undefined
      : (() => {
          if (typeof value.timeoutAt !== "number" || !Number.isFinite(value.timeoutAt))
            throw new SurfaceShapeError("timeoutAt is not a finite number");
          return Math.round(value.timeoutAt);
        })();
  if (lifecycle === "oneShot" && timeoutAt === undefined)
    throw new SurfaceShapeError("a oneShot surface needs a timeoutAt deadline");

  const limits: SurfaceLimitState = { spans: 0, nodes: 0, nodeIds: new Set() };
  // Node ids are unique across the whole surface, not per section: a tap names one node id and a
  // patch path may address it without its section, so one id may name one node only.
  const sections = list(value.sections, EXTENSION_UI_SURFACE_MAX_SECTIONS, "surface sections").map(
    (entry) => section(entry, actions, limits),
  );
  uniqueIds(sections, "composite");
  for (const entry of sections) {
    if (entry.id === EXTENSION_UI_SURFACE_PILL_COMPOSITE_ID)
      throw new SurfaceShapeError(`"${EXTENSION_UI_SURFACE_PILL_COMPOSITE_ID}" is a reserved id`);
  }
  // The pill is the surface's own one-line summary; its nodes count against the same caps.
  const pill = value.pill === undefined ? undefined : pillOf(value.pill, limits, actions);

  const result: ExtensionUISurface = {
    version: EXTENSION_UI_SURFACE_VERSION,
    id: stableId(value.id),
    title: text(value.title, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS, true),
    placement: {
      kind,
      ...(value.placement.preferred === undefined
        ? {}
        : {
            preferred: oneOf(
              ["aboveComposer", "belowComposer"] as const,
              value.placement.preferred,
            ),
          }),
    },
    lifecycle,
    ...(timeoutAt === undefined ? {} : { timeoutAt }),
    header: {
      title: text(value.header.title, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS, true),
      ...(value.header.subtitle === undefined
        ? {}
        : { subtitle: text(value.header.subtitle, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS) }),
    },
    ...(pill ? { pill } : {}),
    sections,
    actions,
    fallback: {
      text: text(value.fallback.text, EXTENSION_UI_SURFACE_MAX_FALLBACK_CHARS, true),
    },
    revision: revision(value.revision),
    ...(value.extensionScopeId === undefined
      ? {}
      : { extensionScopeId: text(value.extensionScopeId, EXTENSION_UI_SURFACE_MAX_TITLE_CHARS) }),
    ...(value.extensionDisplayName === undefined
      ? {}
      : {
          extensionDisplayName: text(
            value.extensionDisplayName,
            EXTENSION_UI_SURFACE_MAX_TITLE_CHARS,
          ),
        }),
    ...(wireMilliseconds(value.publishedAt) === undefined
      ? {}
      : { publishedAt: wireMilliseconds(value.publishedAt) as number }),
  };
  return result;
}

function revision(value: unknown): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 1)
    throw new SurfaceShapeError("revision is not a positive integer");
  return value;
}

function wireMilliseconds(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? Math.round(value)
    : undefined;
}

/** A canonical surface, or the rule the value broke; a caller never publishes the problem. */
export type ExtensionUISurfaceRead = { surface: ExtensionUISurface } | { problem: string };

/**
 * A validated, canonical copy of `value`, or why it was refused. A caller never publishes
 * something this refused: the cap is the rule, not a hint to clip.
 */
export function readExtensionUISurface(value: unknown): ExtensionUISurfaceRead {
  let surface: ExtensionUISurface;
  try {
    surface = validateSurface(value);
  } catch (error) {
    if (error instanceof SurfaceShapeError) return { problem: error.message };
    throw error;
  }
  let json: string;
  try {
    json = JSON.stringify(surface);
  } catch {
    return { problem: "the surface is not serializable" };
  }
  if (Buffer.byteLength(json, "utf8") > EXTENSION_UI_SURFACE_MAX_BYTES)
    return { problem: `the surface exceeds ${EXTENSION_UI_SURFACE_MAX_BYTES} bytes` };
  return { surface: JSON.parse(json) as ExtensionUISurface };
}

const FORBIDDEN_PATH_SEGMENTS = new Set(["__proto__", "constructor", "prototype"]);
/** `id` and `version` are the surface's identity; a patch never rewrites them. */
const IMMUTABLE_PATCH_ROOTS = new Set(["id", "version"]);

function patchSegments(path: string): string[] {
  if (path.length === 0) throw new SurfaceShapeError("a patch path is empty");
  const segments = path.split(".");
  for (const segment of segments) {
    if (segment.length === 0) throw new SurfaceShapeError(`patch path "${path}" has an empty part`);
    if (FORBIDDEN_PATH_SEGMENTS.has(segment))
      throw new SurfaceShapeError(`patch path "${path}" names a prototype field`);
  }
  if (IMMUTABLE_PATCH_ROOTS.has(segments[0]))
    throw new SurfaceShapeError(`patch path "${path}" rewrites the surface's identity`);
  return segments;
}

function writePath(target: Record<string, unknown>, segments: string[], value: unknown): void {
  let node: Record<string, unknown> | unknown[] = target;
  for (let index = 0; index < segments.length - 1; index += 1) {
    const segment = segments[index];
    const next: unknown = Array.isArray(node) ? node[arrayIndex(node, segment)] : node[segment];
    if (Array.isArray(next)) {
      node = next;
      continue;
    }
    if (!isRecord(next)) {
      if (next !== undefined) throw new SurfaceShapeError("a patch path crosses a value");
      if (Array.isArray(node))
        throw new SurfaceShapeError("a patch path names a missing array entry");
      const created: Record<string, unknown> = {};
      node[segment] = created;
      node = created;
      continue;
    }
    node = next;
  }
  const last = segments[segments.length - 1];
  if (Array.isArray(node)) {
    const index = arrayIndex(node, last);
    if (value === null) throw new SurfaceShapeError("a patch cannot remove an array entry");
    node[index] = value;
    return;
  }
  // A `null` deletes the field, so a patch can remove an optional value (a subtitle, a sort).
  if (value === null) delete node[last];
  else node[last] = value;
}

/**
 * A patch path addresses an existing array entry by index, or by node id with `#id` — ids are
 * stable inside a surface, so a body node keeps its address when a sibling is inserted. It never
 * invents an entry.
 */
function arrayIndex(node: readonly unknown[], segment: string): number {
  if (segment.startsWith("#")) {
    const id = segment.slice(1);
    const index = node.findIndex((entry) => isRecord(entry) && entry.id === id);
    if (index < 0) throw new SurfaceShapeError(`no entry with id "${id}" in the list`);
    return index;
  }
  if (!/^\d+$/.test(segment)) throw new SurfaceShapeError(`"${segment}" is not an array index`);
  const index = Number(segment);
  if (index >= node.length)
    throw new SurfaceShapeError(`array index ${segment} is past the end of the list`);
  return index;
}

/**
 * A surface with `patch` merged in, validated like a full surface. `null` removes the named
 * field; `id` and `version` cannot be patched. `undefined` means drop the patch whole.
 */
export function applyExtensionUISurfacePatch(
  surface: ExtensionUISurface,
  patch: unknown,
): ExtensionUISurface | undefined {
  if (!isRecord(patch)) return undefined;
  const entries = Object.entries(patch);
  if (entries.length === 0) return undefined;
  // Deterministic order, and no path inside another: a client applies the frame's own keys, so
  // `sections.0` beside `sections.0.body` would land differently on each side. One path naming
  // another is malformed either way, and the same frame has to land the same way twice.
  const paths = entries.map(([path]) => path).sort();
  for (const [index, path] of paths.entries()) {
    for (const other of paths.slice(index + 1)) {
      if (other.startsWith(`${path}.`)) return undefined;
    }
  }
  let merged: Record<string, unknown>;
  try {
    merged = JSON.parse(JSON.stringify(surface)) as Record<string, unknown>;
    for (const path of paths) writePath(merged, patchSegments(path), patch[path]);
  } catch {
    return undefined;
  }
  // The revision is server-owned: a patch carries data, not the next version number.
  merged.revision = surface.revision;
  const read = readExtensionUISurface(merged);
  return "problem" in read ? undefined : read.surface;
}

/** The v1 widget slot a projected surface occupies, one per surface id. */
export function extensionUISurfaceWidgetKey(surfaceId: string): string {
  return `surface:${surfaceId}`;
}

/**
 * The v1 widget notification a client without the composites capability gets instead of the
 * surface. Dismissing it is the same slot with empty lines, like every v1 widget.
 */
export function extensionUISurfaceProjectionRequest(
  surface: ExtensionUISurface,
): ExtensionUIProtocolRequest {
  return {
    id: extensionUISurfaceWidgetKey(surface.id),
    method: "setWidget",
    widgetKey: extensionUISurfaceWidgetKey(surface.id),
    nativeSurface: projectExtensionUISurfaceToV1(surface),
    extensionScopeId: surface.extensionScopeId,
    extensionDisplayName: surface.extensionDisplayName,
  };
}

/** Clears the v1 widget a projected surface occupied. */
export function extensionUISurfaceProjectionClearRequest(
  surfaceId: string,
): ExtensionUIProtocolRequest {
  return {
    id: extensionUISurfaceWidgetKey(surfaceId),
    method: "setWidget",
    widgetKey: extensionUISurfaceWidgetKey(surfaceId),
    widgetLines: [],
  };
}

/**
 * The v1 surface an older client can draw: a `dataTable` section in its content state stays the
 * grid (the v1 table block and its clamps), every other section is its `fallback.text`. Slice 1
 * ships this one projection so a client without the composites capability still sees results.
 */
export function projectExtensionUISurfaceToV1(
  surface: ExtensionUISurface,
): ExtensionUINativeSurface {
  const blocks: unknown[] = [];
  for (const section of surface.sections) {
    if (section.composite === "blocks") {
      // A tree projects node by node; a region that is not showing its content stays its words.
      if (section.state.kind !== "content") {
        blocks.push(v1TextBlock(section.id, section.fallback.text));
        continue;
      }
      const controls: string[] = [];
      const titleOf = (id: string): string => surface.actions[id]?.title ?? id;
      let projected = projectNodeToV1(section.body, controls, titleOf);
      // The region's own verbs are drawn after the body, so they are named last.
      for (const id of section.actions ?? []) controls.push(titleOf(id));
      // A body of nothing but controls still owes the reader its words; emptiness is decided
      // before the control line, which would otherwise hide it.
      if (projected.length === 0) projected = [v1TextBlock(section.id, section.fallback.text)];
      // A verb v1 cannot draw is named, so the projection never silently loses one.
      if (controls.length > 0) {
        const named = [...new Set(controls)];
        projected = [...projected, v1TextBlock(undefined, `Actions: ${named.join(", ")}`)];
      }
      blocks.push(...projected);
      continue;
    }
    if (section.composite === "dataTable" && section.state.kind === "content") {
      blocks.push({
        type: "table",
        id: section.id,
        columns: section.columns.map((column) => column.title),
        rows: section.rows.map((row) =>
          section.columns.map((column) => row.cells[column.id] ?? null),
        ),
      });
      continue;
    }
    blocks.push({
      type: "text",
      id: section.id,
      spans: [{ text: section.fallback.text }],
    });
  }
  const pillSubtitle = v1PillSubtitle(surface);
  return (
    normalizeExtensionUINativeSurface({
      version: 1,
      id: `surface:${surface.id}`,
      source: "widget",
      presentation: {
        style: "surfacePanel",
        title: surface.title,
        // A composed pill is the surface's one-line summary: the v1 panel keeps that line.
        ...(pillSubtitle === undefined ? {} : { subtitle: pillSubtitle }),
      },
      blocks,
      fallback: { text: surface.fallback.text },
    }) ?? {
      version: 1,
      id: `surface:${surface.id}`,
      source: "widget",
      presentation: { style: "surfacePanel", title: surface.title },
      blocks: [{ type: "text", id: "fallback", spans: [{ text: surface.fallback.text }] }],
      fallback: { text: surface.fallback.text },
    }
  );
}

/**
 * Does this surface use the blocks capability? A tree section or a composed pill is a shape only
 * a client that draws primitives can draw; every other client gets the v1 projection instead.
 */
export function extensionUISurfaceUsesBlocks(surface: ExtensionUISurface): boolean {
  return (
    surface.pill !== undefined || surface.sections.some((entry) => entry.composite === "blocks")
  );
}

/** One node of a body by id, the way a patch and a tap address it. */
export function findExtensionUISurfaceNode(
  root: ExtensionUISurfaceNode,
  id: string,
): ExtensionUISurfaceNode | undefined {
  if (root.id === id) return root;
  if (root.type !== "row" && root.type !== "stack") return undefined;
  for (const child of root.children) {
    const found = findExtensionUISurfaceNode(child, id);
    if (found) return found;
  }
  return undefined;
}
