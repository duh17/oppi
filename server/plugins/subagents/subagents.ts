/**
 * Subagents launched by this parent.
 *
 * The set is the create results this session saw. Status updates come from
 * `oppi session wait`; a one-time `oppi session get <id>` snapshot fills in
 * the model. There is no children list API.
 */

export type Subagent = {
  id: string;
  parentId?: string;
  title: string;
  subtitle: string;
  link: string;
  /**
   * `warning` asks a question, `error` failed and was not stopped since: both need you.
   * `running` works or waits on work of its own. `success` is finished.
   */
  state: "running" | "success" | "warning" | "error";
  /** Finished by a stop: its run was aborted, or its failure dismissed with Stop. */
  stopped?: boolean;
  /**
   * A failure the owner dismissed from the pill: the child is untouched, the row no longer needs
   * you, and it comes back only when a later run of the child fails again.
   */
  dismissed?: boolean;
  model?: string;
  thinking?: string;
  /** What the row says on its second line: the step, the question, the wait, the error, the answer. */
  activity?: string;
  /** Epoch ms the current state began: the question opened, the run started, the run failed. */
  since?: number;
  /** A finished child's newest run, start to end, in ms. */
  took?: number;
  /** When its newest run ended, epoch ms: the order of Recent. */
  finishedAt?: number;
  /** Spend so far, in dollars. */
  cost?: number;
  /**
   * The worktree it works in, as of its newest report. `branch` only when it is not the one the
   * spawn named after the child: the title already says that one.
   */
  worktree?: { branch?: string; ahead?: number; dirty?: boolean };
  /**
   * Its newest answer as Markdown (or the error that ended its run), already cut to at most
   * `ANSWER_EXCERPT_MAX` characters: what its row's disclosure shows.
   */
  answer?: string;
};

export interface SubagentRow {
  id: string;
  title: string;
  subtitle?: string;
  detail?: string;
  /** `inactive`: a child finished by a stop. The Earlier and thread rows have no state. */
  state?: Subagent["state"] | "inactive";
  link?: string;
  since?: number;
  /**
   * A disclosure row's content: a child's answer and details as Markdown, or, on the Earlier row,
   * the list of earlier children.
   */
  blocks?: [SubagentMarkdown] | [SubagentList];
}

export interface SubagentMarkdown {
  type: "markdown";
  id: string;
  markdown: string;
}

export interface SubagentList {
  type: "activityList";
  id: string;
  rows: SubagentRow[];
}

/** A titled group of rows, as the native surface's `section` block holding an `activityList`. */
export interface SubagentSection {
  type: "section";
  id: string;
  title: string;
  blocks: [SubagentList];
}

export interface WidgetChrome {
  title: string;
  subtitle?: string;
}

/** The pill's body: its sections, the text fallback, and which children have a row. */
export interface SubagentPanel {
  chrome: WidgetChrome;
  sections: SubagentSection[];
  fallback: string[];
  /** Ids of the children drawn as rows. */
  shown: Set<string>;
}

/** Most live children (asking, failed, working) the terminal band shows as rows. */
export const MAX_PILL_ROWS = 8;
/** Finished children listed under Recent, newest first. */
export const MAX_RECENT_ROWS = 3;
/** Longest answer, in characters, a live or Recent row's disclosure shows. */
export const ANSWER_EXCERPT_MAX = 1500;
/** Longest answer an Earlier row's disclosure shows: a glance; the session has the rest. */
export const EARLIER_EXCERPT_MAX = 240;

/**
 * The server's native-surface limits (docs/extension-native-ui.md, Limits): it drops a surface
 * over any of them, so the panel is built under them. Text counts every string in the surface.
 */
const SURFACE_TEXT_BYTES = 32 * 1024;
const SURFACE_BYTES = 64 * 1024;
const SURFACE_BLOCKS = 80;
const SURFACE_ROWS = 160;
/**
 * Room kept for what the budget does not measure row by row: the surface's id and presentation,
 * the sections and their lists, the Earlier row, and the thread row.
 */
const SURFACE_RESERVE_TEXT = 1024;
const SURFACE_RESERVE_BYTES = 2048;

export function sessionLink(sessionId: string, workspaceId?: string): string {
  const url = `oppi://session/${sessionId}`;
  return workspaceId ? `${url}?workspaceId=${encodeURIComponent(workspaceId)}` : url;
}

/** The session list with `sessionId`'s thread open: where the children the pill cannot fit are. */
export function threadLink(sessionId: string): string {
  return `oppi://thread/${sessionId}`;
}

export function applyGet(known: Subagent, payload: unknown): Subagent | null {
  const data = envelopeData(payload);
  const session = asRecord(data?.session) ?? data;
  if (!session) return known;
  const id = stringField(session, "id");
  if (id && id !== known.id) return known;
  const launch = asRecord(session.launch);
  const parent = stringField(launch, "parentSessionId");
  if (parent && parent !== known.parentId) return null;
  const refreshed = subagentFromSession(session, known.id, known.parentId);
  const name = stringField(session, "name") ?? known.title;
  return {
    ...known,
    ...refreshed,
    title: titledWithAgent(name, asRecord(launch)?.agentIcon),
    state: mergePolledState(known.state, refreshed.state),
    model: refreshed.model ?? known.model,
  };
}

