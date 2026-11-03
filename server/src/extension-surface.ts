import { normalizeExtensionUINativeSurface } from "./extension-ui-contract.js";
import type { ExtensionUIProtocolRequest } from "./extension-ui-contract.js";
import type {
  ExtensionUINativeSurface,
  ExtensionUISurface,
  ExtensionUISurfaceActionDefinition,
  ExtensionUISurfaceAtom,
  ExtensionUISurfaceCompositeKind,
  ExtensionUISurfaceSection,
  ExtensionUISurfaceState,
  ExtensionUISurfaceStateKind,
  ExtensionUISurfaceTone,
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
// an atom holds nothing. Two containers is the whole shape, so the schema is the cap.
export const EXTENSION_UI_SURFACE_MAX_ACTIONS = 32;
/** Actions a surface accepts per client per minute; beyond it the card shows an error. */
export const EXTENSION_UI_SURFACE_ACTION_RATE_LIMIT = 60;
export const EXTENSION_UI_SURFACE_ACTION_RATE_WINDOW_MS = 60_000;
export const EXTENSION_UI_SURFACE_MAX_TITLE_CHARS = 200;
export const EXTENSION_UI_SURFACE_MAX_FALLBACK_CHARS = 2_000;
export const EXTENSION_UI_SURFACE_MAX_ATOMS = 8;
export const EXTENSION_UI_SURFACE_MAX_SPANS = 320;
export const EXTENSION_UI_SURFACE_COMPOSITES: readonly ExtensionUISurfaceCompositeKind[] = [
  "statusCard",
  "checklist",
  "dataTable",
  "actionBar",
];
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

function section(
  value: unknown,
  actions: Record<string, unknown>,
  limits: SurfaceLimitState,
): ExtensionUISurfaceSection {
  if (!isRecord(value)) throw new SurfaceShapeError("a section is not an object");
  const composite = oneOf(EXTENSION_UI_SURFACE_COMPOSITES, value.composite);
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

  const limits: SurfaceLimitState = { spans: 0 };
  const sections = list(value.sections, EXTENSION_UI_SURFACE_MAX_SECTIONS, "surface sections").map(
    (entry) => section(entry, actions, limits),
  );
  uniqueIds(sections, "composite");

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

/** A patch path addresses an existing array entry by index; it never invents one. */
function arrayIndex(node: readonly unknown[], segment: string): number {
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
  let merged: Record<string, unknown>;
  try {
    merged = JSON.parse(JSON.stringify(surface)) as Record<string, unknown>;
    for (const [path, value] of entries) writePath(merged, patchSegments(path), value);
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
  return (
    normalizeExtensionUINativeSurface({
      version: 1,
      id: `surface:${surface.id}`,
      source: "widget",
      presentation: {
        style: "surfacePanel",
        title: surface.title,
        ...(surface.header.subtitle === undefined ? {} : { subtitle: surface.header.subtitle }),
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
