import {
  badge,
  blocks,
  button,
  code,
  divider,
  group,
  icon,
  pill,
  progress,
  row,
  stack,
  surface,
  text,
  type Surface,
  type SurfaceView,
} from "oppi/v1";
import { backgroundPill, displayCommand, displayLines, type JobStatus } from "./jobs.js";

// The durable form of the job pill: one persistent strip panel per conversation, drawn by the
// host from `oppi/v1`'s `surface()`. The classic extension (`index.ts`) cannot publish one — it
// only reaches the host's v1 widget — and keeps using `backgroundPill`, the model both views read.
// A surface lives in its Session's memory, so the server publishes it again from the saved job
// list (`server.ts`) whenever a job changes and when a job's runner resumes after a restart.

export const PANEL_ID = "background-jobs";
/** Jobs the panel draws: a body is a stack of at most 12 children, and one is left for the count. */
const MAX_SHOWN_JOBS = 11;
/** A row's command and output tail stay inside the wire's 500 characters a node. */
const COMMAND_CHARS = 200;
/**
 * A row's title is one line: the host wraps a card's text rather than cutting it, so the cut is
 * made here, at what fits beside the status glyph and Stop on a phone.
 */
const TITLE_CHARS = 24;
const TAIL_LINES = 12;
/** The pill's live line: what fits beside the count and the age on a phone's strip. */
const PILL_LINE_CHARS = 40;
const TAIL_CHARS = 480;
/** The surface's fallback text is capped at 2,000 characters on the wire. */
const FALLBACK_CHARS = 1_900;

/** A job the panel shows: backgrounded, and its result not yet delivered. */
export interface PanelJob {
  id: string;
  command: string;
  status: JobStatus;
  startedAt: number;
  /** How a finished job's process ended; none when it was stopped or never reported one. */
  exitCode?: number | null;
  /** A finished job's saved output, or a running job's live tail (memory only, never saved). */
  output?: string;
  /** The job's working directory; shown for a running job. */
  cwd?: string;
  /** When a running job's timeout kills it, if it has one. */
  timeoutAt?: number;
  /** Whether the runner has dropped the start of this job's output. */
  truncated?: boolean;
}

export interface PanelState {
  /** Never empty: with nothing to show the panel is dismissed instead. */
  jobs: PanelJob[];
  /** When the state was read, for the elapsed time a running job shows. */
  at: number;
}

function clamp(value: string, chars: number): string {
  const characters = Array.from(value);
  return characters.length <= chars ? value : `${characters.slice(0, chars - 1).join("")}…`;
}

/**
 * The last lines of a job's output, plain, cut at a character budget from the front: what a row
 * shows, and so what a running job's redraw compares.
 */
export function outputTail(output: string | undefined): string | undefined {
  const tail = displayLines(output ?? "")
    .slice(-TAIL_LINES)
    .join("\n");
  if (!tail) return undefined;
  const characters = Array.from(tail);
  return characters.length <= TAIL_CHARS
    ? tail
    : `…${characters.slice(characters.length - TAIL_CHARS + 1).join("")}`;
}

/** The status glyph and its tone: what a person scans for before reading a word. */
function glyph(status: JobStatus): {
  name: string;
  tone: "accent" | "success" | "warning" | "danger";
} {
  if (status === "running") return { name: "arrow.triangle.2.circlepath", tone: "accent" };
  if (status === "completed") return { name: "checkmark.circle.fill", tone: "success" };
  if (status === "cancelled") return { name: "minus.circle", tone: "warning" };
  if (status === "timed_out") return { name: "exclamationmark.triangle.fill", tone: "warning" };
  return { name: "xmark.circle.fill", tone: "danger" };
}

const LEADING_CD = /^cd\s+(?:"[^"]*"|'[^']*'|[^\s;&|]+)\s*(?:&&|;)\s*/u;
/** A word that ends the command proper: a pipe, a list operator, or a redirect. */
const SHELL_OPERATOR = /^(?:\|\|?|&&?|;|\d*[<>])/u;

/** A path is named by its file: `~/tools/scripts/build.ts` is `build.ts`. */
function pathLeaf(word: string): string {
  return word.split("/").length > 2 ? (word.split("/").at(-1) ?? word) : word;
}

/**
 * What a job is called in its row: the program and its first plain arguments, one short line.
 * A leading `cd <dir> &&` is where the shell starts, not what runs, and everything from the first
 * option, pipe, or redirect on is detail the disclosure carries in full.
 */