export function sessionIdFromCreateOutput(text: string): string | undefined {
  return subagentFromCreate("oppi session create --json", text)?.id;
}

export function childStatusFromGet(payload: unknown): {
  id?: string;
  status?: string;
  name?: string;
  lastMessage?: string;
  parentId?: string;
  workspaceId?: string;
} | null {
  const session = sessionRecord(payload);
  if (!session) return null;
  const launch = asRecord(session.launch);
  return {
    id: stringField(session, "id"),
    status: stringField(session, "status"),
    name: stringField(session, "name"),
    lastMessage: stringField(session, "lastMessage"),
    parentId: stringField(launch, "parentSessionId"),
    workspaceId: stringField(session, "workspaceId"),
  };
}

export function subagentFromCreate(
  command: string,
  text: string,
  parentId?: string,
): Subagent | null {
  if (!/\boppi\s+session\s+create\b/.test(command)) return null;
  const data = createEnvelope(text);
  const id = stringField(data, "session_id") ?? stringField(data, "sessionId");
  if (!id || id === parentId) return null;
  const name = flag(command, "name") ?? shortId(id);
  const model = flag(command, "model");
  return {
    id,
    parentId,
    title: name,
    subtitle: shortId(id),
    link: sessionLink(id),
    state: "running",
    ...(model ? { model } : {}),
  };
}

/**
 * A get that failed because the session is gone (deleted). The CLI's JSON error is
 * `{ ok: false, error: { message, status?, code? } }`: its own prefix lookup says
 * `session_not_found`; the server's route says 404 with `Session not found: <id>`. Another
 * 404 (a workspace that is gone) says nothing about the session.
 */
export function isMissingSession(payload: unknown): boolean {
  const record = asRecord(payload);
  if (record?.ok !== false) return false;
  const error = asRecord(record.error);
  if (error?.code === "session_not_found") return true;
  return (
    error?.status === 404 &&
    typeof error.message === "string" &&
    error.message.startsWith("Session not found")
  );
}

/** The Oppi session that launched the child a get describes: the thread its pill row opens. */
export function launcherFromGet(payload: unknown): string | undefined {
  return childStatusFromGet(payload)?.parentId;
}

/** `missing` are launched ids whose session is gone; they leave the set. */
export function refreshLaunched(
  launched: Subagent[],
  gets: unknown[],
  missing: string[] = [],
): Subagent[] {
  const byId = new Map(launched.map((item) => [item.id, item]));
  for (const id of missing) byId.delete(id);
  for (const payload of gets) {
    for (const [id, known] of byId) {
      const session = sessionRecord(payload);
      if (stringField(session, "id") !== id) continue;
      const next = applyGet(known, payload);
      if (next) byId.set(id, next);
      else byId.delete(id);
    }
  }
  return [...byId.values()];
}

export function withStatuses(
  rows: Subagent[],
  updates: Array<{ id: string; status?: string; pendingWake?: boolean }>,
): Subagent[] {
  const byId = new Map(updates.map((item) => [item.id, item]));
  return rows.map((row) => {
    const update = byId.get(row.id);
    if (!update?.status) return row;
    return { ...row, state: stateFromStatus(update.status, update.pendingWake) };
  });
}

export function applyWaitReading(
  rows: Subagent[],
  reading: {
    settled: Array<{ id: string; status?: string; pendingWake?: boolean }>;
    attention: Array<{ id: string }>;
    running: Array<{ id: string; status?: string; pendingWake?: boolean }>;
  },
): Subagent[] {
  const byId = new Map<string, Subagent["state"]>();
  for (const record of reading.running)
    byId.set(record.id, stateFromStatus(record.status, record.pendingWake));
  for (const record of reading.settled)
    byId.set(record.id, stateFromStatus(record.status, record.pendingWake));
  for (const record of reading.attention) byId.set(record.id, "warning");
  return rows.map((row) => {
    const state = byId.get(row.id);
    return state ? { ...row, state } : row;
  });
}

export function statusLabel(state: Subagent["state"]): string {
  switch (state) {
    case "running":
      return "Working";
    case "success":
      return "Done";
    case "warning":
      return "Needs attention";
    case "error":
      return "Error";
  }
}

export function rowFallback(row: SubagentRow): string {
  return [row.title, row.subtitle, row.detail, row.link].filter(Boolean).join(" ");
}

export interface SubagentTerminalStyle {
  accent: (text: string) => string;
  success: (text: string) => string;
  warning: (text: string) => string;
  error: (text: string) => string;
  dim: (text: string) => string;
  title: (text: string) => string;
  rule: (text: string) => string;
  bold: (text: string) => string;
}

