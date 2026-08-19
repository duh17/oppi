import type {
  ExtensionContext,
  ExtensionFactory,
} from "@earendil-works/pi-coding-agent";
import { Type, type Static } from "typebox";

const RELATED_CUSTOM_TYPE = "oppi-related";
const RELATED_WIDGET_KEY = "related";
const CURRENT_STATE_VERSION = 1;

export type RelatedItemState =
  | "queued"
  | "running"
  | "success"
  | "warning"
  | "error"
  | "inactive";

export type RelatedItem = {
  id: string;
  title: string;
  subtitle?: string;
  detail?: string;
  state?: RelatedItemState;
  href?: string;
};

export type RelatedState = {
  version: 1;
  summary?: string;
  items: RelatedItem[];
};

const RelatedItemStateSchema = Type.Union([
  Type.Literal("queued"),
  Type.Literal("running"),
  Type.Literal("success"),
  Type.Literal("warning"),
  Type.Literal("error"),
  Type.Literal("inactive"),
]);

const RelatedItemSchema = Type.Object({
  id: Type.String({ description: "Stable item id." }),
  title: Type.String({ description: "Display title." }),
  subtitle: Type.Optional(Type.String()),
  detail: Type.Optional(Type.String()),
  state: Type.Optional(RelatedItemStateSchema),
  href: Type.Optional(
    Type.String({
      description: "Real URL only: oppi://session/… or http(s)://.",
    }),
  ),
});

const RelatedItemUpdateSchema = Type.Object({
  id: Type.String({ description: "Item id to patch, or create if missing." }),
  title: Type.Optional(Type.String()),
  subtitle: Type.Optional(Type.String()),
  detail: Type.Optional(Type.String()),
  state: Type.Optional(RelatedItemStateSchema),
  href: Type.Optional(
    Type.String({
      description: "Real URL only: oppi://session/… or http(s)://.",
    }),
  ),
});

const RelatedUpdateParams = Type.Object({
  summary: Type.Optional(
    Type.String({
      description:
        "Replace-on-write markdown summary. Empty string clears. Cite files as [[path|label]].",
    }),
  ),
  items: Type.Optional(
    Type.Array(RelatedItemSchema, {
      description: "Full replace of session/web items.",
    }),
  ),
  itemUpdates: Type.Optional(
    Type.Array(RelatedItemUpdateSchema, {
      description: "Patch items by id. Creates the item when missing.",
    }),
  ),
  clear: Type.Optional(
    Type.Boolean({ description: "Remove the board and widget." }),
  ),
});

const RelatedStatusParams = Type.Object({});

type RelatedUpdateInput = Static<typeof RelatedUpdateParams>;

type NativeActivityRow = {
  id: string;
  title: string;
  subtitle?: string;
  detail?: string;
  state?: RelatedItemState;
  link?: string;
};

