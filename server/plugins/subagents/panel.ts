import type { Context } from "@earendil-works/chord/context";
import {
  badge,
  blocks,
  button,
  elapsed,
  group,
  icon,
  markdown,
  pill,
  row,
  stack,
  surface,
  text,
  type Surface,
  type SurfaceConversation,
  type SurfaceView,
} from "oppi/v1";
import { SubagentDismissals, SubagentPill } from "./contract.js";
import {
  ANSWER_EXCERPT_MAX,
  EARLIER_EXCERPT_MAX,
  applyDismissals,
  cutMarkdown,
  isLive,
  jsonBytes,
  renderSubagentTerminal,
  rowDetail,
  rowMetaLine,
  rowNote,
  sessionLink,
  subagentGroups,
  threadLink,
  widgetChrome,
  type Subagent,
} from "./subagents.js";

// The durable subagents pill: a composable surface (`surface()`) whose rows are the children the
// watcher follows, with a Dismiss action on every failed one and Clear failed when more than one
// fails. Dismiss hides a failure without stopping or touching the child's Session: the row leaves
// Needs You for Recent, and returns to Needs You only when a later run of that child fails again.
//
// Nothing here holds state between draws. `load` reads two documents — the rows the watcher wrote
// and the dismissals these actions wrote — so the panel comes back by itself when a chat attaches,
// after a server restart too (`defineExtension({ surfaces })`), and a tap's answer and the next
// attach agree. One panel object serves every chat: Oppi keeps what each chat's surface loop was
// shown apart (`ctx.surfaces`).

export const PANEL_ID = "subagents";
/** One child's failure, dismissed. Values: `child`, the child Session id (its row's id). */
export const DISMISS = "dismiss";
/** Every failure dismissed at once. Offered while `CLEAR_FROM` children fail. */
export const CLEAR_FAILED = "clear-failed";
/** How many failures make Clear failed worth a control: one is dismissed on its own row. */
const CLEAR_FROM = 2;

/** The server's limits for a surface (docs/extension-native-ui.md, Limits): over one it is dropped. */
const SURFACE_NODES = 300;
const SURFACE_BYTES = 64 * 1024;
/** A node's words are at most this many characters, so one answer can span several nodes. */
const NODE_CHARS = 500;
/**
 * Room kept for what the row budget does not measure child by child: the section headings, the
 * Clear failed button, the Earlier fold, the overflow row, the header, and the pill.
 */
const RESERVE_NODES = 24;
const RESERVE_BYTES = 2_048;
/** One node of a blocks tree, as the builders return it. */
type SurfaceNode = ReturnType<typeof row>;

/** The most children any layout node holds (docs/extension-native-ui.md, Limits). */
const NODE_CHILDREN = 12;
/** The body keeps one of its slots for the overflow row. */
const BODY_CHILDREN = NODE_CHILDREN - 1;
/** The surface's own fallback is capped at 2,000 characters on the wire. */
const FALLBACK_CHARS = 1_900;

/** What the panel draws: the watcher's rows, with the owner's dismissals applied. */
export interface SubagentPanelState {
  rows: Subagent[];
  /** Where `N more in Thread` opens: the parent's own Session, once the watcher knows it. */
  threadSessionId?: string;
}

/** A drawn panel, and the children it drew (what the watcher keeps current). */
export interface SubagentSurface {
  view: SurfaceView;
  /** Ids of the children drawn as rows. */
  shown: Set<string>;
  /** Ids of the children whose row keeps the long answer in the watcher's checkpoint. */
  full: Set<string>;
}

/**
 * The panel's state for one chat, read from its documents: the watcher's rows with the dismissed
 * failures no longer needing you. Nothing live, no panel: the next draw ends it.
 */
export async function loadPanel(
  conversation: SurfaceConversation,
  context: Context,
): Promise<SubagentPanelState | undefined> {
  const id = conversation.conversationId;
  const [pill, dismissals] = await Promise.all([
    conversation.snapshot(SubagentPill, id, context),
    conversation.snapshot(SubagentDismissals, id, context),
  ]);
  return panelState(pill?.rows ?? [], pill?.threadSessionId, dismissals?.dismissed ?? {});
}