export function commandTitle(command: string): string {
  let rest = displayCommand(command);
  for (let match = LEADING_CD.exec(rest); match && match[0].length < rest.length;) {
    rest = rest.slice(match[0].length);
    match = LEADING_CD.exec(rest);
  }
  const words = rest.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/gu) ?? [];
  const title: string[] = [];
  let skipping = true;
  for (const word of words) {
    if (SHELL_OPERATOR.test(word)) break;
    // Leading `NAME=value` words configure the program; they are not it.
    if (skipping && /^[A-Za-z_]\w*=/u.test(word)) continue;
    // The program, then arguments up to the first option.
    if (!skipping && (word.startsWith("-") || title.length >= 3)) break;
    skipping = false;
    const cut = word.endsWith(";");
    title.push(pathLeaf(cut ? word.slice(0, -1) : word));
    if (cut) break;
  }
  return clamp(title.join(" ") || displayCommand(command), TITLE_CHARS);
}

/** Whole minutes, as a status line reads: `<1m`, `12m`, `1h 5m`. */
function elapsed(ms: number): string {
  const minutes = Math.max(0, Math.floor(ms / 60_000));
  if (minutes < 1) return "<1m";
  return minutes < 60 ? `${minutes}m` : `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
}

/** How a finished job ended: its exit status when the process reported one, else the outcome. */
function outcome(job: PanelJob): string {
  if (typeof job.exitCode === "number") return `Exit ${job.exitCode}`;
  if (job.status === "cancelled") return "Stopped";
  if (job.status === "timed_out") return "Timed out";
  return "Failed";
}

/** The last non-empty line of a job's output, plain and cut for the pill. */
function latestLine(output: string | undefined): string | undefined {
  const line = displayLines(output ?? "")
    .at(-1)
    ?.trim();
  return line ? clamp(line, PILL_LINE_CHARS) : undefined;
}

function basename(path: string): string {
  return path.replace(/\/+$/u, "").split("/").at(-1) || path;
}

/** A running job's where and until-when, one caption: `app · times out in 4m`. */
function runningDetail(job: PanelJob, at: number): string | undefined {
  const parts = [
    ...(job.cwd ? [basename(job.cwd)] : []),
    ...(job.timeoutAt === undefined
      ? []
      : [job.timeoutAt <= at ? "timing out" : `times out in ${elapsed(job.timeoutAt - at)}`]),
  ];
  return parts.length > 0 ? parts.join(" · ") : undefined;
}

function jobNode(job: PanelJob, at: number, first: boolean): ReturnType<typeof stack> {
  const tail = outputTail(job.output);
  const running = job.status === "running";
  const mark = glyph(job.status);
  const detail = running ? runningDetail(job, at) : undefined;
  // A running job's tail is the point of opening the panel, so it is not folded away; a finished
  // job's output stays behind Details.
  const tailNode = tail
    ? code({ id: `tail:${job.id}`, language: "output", text: tail })
    : text({ id: `tail:${job.id}`, text: "No output yet", style: "caption" });
  return stack({
    id: `job:${job.id}`,
    spacing: "tight",
    children: [
      ...(first ? [] : [divider({ id: `rule:${job.id}` })]),
      row({
        id: `head:${job.id}`,
        children: [
          icon({ id: `status:${job.id}`, name: mark.name, tone: mark.tone }),
          stack({
            id: `titles:${job.id}`,
            spacing: "tight",
            children: [
              text({ id: `title:${job.id}`, text: commandTitle(job.command), style: "headline" }),
              text({
                id: `meta:${job.id}`,
                text: `${job.id} · ${running ? `Running ${elapsed(at - job.startedAt)}` : outcome(job)}`,
                style: "caption",
              }),
            ],
          }),
          // Only a job that is still running offers Stop.
          ...(running
            ? [
                button({
                  id: `stop:${job.id}`,
                  title: "Stop",
                  role: "destructive",
                  action: { id: "stop", values: { job: job.id } },
                }),
              ]
            : []),
        ],
      }),
      ...(detail ? [text({ id: `detail:${job.id}`, text: detail, style: "caption" })] : []),
      ...(running ? [tailNode] : []),
      ...(running && job.truncated
        ? [text({ id: `truncated:${job.id}`, text: "Output truncated", style: "caption" })]
        : []),
      group({
        id: `output:${job.id}`,
        title: "Details",
        collapsed: true,
        children: [
          // The whole command on its own line, in the host's monospace. The row's title is the
          // short form; this is what was run.
          text({
            id: `command:${job.id}`,
            text: clamp(displayCommand(job.command), COMMAND_CHARS),
            style: "mono",
          }),
          ...(running && job.cwd
            ? [text({ id: `cwd:${job.id}`, text: clamp(job.cwd, COMMAND_CHARS), style: "mono" })]
            : []),
          // The `code` node's header carries its label: this is output, not source.
          ...(running ? [] : [tailNode]),
        ],
      }),
    ],
  });
}

/** The jobs that are running first, then the finished ones, each in the order they started. */
function ordered(jobs: readonly PanelJob[]): PanelJob[] {
  return [
    ...jobs.filter((job) => job.status === "running"),
    ...jobs.filter((job) => job.status !== "running"),
  ];
}

/** What an older client shows instead: the terminal band the classic extension draws. */
function fallbackText(state: PanelState): string {
  const pill = backgroundPill(
    state.jobs.map((job) => ({ ...job, backgrounded: true })),
    state.at,
  );
  return clamp(pill?.summary.join("\n") ?? "Background jobs", FALLBACK_CHARS);
}

function jobCount(count: number): string {
  return `${count} ${count === 1 ? "job" : "jobs"}`;
}

/** The strip pill's one line: how many jobs there are and how many still run; no command. */
function pillLine(jobs: readonly PanelJob[], at: number): ReturnType<typeof pill> {
  const running = jobs.filter((job) => job.status === "running");
  const label =
    running.length === jobs.length
      ? `${jobCount(jobs.length)} running`
      : running.length === 0
        ? `${jobCount(jobs.length)} finished`
        : `${jobCount(jobs.length)} · ${running.length} running`;
  // The longest-running job's age, the number that says whether a job is stuck.
  const oldest = Math.min(...running.map((job) => job.startedAt));
  // What the newest running job last printed; nothing until it prints something.
  const newest = running.reduce<PanelJob | undefined>(
    (latest, job) => (!latest || job.startedAt > latest.startedAt ? job : latest),
    undefined,
  );
  const line = latestLine(newest?.output);
  const failed = jobs.filter((job) => job.status === "failed").length;
  return pill({
    content: [
      // No value: an indeterminate spinner while anything runs.
      ...(running.length > 0 ? [progress({ id: "pill:spinner", tone: "accent" })] : []),
      text({ id: "pill:count", text: label, style: "headline" }),
      ...(running.length > 0
        ? [text({ id: "pill:elapsed", text: elapsed(at - oldest), style: "caption" })]
        : []),
      ...(line ? [text({ id: "pill:line", text: line, style: "caption" })] : []),
      ...(failed > 0
        ? [badge({ id: "pill:failed", text: `${failed} failed`, tone: "danger" })]
        : []),
    ],
  });
}

/** The panel for a non-empty job list: a status header, and one row per job with its detail behind a fold. */
export function jobsView(state: PanelState): SurfaceView {
  const jobs = ordered(state.jobs);
  if (jobs.length === 0) throw new Error("The background jobs panel needs at least one job.");
  const running = jobs.filter((job) => job.status === "running").length;
  const finished = jobs.length - running;
  const hidden = jobs.length - MAX_SHOWN_JOBS;
  return {
    header: {
      title: "Background jobs",
      subtitle: [
        running > 0 ? `${running} running` : "",
        finished > 0 ? `${finished} finished` : "",
      ]
        .filter(Boolean)
        .join(" · "),
    },
    pill: pillLine(jobs, state.at),
    sections: [
      blocks({
        id: "jobs",
        fallback: fallbackText(state),
        body: stack({
          id: "list",
          children: [
            ...jobs
              .slice(0, MAX_SHOWN_JOBS)
              .map((job, index) => jobNode(job, state.at, index === 0)),
            ...(hidden > 0
              ? [text({ id: "more", text: `+${hidden} more`, style: "caption" })]
              : []),
          ],
        }),
      }),
    ],
  };
}

/** One conversation's panel, and the means to stop the jobs it lists. */
export interface JobsPanel {
  readonly surface: Surface<PanelState>;
  /**
   * How to stop each running job of this conversation, by job id. A tap on Stop runs outside any
   * task, so the job's own runner leaves its handle here while it runs and takes it back after.
   * A handle answers whether the job was running and is now marked for the kill.
   */
  readonly stops: Map<string, () => Promise<boolean>>;
}

export function createJobsPanel(): JobsPanel {
  const stops = new Map<string, () => Promise<boolean>>();
  const panel = surface<PanelState>({
    id: PANEL_ID,
    title: "Background jobs",
    actions: { stop: { title: "Stop", role: "destructive", pending: { title: "Stopping…" } } },
    fallback: fallbackText,
    view: jobsView,
  });
  panel.action("stop", async (_state, tap) => {
    const job = tap.values?.job;
    const stopped = typeof job === "string" ? await stops.get(job)?.() : undefined;
    if (!stopped)
      return {
        error: {
          compositeId: tap.compositeId,
          message: `${typeof job === "string" ? job : "That job"} is not running.`,
        },
      };
    // The row changes when the runner reports the job stopped, which republishes the panel.
    return undefined;
  });
  return { surface: panel, stops };
}