const plainTerminalStyle: SubagentTerminalStyle = {
  accent: (text) => text,
  success: (text) => text,
  warning: (text) => text,
  error: (text) => text,
  dim: (text) => text,
  title: (text) => text,
  rule: (text) => text,
  bold: (text) => text,
};

const TERMINAL_PREFIX_WIDTH = 4;
const SHORT_MODEL_META_WIDTH = 10;
const SHORT_STATUS_SPREAD = 3;

/**
 * Terminal band for the same children the phone draws as an activity list.
 * A narrow pane keeps the state and the name, then the model.
 * The session URL stays off the line; the phone row still carries the link.
 */
export function renderSubagentTerminal(
  subagents: Subagent[],
  options: { width?: number; style?: SubagentTerminalStyle } = {},
): string[] {
  if (subagents.length === 0) return [];
  const style = options.style ?? plainTerminalStyle;
  const width = options.width;
  const specs = selectPillRows(subagents).map(terminalSpec);
  const nameCol = terminalNameColumn(specs, width);
  const statusCol = terminalStatusColumn(specs, width, nameCol);
  return [
    paintTerminalLine(headerPieces(subagents, width), style),
    ...specs.map((spec) => paintTerminalLine(rowPieces(spec, width, nameCol, statusCol), style)),
  ];
}

/** Asks a question or failed: the child waits on you. */
export function needsYou(item: Subagent): boolean {
  return item.state === "warning" || item.state === "error";
}

/** Needs you or works: what keeps the pill on screen. */
export function isLive(item: Subagent): boolean {
  return item.state !== "success";
}

/**
 * The children the terminal band draws as rows (and the text fallback lists, and the reference
 * extension refreshes first), from every child, newest first: those that need you, the
 * oldest question or failure first; then the working ones, the oldest run first, so a row does
 * not move while it works; up to `max` of those. Then the newest `MAX_RECENT_ROWS` finished, by
 * when they finished. A child without times keeps the order it came in.
 */
export function selectPillRows(subagents: Subagent[], max = MAX_PILL_ROWS): Subagent[] {
  const oldestFirst = (a: Subagent, b: Subagent): number =>
    (a.since ?? Number.POSITIVE_INFINITY) - (b.since ?? Number.POSITIVE_INFINITY);
  // Array.prototype.sort is stable: children without a time keep their order.
  const live = [
    ...subagents.filter(needsYou).sort(oldestFirst),
    ...subagents.filter((item) => item.state === "running").sort(oldestFirst),
  ].slice(0, max);
  const recent = subagents
    .filter((item) => !isLive(item))
    .sort((a, b) => (b.finishedAt ?? 0) - (a.finishedAt ?? 0))
    .slice(0, MAX_RECENT_ROWS);
  return [...live, ...recent];
}

/** The children of one parent, grouped by which section of the pill draws them. */
export interface SubagentGroups {
  /** Asking a question or failed: they wait on you, the oldest first. */
  "needs-you": Subagent[];
  /** Working, the oldest run first, so a row does not move while it works. */
  working: Subagent[];
  /** The `MAX_RECENT_ROWS` newest finished children, newest first. */
  recent: Subagent[];
  /** Every other finished child, newest first. */
  earlier: Subagent[];
}

/**
 * One child's place in the pill: Needs You (the oldest question or failure first), Working (the
 * oldest run first), Recent (the newest finished), and Earlier (the rest). Both the version 1
 * widget and the composable surface order their rows by this, so the two never disagree.
 */
export function subagentGroups(subagents: Subagent[]): SubagentGroups {
  const oldestFirst = (a: Subagent, b: Subagent): number =>
    (a.since ?? Number.POSITIVE_INFINITY) - (b.since ?? Number.POSITIVE_INFINITY);
  // Array.prototype.sort is stable: children without a time keep their order.
  const finished = subagents
    .filter((item) => !isLive(item))
    .sort((a, b) => (b.finishedAt ?? 0) - (a.finishedAt ?? 0));
  return {
    "needs-you": subagents.filter(needsYou).sort(oldestFirst),
    working: subagents.filter((item) => item.state === "running").sort(oldestFirst),
    recent: finished.slice(0, MAX_RECENT_ROWS),
    earlier: finished.slice(MAX_RECENT_ROWS),
  };
}

/**
 * `rows` with the failures the owner dismissed no longer needing you: a dismissed child reads as
 * finished, under Recent or Earlier, and its Session is untouched. Its error stays on the row, as
 * it does for any failure, and its time stops: a finished row has no count to tick. A run that
 * ended after the dismissal failed again, so that row needs you again.
 */
export function applyDismissals(
  rows: readonly Subagent[],
  dismissed: Readonly<Record<string, number>>,
): Subagent[] {
  return rows.map((row) => {
    const at = dismissed[row.id];
    if (at === undefined || row.state !== "error" || (row.finishedAt ?? 0) > at) return row;
    const { since: _since, ...finished } = row;
    return { ...finished, state: "success" as const, dismissed: true };
  });
}