type RelatedNativeSurface = {
  version: 1;
  id: string;
  source: "widget";
  presentation: {
    style: "surfacePanel";
    title: string;
    subtitle?: string;
  };
  blocks: Array<
    | { type: "markdown"; id: string; markdown: string }
    | { type: "activityList"; id: string; rows: NativeActivityRow[] }
  >;
  fallback: { lines: string[] };
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function optionalText(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  return value;
}

function isAllowedRelatedHref(href: string): boolean {
  const trimmed = href.trim();
  if (!trimmed) return false;
  if (trimmed.includes("[[") || trimmed.includes("]]")) return false;
  try {
    const url = new URL(trimmed);
    if (url.protocol === "http:" || url.protocol === "https:") return true;
    return (
      url.protocol === "oppi:" &&
      url.hostname === "session" &&
      url.pathname.length > 1
    );
  } catch {
    return false;
  }
}

function assertAllowedHref(href: string): void {
  if (isAllowedRelatedHref(href)) return;
  throw new Error(
    `href must be a real URL (oppi://session/… or http(s)://), not wiki, scheme-less, or oppi-resource-reference: ${href}`,
  );
}

function isRelatedItemState(value: unknown): value is RelatedItemState {
  return (
    value === "queued" ||
    value === "running" ||
    value === "success" ||
    value === "warning" ||
    value === "error" ||
    value === "inactive"
  );
}

function normalizeItem(raw: {
  id: string;
  title: string;
  subtitle?: string;
  detail?: string;
  state?: RelatedItemState;
  href?: string;
}): RelatedItem {
  if (raw.href !== undefined) assertAllowedHref(raw.href);
  const item: RelatedItem = {
    id: raw.id,
    title: raw.title,
  };
  if (raw.subtitle !== undefined) item.subtitle = raw.subtitle;
  if (raw.detail !== undefined) item.detail = raw.detail;
  if (raw.state !== undefined) item.state = raw.state;
  if (raw.href !== undefined) item.href = raw.href.trim();
  return item;
}

function cloneState(state: RelatedState): RelatedState {
  return {
    version: CURRENT_STATE_VERSION,
    ...(state.summary !== undefined ? { summary: state.summary } : {}),
    items: state.items.map((item) => ({ ...item })),
  };
}

function isBoardEmpty(state: RelatedState | undefined): boolean {
  return !state || (!state.summary && state.items.length === 0);
}

function isRelatedEntry(entry: unknown): entry is {
  type: "custom";
  customType: typeof RELATED_CUSTOM_TYPE;
  data?: unknown;
} {
  return (
    isRecord(entry) &&
    entry.type === "custom" &&
    entry.customType === RELATED_CUSTOM_TYPE
  );
}

function decodeStoredItem(value: unknown): RelatedItem | undefined {
  if (!isRecord(value) || typeof value.id !== "string" || typeof value.title !== "string") {
    return undefined;
  }
  const item: RelatedItem = { id: value.id, title: value.title };
  if (typeof value.subtitle === "string") item.subtitle = value.subtitle;
  if (typeof value.detail === "string") item.detail = value.detail;
  if (isRelatedItemState(value.state)) item.state = value.state;
  if (typeof value.href === "string" && isAllowedRelatedHref(value.href)) {
    item.href = value.href.trim();
  }
  return item;
}

function decodeRelatedState(value: unknown): RelatedState | undefined {
  if (!isRecord(value) || value.version !== CURRENT_STATE_VERSION) return undefined;
  if (!Array.isArray(value.items)) return undefined;
  const items = value.items
    .map((item) => decodeStoredItem(item))
    .filter((item): item is RelatedItem => item !== undefined);
  const summary = optionalText(value.summary);
  return {
    version: 1,
    ...(summary ? { summary } : {}),
    items,
  };
}

function latestCompatibleRelatedState(
  entries: readonly unknown[],
): RelatedState | undefined {
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (!isRelatedEntry(entry)) continue;
    const decoded = decodeRelatedState(entry.data);
    if (decoded) return decoded;
  }
  return undefined;
}

function sessionRelatedEntries(ctx: ExtensionContext): readonly unknown[] {
  return ctx.sessionManager.getBranch?.() ?? ctx.sessionManager.getEntries();
}

function applyItemUpdates(
  items: RelatedItem[],
  updates: Static<typeof RelatedItemUpdateSchema>[],
): RelatedItem[] {
  const next = items.map((item) => ({ ...item }));
  for (const update of updates) {
    const index = next.findIndex((item) => item.id === update.id);
    if (index === -1) {
      if (!update.title) {
        throw new Error(
          `itemUpdates create requires title for id ${update.id}`,
        );
      }
      next.push(
        normalizeItem({
          id: update.id,
          title: update.title,
          subtitle: update.subtitle,
          detail: update.detail,
          state: update.state,
          href: update.href,
        }),
      );
      continue;
    }
    const current = next[index];
    next[index] = normalizeItem({
      id: current.id,
      title: update.title ?? current.title,
      subtitle: update.subtitle ?? current.subtitle,
      detail: update.detail ?? current.detail,
      state: update.state ?? current.state,
      href: update.href ?? current.href,
    });
  }
  return next;
}

function renderRelatedLines(state: RelatedState): string[] {
  const lines = ["Related"];
  if (state.summary) {
    const firstLine = state.summary.split("\n")[0]?.trim();
    if (firstLine) lines.push(firstLine);
  }
  for (const item of state.items) {
    lines.push(
      item.subtitle ? `- ${item.title} · ${item.subtitle}` : `- ${item.title}`,
    );
  }
  return lines;
}

function renderRelatedNativeSurface(state: RelatedState): RelatedNativeSurface {
  const blocks: RelatedNativeSurface["blocks"] = [];
  if (state.items.length > 0) {
    blocks.push({
      type: "activityList",
      id: "related-items",
      rows: state.items.map((item) => {
        const row: NativeActivityRow = {
          id: item.id,
          title: item.title,
        };
        if (item.subtitle !== undefined) row.subtitle = item.subtitle;
        if (item.detail !== undefined) row.detail = item.detail;
        if (item.state !== undefined) row.state = item.state;
        if (item.href !== undefined) row.link = item.href;
        return row;
      }),
    });
  }
  if (state.summary) {
    blocks.push({
      type: "markdown",
      id: "related-summary",
      markdown: state.summary,
    });
  }
  return {
    version: 1,
    id: "widget:related",
    source: "widget",
    presentation: {
      style: "surfacePanel",
      title: "Related",
    },
    blocks,
    fallback: { lines: renderRelatedLines(state) },
  };
}

type RelatedToolDetails = RelatedState | { status: "none" };