export function panelState(
  rows: readonly Subagent[],
  threadSessionId: string | undefined,
  dismissed: Readonly<Record<string, number>>,
): SubagentPanelState | undefined {
  const shown = applyDismissals(rows, dismissed);
  return shown.some(isLive)
    ? { rows: shown, ...(threadSessionId ? { threadSessionId } : {}) }
    : undefined;
}

/** A row's state mark: Oppi's working mark while it works, its answer's tone when it is done. */
type Mark = {
  name: string;
  tone: "neutral" | "accent" | "success" | "warning" | "danger";
};

const MARKS: Record<Subagent["state"], Mark> = {
  error: { name: "xmark.circle.fill", tone: "danger" },
  warning: { name: "exclamationmark.circle", tone: "warning" },
  running: { name: "working", tone: "accent" },
  success: { name: "checkmark.circle.fill", tone: "success" },
};

function mark(item: Subagent): Mark {
  // A child that finished by a stop, or a failure the owner dismissed: nothing to report.
  if (item.state === "success" && (item.dismissed || item.stopped))
    return { name: "minus.circle", tone: "neutral" };
  return MARKS[item.state];
}

/**
 * The one thing wrong, in the pill: `4 failed`, `1 needs you`, `2 working`. One failure reads as
 * `1 failed`, and the drawer's subtitle has the rest of the count.
 */
function pillBadge(rows: readonly Subagent[]): string | undefined {
  const failed = rows.filter((item) => item.state === "error").length;
  if (failed > 0) return `${failed} failed`;
  const asking = rows.filter((item) => item.state === "warning").length;
  if (asking > 0) return asking === 1 ? "1 needs you" : `${asking} need you`;
  const working = rows.filter((item) => item.state === "running").length;
  return working > 0 ? `${working} working` : undefined;
}

/** The most urgent state of the whole panel: what the pill's own mark says before a word is read. */
function panelMark(rows: readonly Subagent[]): Mark {
  for (const state of ["error", "warning", "running"] as const)
    if (rows.some((item) => item.state === state)) return MARKS[state];
  return MARKS.success;
}

function nodeCount(node: unknown): number {
  if (!node || typeof node !== "object") return 0;
  const record = node as { children?: unknown[]; items?: unknown[] };
  const children = (record.children ?? []) as unknown[];
  const items = (record.items ?? []) as unknown[];
  return 1 + children.reduce((sum: number, child) => sum + nodeCount(child), 0) + items.length;
}

/** One child's row: its mark, its name, how long it has been in this state, and its Dismiss. */
function childRow(item: Subagent, dismissible: boolean): ReturnType<typeof stack> {
  const state = mark(item);
  const note = rowNote(item);
  const detail = rowDetail(item);
  // Its name and Dismiss share one line; the time it has been in this state sits with its model
  // and spend, so a row reads as two lines and a long name takes no room from the control.
  const facts: ReturnType<typeof row>[] = [
    ...(item.since !== undefined
      ? [elapsed({ id: `time:${item.id}`, since: item.since, format: "short", style: "caption" })]
      : []),
    // The count and the model are two facts, not one phrase.
    ...(item.since !== undefined && detail
      ? [text({ id: `dot:${item.id}`, text: "\u00b7", style: "caption" })]
      : []),
    ...(detail ? [text({ id: `detail:${item.id}`, text: detail, style: "caption" })] : []),
  ];
  const children: ReturnType<typeof row>[] = [
    row({
      id: `head:${item.id}`,
      spacing: "tight",
      // The row opens the child, as an activity row's link does; controls inside keep their touch.
      link: sessionLink(item.id),
      children: [
        icon({ id: `mark:${item.id}`, name: state.name, tone: state.tone }),
        text({ id: `title:${item.id}`, text: item.title, style: "headline" }),
        ...(dismissible
          ? [
              button({
                id: `dismiss:${item.id}`,
                title: "Dismiss",
                role: "secondary" as const,
                action: {
                  id: DISMISS,
                  values: { child: item.id, ended: item.finishedAt ?? 0 },
                },
              }),
            ]
          : []),
      ],
    }),
    ...(note ? [text({ id: `note:${item.id}`, text: note, style: "caption" })] : []),
    ...(facts.length > 0
      ? [row({ id: `facts:${item.id}`, spacing: "tight", children: facts })]
      : []),
  ];
  return stack({ id: `child:${item.id}`, spacing: "tight", children });
}