/**
 * The pill's body, every child: Needs You (the oldest question or failure first), Working (the
 * oldest run first), Recent (the `MAX_RECENT_ROWS` newest finished), and Earlier (every other
 * finished child, newest first), leaving out an empty section. Earlier is one disclosure row that
 * holds their rows, so the drawer stays as short as before until someone opens it.
 *
 * Each child's row is a disclosure row (its answer, its current step while it works, and its
 * model, spend, and worktree) that keeps its link to the session. The surface is built under the
 * server's limits, which drop an over-limit surface whole: children are taken in that order while
 * their rows fit, and answers then get the room left, live and Recent ones first. Children that do
 * not fit are counted in a last row, `N more in Thread`, that opens the whole thread.
 */
export function subagentPanel(subagents: Subagent[], threadSessionId?: string): SubagentPanel {
  const groups = subagentGroups(subagents);

  // The fallback is the terminal band's rows: it does not grow with the thread.
  const fallback = subagentRows(selectPillRows(subagents)).map(rowFallback);
  const fallbackCost = { text: textBytes(fallback), bytes: jsonBytes(fallback) };
  // Four sections with their lists, the Earlier row and its list, and the thread row.
  const left = {
    text: SURFACE_TEXT_BYTES - SURFACE_RESERVE_TEXT - fallbackCost.text,
    bytes: SURFACE_BYTES - SURFACE_RESERVE_BYTES - fallbackCost.bytes,
    blocks: SURFACE_BLOCKS - 4 * 2 - 1,
    rows: SURFACE_ROWS - 2,
  };
  const fits = (row: SubagentRow): boolean =>
    textBytes(row) <= left.text && jsonBytes(row) <= left.bytes;
  const spend = (row: SubagentRow, sign: 1 | -1): void => {
    left.text -= sign * textBytes(row);
    left.bytes -= sign * jsonBytes(row);
    left.blocks -= sign;
    left.rows -= sign;
  };
  /** `item`'s row with the longest cut of its answer, up to `cap`, that fits; else none. */
  const withAnswer = (item: Subagent, cap: number): SubagentRow | undefined => {
    const answer = item.answer;
    if (!answer) return undefined;
    const cut = (chars: number): SubagentRow | undefined => {
      const row = disclosureRow(item, cutMarkdown(answer, chars));
      return fits(row) ? row : undefined;
    };
    const whole = cut(cap);
    if (whole) return whole;
    // The longest cut that fits; none shorter than a line is worth showing.
    let best: SubagentRow | undefined;
    let low = MIN_EXCERPT;
    let high = cap - 1;
    while (low <= high) {
      const middle = Math.floor((low + high) / 2);
      const row = cut(middle);
      if (row) {
        best = row;
        low = middle + 1;
      } else high = middle - 1;
    }
    return best;
  };

  // A row for every child that fits first, in the panel's order: seeing each child comes before
  // reading any answer.
  const taken = new Map<Subagent, SubagentRow>();
  for (const item of [
    ...groups["needs-you"],
    ...groups.working,
    ...groups.recent,
    ...groups.earlier,
  ]) {
    const row = disclosureRow(item, undefined);
    if (!fits(row) || left.blocks < 1 || left.rows < 1) break;
    spend(row, 1);
    taken.set(item, row);
  }
  // Then answers with the room left: in full what needs you and what just finished; a glance at a
  // working child's previous answer and at Earlier ones.
  const answers: Array<[Subagent[], number]> = [
    [groups["needs-you"], ANSWER_EXCERPT_MAX],
    [groups.recent, ANSWER_EXCERPT_MAX],
    [groups.working, EARLIER_EXCERPT_MAX],
    [groups.earlier, EARLIER_EXCERPT_MAX],
  ];
  for (const [items, cap] of answers)
    for (const item of items) {
      const row = taken.get(item);
      if (!row) continue;
      spend(row, -1);
      const next = withAnswer(item, cap) ?? row;
      spend(next, 1);
      taken.set(item, next);
    }

  const shown = new Set([...taken.keys()].map((item) => item.id));
  const rowsOf = (items: Subagent[]): SubagentRow[] =>
    items.flatMap((item) => taken.get(item) ?? []);
  const section = (id: string, title: string, rows: SubagentRow[]): SubagentSection => ({
    type: "section",
    id: `subagents:${id}`,
    title,
    blocks: [{ type: "activityList", id: `subagents:${id}:rows`, rows }],
  });
  const sections: SubagentSection[] = [];
  for (const [id, title] of [
    ["needs-you", "Needs You"],
    ["working", "Working"],
    ["recent", "Recent"],
  ] as const) {
    const rows = rowsOf(groups[id]);
    if (rows.length > 0) sections.push(section(id, title, rows));
  }
  const earlier = rowsOf(groups.earlier);
  if (earlier.length > 0) {
    sections.push(
      section("earlier", "Earlier", [
        {
          id: "earlier",
          title: `${earlier.length} finished`,
          blocks: [{ type: "activityList", id: "subagents:earlier:list", rows: earlier }],
        },
      ]),
    );
  }

  const hidden = subagents.length - shown.size;
  if (hidden > 0) {
    const more: SubagentRow = {
      id: "thread",
      title: threadSessionId ? `${hidden} more in Thread` : `${hidden} more`,
      ...(threadSessionId ? { link: threadLink(threadSessionId) } : {}),
    };
    // After the oldest shown: inside Earlier when it is there.
    (earlier.length > 0 ? earlier : sections.at(-1)?.blocks[0].rows)?.push(more);
    fallback.push(rowFallback(more));
  }

  const liveShown = [...taken.keys()].filter(isLive).length;
  return { chrome: widgetChrome(subagents, liveShown), sections, fallback, shown };
}