function noneResult(): {
  content: Array<{ type: "text"; text: string }>;
  details: RelatedToolDetails;
} {
  return {
    content: [{ type: "text", text: "No related work." }],
    details: { status: "none" },
  };
}

function boardResult(state: RelatedState): {
  content: Array<{ type: "text"; text: string }>;
  details: RelatedToolDetails;
} {
  return {
    content: [{ type: "text", text: "Related work board." }],
    details: cloneState(state),
  };
}

export function createRelatedFactory(): ExtensionFactory {
  return (pi) => {
    let state: RelatedState | undefined;

    function persist(): void {
      if (!state) {
        pi.appendEntry(RELATED_CUSTOM_TYPE, {
          version: CURRENT_STATE_VERSION,
          items: [],
        } satisfies RelatedState);
        return;
      }
      pi.appendEntry(RELATED_CUSTOM_TYPE, cloneState(state));
    }

    function clearUi(ctx: ExtensionContext): void {
      if (!ctx.hasUI) return;
      ctx.ui.setWidget(RELATED_WIDGET_KEY, undefined);
    }

    function render(ctx: ExtensionContext): void {
      if (!ctx.hasUI) return;
      if (isBoardEmpty(state) || !state) {
        clearUi(ctx);
        return;
      }
      const lines = renderRelatedLines(state);
      // Plain Pi RPC ignores component factories, so publish the line snapshot first.
      ctx.ui.setWidget(RELATED_WIDGET_KEY, lines, {
        placement: "aboveEditor",
      });
      ctx.ui.setWidget(
        RELATED_WIDGET_KEY,
        () => {
          const snapshot = state;
          return {
            render: () => (snapshot ? renderRelatedLines(snapshot) : []),
            renderNative: () =>
              snapshot ? renderRelatedNativeSurface(snapshot) : undefined,
            invalidate: () => {},
            dispose: () => {},
          };
        },
        { placement: "aboveEditor" },
      );
    }

    function setBoard(
      next: RelatedState | undefined,
      ctx: ExtensionContext,
    ): void {
      state = next && !isBoardEmpty(next) ? cloneState(next) : undefined;
      persist();
      render(ctx);
    }

    function restore(ctx: ExtensionContext): void {
      const restored = latestCompatibleRelatedState(sessionRelatedEntries(ctx));
      state = restored && !isBoardEmpty(restored) ? cloneState(restored) : undefined;
      render(ctx);
    }

    function applyUpdate(
      params: RelatedUpdateInput,
      ctx: ExtensionContext,
    ): RelatedState | undefined {
      if (params.clear) {
        setBoard(undefined, ctx);
        return undefined;
      }

      const current: RelatedState = state
        ? cloneState(state)
        : { version: 1, items: [] };

      if (params.summary !== undefined) {
        const summary = params.summary;
        if (summary === "") {
          delete current.summary;
        } else {
          current.summary = summary;
        }
      }

      if (params.items) {
        current.items = params.items.map((item) => normalizeItem(item));
      }

      if (params.itemUpdates) {
        current.items = applyItemUpdates(current.items, params.itemUpdates);
      }

      setBoard(current, ctx);
      return state;
    }

    pi.registerTool({
      name: "related_update",
      label: "Related Update",
      description:
        "Create or update the related-work board: replace-on-write summary plus session/web items.",
      promptSnippet:
        "Publish a related-work board when the user should see related sessions, files, or web pages. Do not use this for ordinary work.",
      promptGuidelines: [
        "Use related_update to create or replace the board. related_status reads it.",
        "Write the summary yourself in markdown. Cite files as [[path|label]] and web pages as https URLs.",
        "Put sessions and web pages in items with a real href: oppi://session/<id> or http(s)://.",
        "Never put wiki links, scheme-less paths, or oppi-resource-reference URLs in href.",
        "Use clear to remove the board and widget.",
      ],
      parameters: RelatedUpdateParams,
      async execute(_toolCallId, params: RelatedUpdateInput, _signal, _onUpdate, ctx) {
        const next = applyUpdate(params, ctx);
        return next ? boardResult(next) : noneResult();
      },
    });

    pi.registerTool({
      name: "related_status",
      label: "Related Status",
      description: "Read the current related-work board.",
      parameters: RelatedStatusParams,
      async execute() {
        return state ? boardResult(state) : noneResult();
      },
    });

    pi.registerCommand("related", {
      description: "Show or clear the related-work board",
      handler: async (args, ctx) => {
        if (args.trim().toLowerCase() === "clear") {
          setBoard(undefined, ctx);
        } else if (ctx.hasUI) {
          render(ctx);
        }
      },
    });

    pi.on("session_start", (_event, ctx) => restore(ctx));
  };
}

export default createRelatedFactory();
