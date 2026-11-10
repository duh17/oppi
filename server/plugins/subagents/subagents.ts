/**
 * Subagents launched by this parent.
 *
 * The set is the create results this session saw. Status updates come from
 * `oppi session wait`; a one-time `oppi session get <id>` snapshot fills in
 * the model. There is no children list API.
 */

export interface Subagent {
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
}

export interface SubagentRow {
  id: string;
  title: string;
  subtitle?: string;
  detail?: string;
  /** `inactive`: a child finished by a stop. The thread row has no state. */
  state?: Subagent["state"] | "inactive";
  link: string;
  since?: number;
}

/** A titled group of rows, as the native surface's `section` block holding an `activityList`. */
export interface SubagentSection {
  type: "section";
  id: string;
  title: string;
  blocks: [{ type: "activityList"; id: string; rows: SubagentRow[] }];
}

export interface WidgetChrome {
  title: string;
  subtitle?: string;
}

/** Most live children (asking, failed, working) the pill shows as rows; the subtitle counts all. */
export const MAX_PILL_ROWS = 8;
/** Finished children listed under Recent, newest first. */
export const MAX_RECENT_ROWS = 3;

export function sessionLink(sessionId: string, workspaceId?: string): string {
  const url = `oppi://session/${sessionId}`;
  return workspaceId ? `${url}?workspaceId=${encodeURIComponent(workspaceId)}` : url;
}

/** The session list with `sessionId`'s thread open: the way from the pill to every child. */
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
 * The children the pill draws as rows, from every child, newest first: those that need you, the
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

/**
 * The pill's body: Needs You, Working, and Recent, each a section of rows, leaving out an empty
 * one. When any child has no row, a last row in the last section opens the whole thread.
 */
export function pillSections(
  subagents: Subagent[],
  threadSessionId?: string,
  max = MAX_PILL_ROWS,
): SubagentSection[] {
  const selected = selectPillRows(subagents, max);
  const groups: Array<[id: string, title: string, rows: Subagent[]]> = [
    ["needs-you", "Needs You", selected.filter(needsYou)],
    ["working", "Working", selected.filter((item) => item.state === "running")],
    ["recent", "Recent", selected.filter((item) => !isLive(item))],
  ];
  const sections = groups
    .filter(([, , rows]) => rows.length > 0)
    .map(([id, title, rows]): SubagentSection => ({
      type: "section",
      id: `subagents:${id}`,
      title,
      blocks: [{ type: "activityList", id: `subagents:${id}:rows`, rows: subagentRows(rows) }],
    }));
  const last = sections.at(-1);
  if (last && threadSessionId && selected.length < subagents.length) {
    last.blocks[0].rows.push({
      id: "thread",
      title: `All ${subagents.length} in Thread`,
      link: threadLink(threadSessionId),
    });
  }
  return sections;
}

/** Every row of the sections, for the surface's text fallback. */
export function sectionRows(sections: SubagentSection[]): SubagentRow[] {
  return sections.flatMap((section) => section.blocks[0].rows);
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
  return subagents.map((item) => {
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
    const activity = item.activity ?? (item.stopped ? "Stopped" : undefined);
    return {
      id: item.id,
      title: item.title,
      ...(activity ? { subtitle: activity } : {}),
      ...(detail ? { detail } : {}),
      state: item.stopped && !isLive(item) ? "inactive" : item.state,
      link: item.link,
      ...(isLive(item) && item.since !== undefined ? { since: item.since } : {}),
    };
  });
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