/** The shortest answer cut worth showing, in characters. */
const MIN_EXCERPT = 80;

/**
 * A child's row as a disclosure row: what it is doing while it works, its answer (`excerpt`, or a
 * note that it did not fit), and a line of its model, spend, and worktree.
 */
function disclosureRow(item: Subagent, excerpt: string | undefined): SubagentRow {
  const parts: string[] = [];
  if (item.state === "running" && item.activity) parts.push(`**Now:** ${item.activity}`);
  if (excerpt) parts.push(excerpt);
  else if (item.answer) parts.push("_Open the session to read its answer._");
  const meta = rowMetaLine(item);
  if (meta) parts.push(meta);
  if (parts.length === 0) parts.push("_Open the session for its details._");
  return {
    ...subagentRow(item),
    blocks: [{ type: "markdown", id: "answer", markdown: parts.join("\n\n") }],
  };
}

/** The full model and thinking level, the exact spend, the worktree, and the run time. */
export function rowMetaLine(item: Subagent): string | undefined {
  const tree = item.worktree;
  const parts = [
    item.model ? `\`${item.model}\`` : undefined,
    item.thinking && item.thinking !== "off" ? `thinking ${item.thinking}` : undefined,
    item.cost !== undefined && item.cost > 0 ? `$${item.cost.toFixed(2)}` : undefined,
    tree?.branch ? `branch \`${tree.branch}\`` : undefined,
    tree?.ahead !== undefined && tree.ahead > 0 ? `${tree.ahead} ahead` : undefined,
    tree?.dirty ? "dirty" : undefined,
    !isLive(item) && item.took !== undefined ? `took ${durationLabel(item.took)}` : undefined,
  ].filter(Boolean);
  return parts.length > 0 ? parts.join(" \u00b7 ") : undefined;
}

/**
 * `markdown` cut to at most `max` characters, at a line or word end when one is near, with an
 * ellipsis; a code fence the cut leaves open is closed.
 */