/**
 * A child's answer behind one fold: its text in `markdown` nodes of at most a node's words each, and
 * the line of its full model, spend, and worktree under it. Nil when the child has no answer.
 */
function answerNodes(item: Subagent, cap: number): ReturnType<typeof group>[] | undefined {
  if (!item.answer) return undefined;
  const meta = rowMetaLine(item);
  const body = markdownChunks(cutMarkdown(item.answer, cap));
  return [
    group({
      id: `answer:${item.id}`,
      title: "Answer",
      collapsed: true,
      children: [
        ...body.map((chunk, index) =>
          markdown({ id: `answer:${item.id}:${index}`, markdown: chunk }),
        ),
        ...(meta ? [text({ id: `meta:${item.id}`, text: meta, style: "caption" })] : []),
      ],
    }),
  ];
}

/** `text` in pieces of at most a node's words, cut at a line or word end when one is near. */
export function markdownChunks(text: string): string[] {
  const chars = Array.from(text);
  const chunks: string[] = [];
  let rest = chars;
  while (rest.length > NODE_CHARS) {
    const window = rest.slice(0, NODE_CHARS).join("");
    const end = Math.max(window.lastIndexOf("\n"), window.lastIndexOf(" "));
    const cut = end > NODE_CHARS * 0.6 ? end : NODE_CHARS;
    chunks.push(rest.slice(0, cut).join(""));
    rest = rest.slice(cut);
  }
  if (rest.length > 0) chunks.push(rest.join(""));
  return chunks;
}

/**
 * The panel's body, under the server's limits: every child's row first, in section order (seeing
 * each child comes before reading any answer), then answers with the room left — in full for those
 * that need you and those that just finished, a glance at a working child's and at an Earlier one's.
 * Children that do not fit are counted in a last row that opens the whole thread.
 */
