import {
  badge,
  blocks,
  button,
  code,
  group,
  row,
  stack,
  surface,
  text,
  type Surface,
  type SurfaceView,
} from "oppi/v1";
import {
  backgroundPill,
  badgeLabel,
  displayCommand,
  displayLines,
  type JobStatus,
} from "./jobs.js";

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
const TAIL_LINES = 12;
const TAIL_CHARS = 480;
/** The surface's fallback text is capped at 2,000 characters on the wire. */
const FALLBACK_CHARS = 1_900;

/** A job the panel shows: backgrounded, and its result not yet delivered. */
export interface PanelJob {
  id: string;
  command: string;
  status: JobStatus;
  startedAt: number;
  /** The output of a finished job; one that is still running has none saved yet. */
  output?: string;
}

export interface PanelState {
  /** Never empty: with nothing to show the panel is dismissed instead. */
  jobs: PanelJob[];
  /** When the state was read, for the elapsed time the header shows. */
  at: number;
}

function clamp(value: string, chars: number): string {
  const characters = Array.from(value);
  return characters.length <= chars ? value : `${characters.slice(0, chars - 1).join("")}…`;
}

/** The last lines of a job's output, plain, cut at a character budget from the front. */
function outputTail(output: string | undefined): string | undefined {
  const tail = displayLines(output ?? "")
    .slice(-TAIL_LINES)
    .join("\n");
  if (!tail) return undefined;
  const characters = Array.from(tail);
  return characters.length <= TAIL_CHARS
    ? tail
    : `…${characters.slice(characters.length - TAIL_CHARS + 1).join("")}`;
}

function tone(status: JobStatus): "accent" | "success" | "warning" | "danger" {
  if (status === "running") return "accent";
  if (status === "completed") return "success";
  if (status === "cancelled") return "warning";
  return "danger";
}

function jobNode(job: PanelJob): ReturnType<typeof stack> {
  const tail = outputTail(job.output);
  return stack({
    id: `job:${job.id}`,
    children: [
      row({
        id: `head:${job.id}`,
        align: "spread",
        children: [
          text({ id: `title:${job.id}`, text: job.id, style: "headline" }),
          badge({ id: `status:${job.id}`, text: badgeLabel(job.status), tone: tone(job.status) }),
          // Only a job that is still running offers Stop.
          ...(job.status === "running"
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
      text({
        id: `command:${job.id}`,
        text: clamp(displayCommand(job.command), COMMAND_CHARS),
        style: "mono",
      }),
      group({
        id: `output:${job.id}`,
        title: "Output",
        collapsed: true,
        children: [
          tail
            ? code({ id: `tail:${job.id}`, text: tail })
            : text({ id: `tail:${job.id}`, text: "No output yet", style: "caption" }),
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

/** The panel for a non-empty job list: its header, and one row per job with its output behind a fold. */
export function jobsView(state: PanelState): SurfaceView {
  const jobs = ordered(state.jobs);
  const pill = backgroundPill(
    jobs.map((job) => ({ ...job, backgrounded: true })),
    state.at,
  );
  if (!pill) throw new Error("The background jobs panel needs at least one job.");
  const hidden = jobs.length - MAX_SHOWN_JOBS;
  return {
    header: { title: pill.title, subtitle: clamp(pill.subtitle, COMMAND_CHARS) },
    sections: [
      blocks({
        id: "jobs",
        fallback: fallbackText(state),
        body: stack({
          id: "list",
          children: [
            ...jobs.slice(0, MAX_SHOWN_JOBS).map(jobNode),
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
   */
  readonly stops: Map<string, () => Promise<void>>;
}

export function createJobsPanel(): JobsPanel {
  const stops = new Map<string, () => Promise<void>>();
  const panel = surface<PanelState>({
    id: PANEL_ID,
    title: "Background jobs",
    actions: { stop: { title: "Stop", role: "destructive", pending: { title: "Stopping…" } } },
    fallback: fallbackText,
    view: jobsView,
  });
  panel.action("stop", async (_state, tap) => {
    const job = tap.values?.job;
    const stop = typeof job === "string" ? stops.get(job) : undefined;
    if (!stop)
      return {
        error: {
          compositeId: tap.compositeId,
          message: `${typeof job === "string" ? job : "That job"} is not running.`,
        },
      };
    await stop();
    // The row changes when the runner reports the job stopped, which republishes the panel.
    return undefined;
  });
  return { surface: panel, stops };
}