export function cutMarkdown(markdown: string, max: number): string {
  const text = markdown.trim();
  const chars = Array.from(text);
  if (chars.length <= max) return text;
  let cut = chars.slice(0, Math.max(1, max - 5)).join("");
  const end = Math.max(cut.lastIndexOf("\n"), cut.lastIndexOf(" "));
  if (end > cut.length * 0.8) cut = cut.slice(0, end);
  cut = `${cut.trimEnd()}\u2026`;
  const fences = cut.match(/^\s*```/gm)?.length ?? 0;
  return fences % 2 === 1 ? `${cut}\n\`\`\`` : cut;
}

const encoder = new TextEncoder();

/** Every string in `value`, in UTF-8 bytes: at least what the server counts as surface text. */
export function textBytes(value: unknown): number {
  if (typeof value === "string") return encoder.encode(value).length;
  if (Array.isArray(value)) return value.reduce((sum: number, item) => sum + textBytes(item), 0);
  if (value && typeof value === "object")
    return Object.values(value).reduce((sum: number, item) => sum + textBytes(item), 0);
  return 0;
}

/** `value` as JSON, in UTF-8 bytes, with the comma that follows it in a list. */
export function jsonBytes(value: unknown): number {
  return encoder.encode(JSON.stringify(value)).length + 1;
}

/** Title and subtitle; the subtitle counts every live child, not the rows shown. */
export function widgetChrome(subagents: Subagent[], max = MAX_PILL_ROWS): WidgetChrome {
  const subtitle = panelSummary(subagents, max);
  return { title: "Subagents", ...(subtitle ? { subtitle } : {}) };
}

/**
 * One row per child. The title is its name; the second line says what changes (the step, the
 * question, the wait, the error, the answer), with no state word: the section says the state.
 * The quiet third line is the model and thinking level, the spend, the worktree's progress, and
 * how long a finished run took. A live row's `since` lets the client tick its time.
 */
export function subagentRows(subagents: Subagent[]): SubagentRow[] {
  return subagents.map(subagentRow);
}

function subagentRow(item: Subagent): SubagentRow {
  const detail = rowDetail(item);
  const activity = rowNote(item);
  return {
    id: item.id,
    title: item.title,
    ...(activity ? { subtitle: activity } : {}),
    ...(detail ? { detail } : {}),
    state: item.stopped && !isLive(item) ? "inactive" : item.state,
    link: item.link,
    ...(isLive(item) && item.since !== undefined ? { since: item.since } : {}),
  };
}

/**
 * The row's quiet third line: the short model name and thinking level, the spend, the worktree's
 * progress, and how long a finished run took.
 */
export function rowDetail(item: Subagent): string | undefined {
  const detail = [
    [shortModelName(item.model), item.thinking === "off" ? undefined : item.thinking]
      .filter(Boolean)
      .join(" "),
    item.cost !== undefined && item.cost > 0 ? `$${item.cost.toFixed(2)}` : undefined,
    worktreeLabel(item),
    !isLive(item) && item.took !== undefined ? `took ${durationLabel(item.took)}` : undefined,
  ]
    .filter(Boolean)
    .join(" \u00b7 ");
  return detail.length > 0 ? detail : undefined;
}

/**
 * The row's second line: what changed (the step, the question, the error, the answer), or how the
 * child finished. The section says the state, so the line never repeats it.
 */
export function rowNote(item: Subagent): string | undefined {
  return item.activity ?? (item.stopped ? "Stopped" : undefined);
}

/** The worktree's progress: its branch when the spawn did not name it, commits ahead, dirty. */
function worktreeLabel(item: Subagent): string | undefined {
  const tree = item.worktree;
  if (!tree) return undefined;
  const parts = [
    tree.branch,
    tree.ahead !== undefined && tree.ahead > 0 ? `${tree.ahead} ahead` : undefined,
    tree.dirty ? "dirty" : undefined,
  ].filter(Boolean);
  return parts.length > 0 ? parts.join(", ") : undefined;
}

function durationLabel(ms: number): string {
  const minutes = Math.round(ms / 60_000);
  if (minutes < 1) return `${Math.max(1, Math.round(ms / 1000))}s`;
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  return minutes % 60 === 0 ? `${hours}h` : `${hours}h ${minutes % 60}m`;
}

function sessionRecord(payload: unknown): Record<string, unknown> | null {
  const data = envelopeData(payload);
  return asRecord(data?.session) ?? data;
}

function subagentFromSession(
  session: Record<string, unknown>,
  id: string,
  parentId?: string,
): Subagent {
  const workspaceId = stringField(session, "workspaceId");
  const name = stringField(session, "name") ?? shortId(id);
  const model = stringField(session, "model");
  return {
    id,
    parentId,
    title: name,
    subtitle: shortId(id),
    link: sessionLink(id, workspaceId),
    state: stateFromStatus(stringField(session, "status"), boolField(session, "pendingWake")),
    ...(model ? { model } : {}),
  };
}

/**
 * The live counts, most urgent first: `1 failed · 1 needs you · 2 working`. Nothing live: none,
 * and the pill goes away. Live children past the rows add `+N more`.
 */
function panelSummary(rows: Subagent[], max: number): string | undefined {
  const failed = rows.filter((row) => row.state === "error").length;
  const asking = rows.filter((row) => row.state === "warning").length;
  const working = rows.filter((row) => row.state === "running").length;
  const parts: string[] = [];
  if (failed > 0) parts.push(`${failed} failed`);
  if (asking > 0) parts.push(asking === 1 ? "1 needs you" : `${asking} need you`);
  if (working > 0) parts.push(`${working} working`);
  const hidden = failed + asking + working - max;
  if (hidden > 0) parts.push(`+${hidden} more`);
  return parts.length > 0 ? parts.join(" \u00b7 ") : undefined;
}

function shortModelName(model: string | undefined): string | undefined {
  if (!model) return undefined;
  const name = model.split("/").pop() ?? model;
  return name.replace(/^claude-/, "").replace(/^gemini-/, "");
}

export function titledWithAgent(name: string, icon: unknown): string {
  const mark = agentEmoji(icon);
  if (!mark || name.startsWith(`${mark} `) || name === mark) return name;
  return `${mark} ${name}`;
}

function agentEmoji(icon: unknown): string | undefined {
  const record = asRecord(icon);
  if (stringField(record, "kind") !== "emoji") return undefined;
  const value = stringField(record, "value");
  if (!value || [...value].length > 4) return undefined;
  return value;
}

/**
 * `pendingWake` (`SessionManager.awaitsNextTurn`, carried on a live GET or `wait` snapshot) says
 * a running background job or a supervised child will still start this session's next turn: an
 * otherwise-settled row stays Working instead of Done.
 */
function stateFromStatus(status: string | undefined, pendingWake?: boolean): Subagent["state"] {
  const token = (status ?? "").toLowerCase();
  if (token === "error") return "error";
  if (token === "attention") return "warning";
  if (token === "stopped" || token === "idle" || token === "ready" || token === "stopping")
    return pendingWake ? "running" : "success";
  return "running";
}

function mergePolledState(known: Subagent["state"], polled: Subagent["state"]): Subagent["state"] {
  // Wait owns attention. Session get has no pending-dialog field, so a busy
  // poll must not paint Needs attention back to Working.
  if (known === "warning" && polled === "running") return "warning";
  return polled;
}

function envelopeData(payload: unknown): Record<string, unknown> | null {
  if (typeof payload === "string") return jsonData(payload);
  const record = asRecord(payload);
  if (!record) return null;
  if (record.ok === true) return asRecord(record.data);
  return record;
}

function createEnvelope(text: string): Record<string, unknown> | null {
  const trimmed = text.trim();
  const candidates = [trimmed];
  const line = trimmed.split("\n").find((item) => item.trim().startsWith("{"));
  if (line && line.trim() !== trimmed) candidates.push(line.trim());
  for (const candidate of candidates) {
    try {
      const data = envelopeData(JSON.parse(candidate) as unknown);
      if (stringField(data, "session_id") || stringField(data, "sessionId")) return data;
    } catch {
      // A create result is one JSON envelope, not a slice across several objects.
    }
  }
  return null;
}

function jsonData(text: string): Record<string, unknown> | null {
  try {
    return envelopeData(JSON.parse(text) as unknown);
  } catch {
    return null;
  }
}

function flag(command: string, name: string): string | undefined {
  const equals = command.match(new RegExp(`--${name}=(\\S+)`));
  if (equals?.[1]) return equals[1];
  const spaced = command.match(new RegExp(`--${name}\\s+(\\S+)`));
  return spaced?.[1];
}

function shortId(sessionId: string): string {
  return sessionId.replace(/-/g, "").slice(0, 8);
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function stringField(record: Record<string, unknown> | null, key: string): string | undefined {
  const value = record?.[key];
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function boolField(record: Record<string, unknown> | null, key: string): boolean | undefined {
  const value = record?.[key];
  return typeof value === "boolean" ? value : undefined;
}

interface TerminalSpec {
  title: string;
  status: string;
  state: Subagent["state"];
  model?: string;
}

interface TerminalPiece {
  text: string;
  role: "rule" | "glyph" | "header" | "name" | "status" | "meta";
  state?: Subagent["state"];
}

function terminalSpec(item: Subagent): TerminalSpec {
  return {
    title: item.title,
    status: statusLabel(item.state),
    state: item.state,
    model: shortModelName(item.model),
  };
}

function headerState(rows: Subagent[]): Subagent["state"] {
  if (rows.some((row) => row.state === "warning")) return "warning";
  if (rows.some((row) => row.state === "running")) return "running";
  if (rows.some((row) => row.state === "error")) return "error";
  return "success";
}

function stateGlyph(state: Subagent["state"]): string {
  switch (state) {
    case "running":
      return "\u25cf";
    case "success":
      return "\u2713";
    case "warning":
      return "!";
    case "error":
      return "\u2717";
  }
}

function terminalNameColumn(specs: TerminalSpec[], width: number | undefined): number | undefined {
  const maxName = Math.max(...specs.map((spec) => columns(spec.title)));
  const maxStatus = Math.max(...specs.map((spec) => columns(spec.status)));
  if (width === undefined) return maxName;
  const cap = width - TERMINAL_PREFIX_WIDTH - 1 - maxStatus;
  if (cap < 8) return undefined;
  return Math.min(maxName, cap);
}

function terminalStatusColumn(
  specs: TerminalSpec[],
  width: number | undefined,
  nameCol: number | undefined,
): number | undefined {
  if (nameCol === undefined) return undefined;
  const widths = specs.map((spec) => columns(spec.status));
  const maxStatus = Math.max(...widths);
  if (width === undefined) return maxStatus;
  const room = width - TERMINAL_PREFIX_WIDTH - nameCol - 1 - maxStatus - 1;
  const wantsModel = specs.some((spec) => spec.model);
  const spread = maxStatus - Math.min(...widths);
  // Padding "Needs attention" to every row hides the model. Done versus Working does not.
  if (wantsModel && room < SHORT_MODEL_META_WIDTH && spread > SHORT_STATUS_SPREAD) return undefined;
  return maxStatus;
}

function headerPieces(subagents: Subagent[], width: number | undefined): TerminalPiece[] {
  const chrome = widgetChrome(subagents);
  const state = headerState(subagents);
  const glyph = stateGlyph(state);
  let title = chrome.title;
  let subtitle = chrome.subtitle;
  if (width !== undefined) {
    const prefix = `\u2502 ${glyph} `;
    const extra = subtitle ? ` \u00b7 ${subtitle}` : "";
    if (columns(prefix + title + extra) > width) {
      subtitle = undefined;
      if (columns(prefix + title) > width) {
        title = truncateColumns(title, Math.max(1, width - columns(prefix)));
      }
    }
  }
  const pieces: TerminalPiece[] = [
    { text: "\u2502", role: "rule" },
    { text: glyph, role: "glyph", state },
    { text: title, role: "header", state },
  ];
  if (subtitle) pieces.push({ text: `\u00b7 ${subtitle}`, role: "meta" });
  return pieces;
}

function rowPieces(
  spec: TerminalSpec,
  width: number | undefined,
  nameCol: number | undefined,
  statusCol: number | undefined,
): TerminalPiece[] {
  const fitted = fitRow(spec, width, nameCol, statusCol);
  const pieces: TerminalPiece[] = [
    { text: "\u2502", role: "rule" },
    { text: stateGlyph(spec.state), role: "glyph", state: spec.state },
    { text: fitted.name, role: "name" },
  ];
  if (fitted.status) pieces.push({ text: fitted.status, role: "status", state: spec.state });
  if (fitted.meta) pieces.push({ text: fitted.meta, role: "meta" });
  return pieces;
}

function fitRow(
  spec: TerminalSpec,
  width: number | undefined,
  nameCol: number | undefined,
  statusCol: number | undefined,
): { name: string; status: string; meta: string } {
  if (width === undefined) {
    return {
      name: padColumns(spec.title, nameCol ?? columns(spec.title)),
      status: padColumns(spec.status, statusCol ?? columns(spec.status)),
      meta: fitMeta(spec.model, Number.POSITIVE_INFINITY),
    };
  }
  if (nameCol !== undefined) {
    const name = padColumns(truncateColumns(spec.title, nameCol), nameCol);
    const status = statusCol === undefined ? spec.status : padColumns(spec.status, statusCol);
    const used = TERMINAL_PREFIX_WIDTH + columns(name) + 1 + columns(status);
    const meta = fitMeta(spec.model, width - used - 1);
    return { name, status: meta ? status : status.trimEnd(), meta };
  }
  const statusW = columns(spec.status);
  const nameBudget = width - TERMINAL_PREFIX_WIDTH - 1 - statusW;
  if (nameBudget >= 1) {
    const name = truncateColumns(spec.title, nameBudget);
    const used = TERMINAL_PREFIX_WIDTH + columns(name) + 1 + statusW;
    return { name, status: spec.status, meta: fitMeta(spec.model, width - used - 1) };
  }
  return {
    name: truncateColumns(spec.title, Math.max(1, width - TERMINAL_PREFIX_WIDTH)),
    status: "",
    meta: "",
  };
}

function fitMeta(model: string | undefined, remaining: number): string {
  if (!model) return "";
  if (remaining === Number.POSITIVE_INFINITY) return `\u00b7 ${model}`;
  if (remaining < 4) return "";
  if (columns(`\u00b7 ${model}`) <= remaining) return `\u00b7 ${model}`;
  if (remaining >= 10) return `\u00b7 ${truncateColumns(model, remaining - 2)}`;
  return "";
}

function paintTerminalLine(pieces: TerminalPiece[], style: SubagentTerminalStyle): string {
  return pieces
    .filter((piece) => piece.text.length > 0)
    .map((piece) => paintTerminalPiece(piece, style))
    .join(" ");
}

function paintTerminalPiece(piece: TerminalPiece, style: SubagentTerminalStyle): string {
  const paint = statePaint(style, piece.state ?? "running");
  switch (piece.role) {
    case "rule":
      return style.rule(piece.text);
    case "glyph":
      return paint(piece.text);
    case "header":
      return style.bold(paint(piece.text));
    case "name":
      return style.bold(style.title(piece.text));
    case "status":
      return paint(piece.text);
    case "meta":
      return style.dim(piece.text);
  }
}

function statePaint(
  style: SubagentTerminalStyle,
  state: Subagent["state"],
): (text: string) => string {
  if (state === "success") return style.success;
  if (state === "warning") return style.warning;
  if (state === "error") return style.error;
  return style.accent;
}

function columns(text: string): number {
  let width = 0;
  for (const char of text) {
    const code = char.codePointAt(0) ?? 0;
    if (code === 0xfe0f || code === 0x200d) continue;
    width += charColumns(code);
  }
  return width;
}

function charColumns(code: number): number {
  if (code > 0xffff) return 2;
  if (code >= 0x1100 && code <= 0x115f) return 2;
  if (code >= 0x2e80 && code <= 0xa4cf) return 2;
  if (code >= 0xac00 && code <= 0xd7a3) return 2;
  if (code >= 0xf900 && code <= 0xfaff) return 2;
  if (code >= 0xfe10 && code <= 0xfe6f) return 2;
  if (code >= 0xff00 && code <= 0xff60) return 2;
  if (code >= 0xffe0 && code <= 0xffe6) return 2;
  return 1;
}

function truncateColumns(text: string, width: number): string {
  if (width <= 0) return "";
  if (columns(text) <= width) return text;
  if (width === 1) return "\u2026";
  let out = "";
  let used = 0;
  for (const char of text) {
    const code = char.codePointAt(0) ?? 0;
    if (code === 0xfe0f || code === 0x200d) continue;
    const size = charColumns(code);
    if (used + size > width - 1) break;
    out += char;
    used += size;
  }
  return `${out}\u2026`;
}

function padColumns(text: string, width: number): string {
  const gap = width - columns(text);
  return gap > 0 ? text + " ".repeat(gap) : text;
}