export function subagentView(state: SubagentPanelState): SubagentSurface {
  const groups = subagentGroups(state.rows);
  const budget = { nodes: SURFACE_NODES - RESERVE_NODES, bytes: SURFACE_BYTES - RESERVE_BYTES };
  const charge = (nodes: number, bytes: number): boolean => {
    if (nodes > budget.nodes || bytes > budget.bytes) return false;
    budget.nodes -= nodes;
    budget.bytes -= bytes;
    return true;
  };
  /** Charge one node list whole, or nothing. */
  const take = (nodes: unknown[]): boolean =>
    charge(
      nodes.reduce((sum: number, node) => sum + nodeCount(node), 0),
      jsonBytes(nodes),
    );

  // A row for every child that fits, in the panel's order.
  const taken = new Map<Subagent, ReturnType<typeof stack>[]>();
  const order = [...groups["needs-you"], ...groups.working, ...groups.recent, ...groups.earlier];
  for (const item of order) {
    const nodes = [childRow(item, item.state === "error")];
    if (!take(nodes)) break;
    taken.set(item, nodes);
  }
  // Then answers with the room left: full for Needs You and Recent, a glance at the others.
  const answers: Array<[Subagent[], number]> = [
    [groups["needs-you"], ANSWER_EXCERPT_MAX],
    [groups.recent, ANSWER_EXCERPT_MAX],
    [groups.working, EARLIER_EXCERPT_MAX],
    [groups.earlier, EARLIER_EXCERPT_MAX],
  ];
  for (const [items, cap] of answers)
    for (const item of items) {
      const nodes = taken.get(item);
      if (!nodes) continue;
      const answer = answerNodes(item, cap);
      if (!answer || !take(answer)) continue;
      nodes.push(...answer);
    }

  const failed = groups["needs-you"].filter((item) => item.state === "error").length;
  // A layout node holds 12 children (the protocol's cap): a section is a stack of at most that,
  // and one that overflows continues in a sibling stack. The body is one too, and keeps its last
  // slot for the overflow row.
  const body: ReturnType<typeof stack>[] = [];
  const bodyCap = BODY_CHILDREN;
  const add = (node: ReturnType<typeof stack>): boolean => {
    if (body.length >= bodyCap) return false;
    body.push(node);
    return true;
  };
  /**
   * `items`' nodes into stacks under `title`, in the panel's order, each holding ≤12 children.
   * `alongside` is drawn at the heading's trailing edge, as the section's own control.
   */
  const section = (id: string, title: string, items: Subagent[], alongside?: SurfaceNode): void => {
    const nodes: SurfaceNode[] = items.flatMap((item) => taken.get(item) ?? []);
    const heading = (part: number): SurfaceNode[] => {
      if (part > 0) return [];
      const title_ = text({ id: `section:${id}:title`, text: title, style: "caption" });
      return [
        alongside
          ? row({
              id: `section:${id}:heading`,
              align: "spread",
              spacing: "tight",
              children: [title_, alongside],
            })
          : title_,
      ];
    };
    let index = 0;
    for (let part = 0; index < nodes.length || part === 0; part += 1) {
      const head = heading(part);
      const slice = nodes.slice(index, index + NODE_CHILDREN - head.length);
      if (
        !add(
          stack({
            id: part === 0 ? `section:${id}` : `section:${id}:${part}`,
            spacing: "tight",
            children: [...head, ...slice],
          }),
        )
      )
        return;
      index += NODE_CHILDREN - head.length;
    }
  };
  if (groups["needs-you"].length > 0)
    section(
      "needs-you",
      "Needs You",
      groups["needs-you"],
      // One failure is dismissed on its row; two or more, at once, from the section's heading.
      failed >= CLEAR_FROM
        ? button({
            id: "clear-failed:button",
            title: "Clear failed",
            role: "secondary",
            action: { id: CLEAR_FAILED },
          })
        : undefined,
    );
  if (groups.working.length > 0) section("working", "Working", groups.working);
  if (groups.recent.length > 0) section("recent", "Recent", groups.recent);
  const earlier = groups.earlier.flatMap((item) => taken.get(item) ?? []);
  if (earlier.length > 0) {
    // One fold for everything older, so the drawer stays short until someone opens it. A fold
    // holds 12 children too, so more than that take a second fold.
    add(text({ id: "section:earlier:title", text: "Earlier", style: "caption" }));
    for (let index = 0; index < earlier.length; index += NODE_CHILDREN) {
      const placed = add(
        group({
          id: index === 0 ? "earlier:group" : `earlier:group:${index}`,
          title: `${groups.earlier.length} finished`,
          collapsed: true,
          children: earlier.slice(index, index + NODE_CHILDREN),
        }),
      );
      if (!placed) break;
    }
  }

  // What the drawer really shows: a body that ran out of room leaves its rest to the row below.
  const shown = new Set<string>();
  const collect = (node: SurfaceNode): void => {
    if (typeof node.id === "string" && node.id.startsWith("child:"))
      shown.add(node.id.slice("child:".length));
    for (const child of "children" in node ? node.children : []) collect(child);
  };
  for (const node of body) collect(node);
  const hidden = state.rows.length - shown.size;
  if (hidden > 0)
    body.push(
      row({
        id: "more",
        ...(state.threadSessionId ? { link: threadLink(state.threadSessionId) } : {}),
        children: [
          text({
            id: "more:text",
            text: state.threadSessionId ? `${hidden} more in Thread` : `${hidden} more`,
          }),
        ],
      }),
    );

  const chrome = widgetChrome(state.rows);
  const state_ = panelMark(state.rows);
  // A pill is one line: its badge is the one thing wrong, short enough never to wrap, and the
  // drawer's subtitle carries the whole count.
  const badge_ = pillBadge(state.rows);
  return {
    view: {
      header: { title: chrome.title, ...(chrome.subtitle ? { subtitle: chrome.subtitle } : {}) },
      pill: pill({
        content: [
          icon({ id: "pill:mark", name: state_.name, tone: state_.tone }),
          text({ id: "pill:title", text: chrome.title, style: "headline" }),
          ...(badge_
            ? [
                badge({
                  id: "pill:count",
                  text: badge_,
                  tone: state_.tone === "neutral" ? "accent" : state_.tone,
                }),
              ]
            : []),
        ],
      }),
      sections: [
        blocks({
          id: PANEL_ID,
          fallback: fallbackText(state.rows),
          body: stack({ id: "list", spacing: "normal", children: body }),
        }),
      ],
    },
    shown,
    // What the watcher's checkpoint keeps whole: a child whose row is not folded into Earlier.
    full: new Set(
      [...groups["needs-you"], ...groups.working, ...groups.recent].map((item) => item.id),
    ),
  };
}

/** What an older client shows instead: the terminal band the pill draws in a terminal. */
function fallbackText(rows: readonly Subagent[]): string {
  const band = renderSubagentTerminal([...rows]).join("\n");
  return band.length > FALLBACK_CHARS ? `${band.slice(0, FALLBACK_CHARS - 1)}\u2026` : band;
}

/** The panel: one object for every chat, drawn from that chat's rows and dismissals. */
export const panel: Surface<SubagentPanelState> = surface<SubagentPanelState>({
  id: PANEL_ID,
  title: "Subagents",
  // A list of rows: a pane shows it at the width a list wants.
  panel: { icon: "person.2", size: "regular" },
  actions: {
    [DISMISS]: { title: "Dismiss", role: "secondary", pending: { title: "Dismissing\u2026" } },
    [CLEAR_FAILED]: {
      title: "Clear failed",
      role: "secondary",
      pending: { title: "Clearing\u2026" },
    },
  },
  fallback: (state) => fallbackText(state.rows),
  load: loadPanel,
  view: (state) => subagentView(state).view,
});

/**
 * Save failures as dismissed, in one commit: the child's own Session is untouched. `ended` is when
 * that failure's run ended, so a run that ends later still needs you; there is no wall clock here,
 * which a tap could not tell from a later failure.
 */
async function dismiss(
  conversation: SurfaceConversation,
  ended: ReadonlyMap<string, number>,
  context: Context,
): Promise<void> {
  if (ended.size === 0) return;
  await conversation.commit(async (tx) => {
    const state = await tx.doc(SubagentDismissals, conversation.conversationId);
    for (const [child, at] of ended) state.dismissed[child] = at;
  }, context);
}

panel.action(DISMISS, async (state, { values, conversation, context, ctx }) => {
  const child = typeof values?.child === "string" ? values.child : undefined;
  // Only a child that is failing under Needs You right now: a tap that outlived its row does
  // nothing, rather than hiding a failure the drawer no longer shows.
  const row = state.rows.find((item) => item.id === child && item.state === "error");
  const ended = typeof values?.ended === "number" ? values.ended : undefined;
  if (row) await dismiss(conversation, new Map([[row.id, row.finishedAt ?? ended ?? 0]]), context);
  await panel.sync(ctx, context);
});

panel.action(CLEAR_FAILED, async (state, { conversation, context, ctx }) => {
  const failed = state.rows.filter((row) => row.state === "error");
  await dismiss(conversation, new Map(failed.map((row) => [row.id, row.finishedAt ?? 0])), context);
  await panel.sync(ctx, context);
});
