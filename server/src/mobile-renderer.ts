/**
 * Mobile tool renderer registry.
 *
 * Pre-renders styled summary segments for iOS tool call display.
 * Parallels pi's TUI `renderCall`/`renderResult` pattern but produces
 * serializable StyledSegment[] instead of TUI Component objects.
 *
 * Sources (load order, later overrides earlier):
 * 1. Built-in renderers (bash, read, edit, write, grep, find, ls, todo)
 * 2. User renderers (~/.pi/agent/mobile-renderers/*.ts)
 *
 * User renderers live in a dedicated directory separate from pi extensions
 * so the pi CLI doesn't try to load them as extensions.
 */

import { existsSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import { createLogger } from "./logger.js";
import type { StyledSegment } from "./types.js";

// ─── Types ───

export type { StyledSegment } from "./types.js";

export interface MobileToolRenderer {
  renderCall(args: Record<string, unknown>): StyledSegment[];
  renderResult(details: unknown, isError: boolean): StyledSegment[];
}

// ─── Helpers ───

function str(v: unknown): string {
  return typeof v === "string" ? v : "";
}

function num(v: unknown): number | undefined {
  return typeof v === "number" ? v : undefined;
}

function asRecord(v: unknown): Record<string, unknown> | undefined {
  return typeof v === "object" && v !== null ? (v as Record<string, unknown>) : undefined;
}

function recordField(
  v: Record<string, unknown> | undefined,
  key: string,
): Record<string, unknown> | undefined {
  return asRecord(v?.[key]);
}

/** Shorten long paths for display: /Users/alice/workspace/foo → ~/workspace/foo */
function shortenPath(p: string): string {
  const home = process.env.HOME || process.env.USERPROFILE || "";
  if (home && p.startsWith(home)) {
    return "~" + p.slice(home.length);
  }
  return p;
}

/** First line, truncated. */
function firstLine(s: string, max = 80): string {
  const line = s.split("\n")[0] || "";
  return line.length > max ? line.slice(0, max - 1) + "…" : line;
}

function safeTitlePart(value: string, max = 40): string {
  const line =
    value
      .split(/[\r\n]/, 1)[0]
      ?.replace(/\s+/g, " ")
      .trim() ?? "";
  return line.length > max ? `${line.slice(0, max - 1)}…` : line;
}

const waitBooleanFlags = new Set(["--all", "--json", "--help", "-h"]);
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function shortenWaitSessionId(id: string): string {
  return uuidPattern.test(id) ? `${id.slice(0, 8)}…` : id;
}

/** Collapsed wait titles include targets and --for immediately from args. */
function waitTitleSuffix(commandArgs: string[]): string {
  const ids: string[] = [];
  let condition = "either";
  for (let index = 2; index < commandArgs.length; index += 1) {
    const arg = commandArgs[index];
    if (!arg) continue;
    if (arg === "--for") {
      const value = commandArgs[index + 1];
      if (value && !value.startsWith("--")) {
        condition = value;
        index += 1;
      }
      continue;
    }
    if (arg.startsWith("--for=")) {
      const value = arg.slice("--for=".length);
      if (value) condition = value;
      continue;
    }
    if (arg.startsWith("-")) {
      const flag = arg.split("=", 1)[0] ?? arg;
      if (!waitBooleanFlags.has(flag) && !arg.includes("=")) {
        const next = commandArgs[index + 1];
        if (next && !next.startsWith("-")) index += 1;
      }
      continue;
    }
    ids.push(arg);
  }

  const shown = ids
    .slice(0, 2)
    .map((id) => safeTitlePart(shortenWaitSessionId(id)))
    .filter(Boolean);
  const extra = ids.length > 2 ? ` +${ids.length - 2}` : "";
  const idPart = shown.length > 0 ? ` ${shown.join(" ")}${extra}` : "";
  return `${idPart} · ${safeTitlePart(condition, 20) || "either"}`;
}

const styledSegmentStyles = new Set([
  "bold",
  "muted",
  "dim",
  "accent",
  "success",
  "warning",
  "error",
]);

function validatedSegments(
  value: unknown,
  onInvalid: (reason: string) => void,
): StyledSegment[] | undefined {
  if (!Array.isArray(value)) {
    onInvalid("renderer returned a non-array value");
    return undefined;
  }
  if (value.length === 0) return undefined;
  const segments: StyledSegment[] = [];
  for (const candidate of value) {
    const segment = asRecord(candidate);
    if (!segment || typeof segment.text !== "string") {
      onInvalid("segment text must be a string");
      return undefined;
    }
    if (
      segment.style !== undefined &&
      (typeof segment.style !== "string" || !styledSegmentStyles.has(segment.style))
    ) {
      onInvalid(`unsupported segment style: ${String(segment.style)}`);
      return undefined;
    }
    segments.push({
      text: segment.text,
      ...(segment.style ? { style: segment.style as StyledSegment["style"] } : {}),
    });
  }
  return segments;
}

const bashCommandSummaryMaxCharacters = 200;

// ─── Built-in Renderers ───

const bash: MobileToolRenderer = {
  renderCall(args) {
    const cmd = firstLine(str(args.command), bashCommandSummaryMaxCharacters);
    return [
      { text: "$ ", style: "bold" },
      { text: cmd, style: "accent" },
    ];
  },
  renderResult(details: unknown, isError) {
    const payload = asRecord(details);
    const code = num(payload?.exitCode);
    if (isError || (typeof code === "number" && code !== 0)) {
      return [{ text: `exit ${code ?? "?"}`, style: "error" }];
    }
    return [];
  },
};

const read: MobileToolRenderer = {
  renderCall(args) {
    const path = shortenPath(str(args.path));
    const segs: StyledSegment[] = [
      { text: "read ", style: "bold" },
      { text: path || "…", style: "accent" },
    ];
    const offset = num(args.offset);
    const limit = num(args.limit);
    if (offset !== undefined || limit !== undefined) {
      const start = offset ?? 1;
      const end = limit !== undefined ? start + limit - 1 : "";
      segs.push({ text: `:${start}${end ? `-${end}` : ""}`, style: "warning" });
    }
    return segs;
  },
  renderResult(details: unknown, isError) {
    if (isError) return []; // error icon is sufficient
    const payload = asRecord(details);
    const trunc = recordField(payload, "truncation");
    if (trunc?.truncated === true) {
      const outputLines = num(trunc.outputLines) ?? "?";
      const totalLines = num(trunc.totalLines) ?? "?";
      return [{ text: `${outputLines}/${totalLines} lines`, style: "warning" }];
    }
    return [];
  },
};

const edit: MobileToolRenderer = {
  renderCall(args) {
    const path = shortenPath(str(args.path));
    const segs: StyledSegment[] = [
      { text: "edit ", style: "bold" },
      { text: path || "…", style: "accent" },
    ];
    return segs;
  },
  renderResult(details: unknown, isError) {
    if (isError) return []; // error icon is sufficient
    const payload = asRecord(details);
    const line = num(payload?.firstChangedLine);
    if (typeof line === "number") {
      return [{ text: `applied :${line}`, style: "success" }];
    }
    return [{ text: "applied", style: "success" }];
  },
};

const write: MobileToolRenderer = {
  renderCall(args) {
    const path = shortenPath(str(args.path));
    return [
      { text: "write ", style: "bold" },
      { text: path || "…", style: "accent" },
    ];
  },
  renderResult(_details: unknown, isError) {
    if (isError) return []; // error icon is sufficient
    return [{ text: "✓", style: "success" }];
  },
};

const grep: MobileToolRenderer = {
  renderCall(args) {
    const pattern = str(args.pattern);
    const path = shortenPath(str(args.path) || ".");
    const segs: StyledSegment[] = [
      { text: "grep ", style: "bold" },
      { text: `/${pattern}/`, style: "accent" },
      { text: ` in ${path}`, style: "muted" },
    ];
    const glob = str(args.glob);
    if (glob) segs.push({ text: ` (${glob})`, style: "dim" });
    return segs;
  },
  renderResult(details: unknown, isError) {
    if (isError) return []; // error icon is sufficient
    const payload = asRecord(details);
    const limit = num(payload?.matchLimitReached);
    const trunc = recordField(payload, "truncation");
    if ((typeof limit === "number" && limit > 0) || trunc?.truncated === true) {
      const parts: string[] = [];
      if (typeof limit === "number" && limit > 0) parts.push(`${limit} match limit`);
      if (trunc?.truncated === true) parts.push("truncated");
      return [{ text: parts.join(", "), style: "warning" }];
    }
    return [];
  },
};

const find: MobileToolRenderer = {
  renderCall(args) {
    const pattern = str(args.pattern);
    const path = shortenPath(str(args.path) || ".");
    return [
      { text: "find ", style: "bold" },
      { text: pattern || "*", style: "accent" },
      { text: ` in ${path}`, style: "muted" },
    ];
  },
  renderResult(details: unknown, isError) {
    if (isError) return []; // error icon is sufficient
    const payload = asRecord(details);
    const limit = num(payload?.resultLimitReached);
    const trunc = recordField(payload, "truncation");
    if ((typeof limit === "number" && limit > 0) || trunc?.truncated === true) {
      const parts: string[] = [];
      if (typeof limit === "number" && limit > 0) parts.push(`${limit} result limit`);
      if (trunc?.truncated === true) parts.push("truncated");
      return [{ text: parts.join(", "), style: "warning" }];
    }
    return [];
  },
};

const ls: MobileToolRenderer = {
  renderCall(args) {
    const path = shortenPath(str(args.path) || ".");
    return [
      { text: "ls ", style: "bold" },
      { text: path, style: "accent" },
    ];
  },
  renderResult(details: unknown, isError) {
    if (isError) return []; // error icon is sufficient
    const payload = asRecord(details);
    const limit = num(payload?.entryLimitReached);
    const trunc = recordField(payload, "truncation");
    if ((typeof limit === "number" && limit > 0) || trunc?.truncated === true) {
      const parts: string[] = [];
      if (typeof limit === "number" && limit > 0) parts.push(`${limit} entry limit`);
      if (trunc?.truncated === true) parts.push("truncated");
      return [{ text: parts.join(", "), style: "warning" }];
    }
    return [];
  },
};

const todo: MobileToolRenderer = {
  renderCall(args) {
    const action = str(args.action);
    const segs: StyledSegment[] = [
      { text: "todo ", style: "bold" },
      { text: action, style: "accent" },
    ];
    const title = str(args.title);
    if (title) segs.push({ text: ` "${firstLine(title, 50)}"`, style: "muted" });
    const id = str(args.id);
    if (id) segs.push({ text: ` ${id}`, style: "dim" });
    return segs;
  },
  renderResult(details: unknown, isError) {
    const payload = asRecord(details);
    if (isError || payload?.error) return []; // error icon is sufficient
    const action = str(payload?.action);
    if (action === "list" || action === "list-all") {
      const todos = payload?.todos;
      const count = Array.isArray(todos) ? todos.length : 0;
      return [{ text: `${count} todo(s)`, style: "success" }];
    }
    return [{ text: "✓", style: "success" }];
  },
};

// ─── Autoresearch ───

const init_experiment: MobileToolRenderer = {
  renderCall(args) {
    return [
      { text: "init ", style: "bold" },
      { text: str(args.name) || "experiment", style: "accent" },
    ];
  },
  renderResult(_details: unknown, isError) {
    if (isError) return [{ text: "failed", style: "error" }];
    return [{ text: "initialized", style: "success" }];
  },
};

const run_experiment: MobileToolRenderer = {
  renderCall(args) {
    const cmd = firstLine(str(args.command));
    return [
      { text: "run ", style: "bold" },
      { text: cmd, style: "muted" },
    ];
  },
  renderResult(details: unknown, isError) {
    const payload = asRecord(details);
    if (isError || !payload) return [{ text: "failed", style: "error" }];

    const duration = num(payload.durationSeconds);
    const timedOut = payload.timedOut === true;
    const checksPass = payload.checksPass;
    const checksDuration = num(payload.checksDuration);

    if (timedOut) {
      return [{ text: `timeout ${duration?.toFixed(1) ?? "?"}s`, style: "error" }];
    }

    if (payload.crashed === true || payload.passed === false) {
      const code = num(payload.exitCode);
      return [
        { text: `exit=${code ?? "?"}`, style: "error" },
        { text: ` ${duration?.toFixed(1) ?? "?"}s`, style: "dim" },
      ];
    }

    const segs: StyledSegment[] = [{ text: `${duration?.toFixed(1) ?? "?"}s`, style: "success" }];

    if (checksPass === false) {
      segs.push({ text: ` checks failed`, style: "error" });
      if (checksDuration !== undefined) {
        segs.push({ text: ` ${checksDuration.toFixed(1)}s`, style: "dim" });
      }
    } else if (checksPass === true) {
      segs.push({ text: ` checks ok`, style: "success" });
    }

    return segs;
  },
};

const log_experiment: MobileToolRenderer = {
  renderCall(args) {
    const status = str(args.status);
    const desc = firstLine(str(args.description), 60);
    const style: StyledSegment["style"] =
      status === "keep"
        ? "success"
        : status === "crash" || status === "checks_failed"
          ? "error"
          : "warning";
    const icon =
      status === "keep" ? "+" : status === "crash" ? "x" : status === "checks_failed" ? "!" : "-";
    return [
      { text: `${icon} `, style },
      { text: desc || "experiment", style: "muted" },
    ];
  },
  renderResult(details: unknown, isError) {
    if (isError) return [{ text: "failed", style: "error" }];
    const payload = asRecord(details);
    const exp = asRecord(payload?.experiment);
    const st = asRecord(payload?.state);
    if (!exp || !st) return [];

    const status = str(exp.status);
    const metric = num(exp.metric);
    const metricName = str(st.metricName);
    const metricUnit = str(st.metricUnit);
    const bestMetric = num(st.bestMetric);

    const style: StyledSegment["style"] =
      status === "keep"
        ? "success"
        : status === "crash" || status === "checks_failed"
          ? "error"
          : "warning";

    const segs: StyledSegment[] = [{ text: status, style }];

    if (metric !== undefined) {
      const fmtMetric = metric === Math.round(metric) ? String(metric) : metric.toFixed(2);
      segs.push({ text: ` ${metricName}: ${fmtMetric}${metricUnit}`, style: "accent" });

      // Delta vs baseline
      if (bestMetric !== undefined && bestMetric !== 0 && metric !== bestMetric) {
        const pct = ((metric - bestMetric) / bestMetric) * 100;
        const sign = pct > 0 ? "+" : "";
        const direction = str(st.bestDirection);
        const improved = direction === "higher" ? metric > bestMetric : metric < bestMetric;
        segs.push({
          text: ` (${sign}${pct.toFixed(1)}%)`,
          style: improved ? "success" : "error",
        });
      }
    }

    return segs;
  },
};

function askQuestionLabel(question: Record<string, unknown> | undefined): string {
  const id = str(question?.id);
  return firstLine(str(question?.question) || id, 120);
}

function askAnswerValueLabel(question: Record<string, unknown> | undefined, value: string): string {
  const options = Array.isArray(question?.options)
    ? (question.options as Array<Record<string, unknown>>)
    : [];
  const matched = options.find(
    (option) => str(option.value) === value || str(option.label) === value,
  );
  return str(matched?.label) || value;
}

function askAnswerLabel(question: Record<string, unknown> | undefined, answer: unknown): string {
  if (Array.isArray(answer)) {
    return answer.map((value) => askAnswerValueLabel(question, str(value))).join(", ");
  }
  return askAnswerValueLabel(question, str(answer));
}

const oppi: MobileToolRenderer = {
  renderCall(args) {
    const rawCommandArgs = Array.isArray(args.args) ? args.args.map(str).filter(Boolean) : [];
    const normalizedArgs = rawCommandArgs[0] === "oppi" ? rawCommandArgs.slice(1) : rawCommandArgs;
    const commandArgs =
      normalizedArgs[0] === "help" && normalizedArgs.length > 1
        ? normalizedArgs.slice(1)
        : normalizedArgs[1] === "help"
          ? [normalizedArgs[0], ...normalizedArgs.slice(2)]
          : normalizedArgs;
    const rawResource = commandArgs[0]?.startsWith("--") ? "command" : commandArgs[0] || "command";
    const resource = safeTitlePart(rawResource) || "command";
    const action =
      resource === "command" || commandArgs[1]?.startsWith("--")
        ? ""
        : safeTitlePart(commandArgs[1] || "");
    const waitSuffix =
      resource === "session" && action === "wait" ? waitTitleSuffix(commandArgs) : "";
    return [
      { text: "oppi ", style: "bold" },
      { text: resource, style: "accent" },
      ...(action ? [{ text: ` ${action}${waitSuffix}`, style: "muted" as const }] : []),
    ];
  },
  renderResult(details, isError) {
    if (isError) return [{ text: "failed", style: "error" }];
    const payload = asRecord(details);
    if (payload?.outcome === "cancelled") return [{ text: "cancelled", style: "dim" }];
    const data = asRecord(payload?.data);
    const args = Array.isArray(payload?.args) ? payload.args.map(str) : [];
    if (args[0] === "session" && args[1] === "search") {
      const count =
        num(data?.total_results) ?? (Array.isArray(data?.results) ? data.results.length : 0);
      return [{ text: `${count} ${count === 1 ? "result" : "results"}`, style: "success" }];
    }
    return [];
  },
};

const ask: MobileToolRenderer = {
  renderCall(args) {
    const qs = Array.isArray(args.questions)
      ? (args.questions as Array<Record<string, unknown>>)
      : [];
    const segs: StyledSegment[] = [{ text: "ask ", style: "bold" }];

    if (qs.length === 0) {
      segs.push({ text: "question", style: "muted" });
      return segs;
    }

    segs.push({
      text: qs.length === 1 ? "1 question" : `${qs.length} questions`,
      style: "muted",
    });
    return segs;
  },
  renderResult(details: unknown, isError) {
    if (isError) return [];
    const payload = asRecord(details);
    if (payload?.allIgnored === true) {
      return [{ text: "all ignored", style: "dim" }];
    }
    const answers = asRecord(payload?.answers) ?? {};
    const questions = Array.isArray(payload?.questions)
      ? (payload.questions as Array<Record<string, unknown>>)
      : [];
    const keys = Object.keys(answers);
    if (keys.length === 0) return [{ text: "no answers", style: "warning" }];

    const segs: StyledSegment[] = [];
    for (const q of questions) {
      const qId = str(q?.id);
      const label = askQuestionLabel(q);
      const a = answers[qId];
      if (a === undefined) {
        segs.push({ text: label, style: "dim" }, { text: ": skipped\n", style: "dim" });
        continue;
      }
      const display = askAnswerLabel(q, a);
      segs.push(
        { text: "\u2713 ", style: "success" },
        { text: label, style: "muted" },
        { text: ": ", style: "dim" },
        { text: display, style: "accent" },
        { text: "\n", style: "dim" },
      );
    }
    // Trim trailing newline
    if (segs.length > 0) {
      const last = segs[segs.length - 1];
      if (last.text === "\n") segs.pop();
    }
    return segs;
  },
};

// ─── Registry ───

const BUILTIN_RENDERERS: Record<string, MobileToolRenderer> = {
  ask,
  oppi,
  bash,
  read,
  edit,
  write,
  grep,
  find,
  ls,
  todo,
  init_experiment,
  run_experiment,
  log_experiment,
};

export class MobileRendererRegistry {
  private readonly log = createLogger();
  private readonly invalidWarnings = new Set<string>();
  private renderers = new Map<string, MobileToolRenderer>();

  constructor() {
    // Load built-in renderers
    for (const [name, renderer] of Object.entries(BUILTIN_RENDERERS)) {
      this.renderers.set(name, renderer);
    }
  }

  /** Register a renderer (extension sidecar or config override). */
  register(toolName: string, renderer: MobileToolRenderer): void {
    this.renderers.set(toolName, renderer);
  }

  /** Register multiple renderers from a sidecar module. */
  registerAll(renderers: Record<string, MobileToolRenderer>): void {
    for (const [name, renderer] of Object.entries(renderers)) {
      if (
        renderer &&
        typeof renderer.renderCall === "function" &&
        typeof renderer.renderResult === "function"
      ) {
        this.renderers.set(name, renderer);
      }
    }
  }

  /** Render call segments, returning undefined if no renderer or on error. */
  renderCall(toolName: string, args: Record<string, unknown>): StyledSegment[] | undefined {
    const renderer = this.renderers.get(toolName);
    if (!renderer) return undefined;
    try {
      return validatedSegments(renderer.renderCall(args), (reason) =>
        this.warnInvalidRenderer(toolName, "call", reason),
      );
    } catch (error) {
      this.warnInvalidRenderer(
        toolName,
        "call",
        error instanceof Error ? error.message : String(error),
      );
      return undefined;
    }
  }

  /** Render result segments, returning undefined if no renderer or on error. */
  renderResult(toolName: string, details: unknown, isError: boolean): StyledSegment[] | undefined {
    const renderer = this.renderers.get(toolName);
    if (!renderer) return undefined;
    try {
      return validatedSegments(renderer.renderResult(details, isError), (reason) =>
        this.warnInvalidRenderer(toolName, "result", reason),
      );
    } catch (error) {
      this.warnInvalidRenderer(
        toolName,
        "result",
        error instanceof Error ? error.message : String(error),
      );
      return undefined;
    }
  }

  private warnInvalidRenderer(toolName: string, phase: "call" | "result", reason: string): void {
    const key = `${toolName}\u0000${phase}\u0000${reason}`;
    if (this.invalidWarnings.has(key)) return;
    this.invalidWarnings.add(key);
    this.log.warn("mobile_renderer.invalid_segments", { toolName, phase, reason });
  }

  /** Number of registered renderers. */
  get size(): number {
    return this.renderers.size;
  }

  /** Check if a tool has a renderer. */
  has(toolName: string): boolean {
    return this.renderers.has(toolName);
  }

  /** Default directory for user-provided mobile renderers. */
  static readonly RENDERERS_DIR = join(homedir(), ".pi", "agent", "mobile-renderers");

  /**
   * Discover renderer files in the mobile-renderers directory.
   *
   * Every .ts/.js file in the directory is treated as a renderer module.
   * Returns absolute paths to discovered files.
   */
  static discoverRenderers(renderersDir: string = MobileRendererRegistry.RENDERERS_DIR): string[] {
    if (!existsSync(renderersDir)) return [];

    const files: string[] = [];
    for (const entry of readdirSync(renderersDir)) {
      if (entry.startsWith(".")) continue;
      if (entry.endsWith(".ts") || entry.endsWith(".js")) {
        files.push(join(renderersDir, entry));
      }
    }
    return files;
  }

  /**
   * Load a single renderer module and register its tools.
   *
   * Renderer modules export a default object keyed by tool name:
   * ```ts
   * export default {
   *   remember: { renderCall(args) {...}, renderResult(details, isError) {...} },
   *   recall:   { renderCall(args) {...}, renderResult(details, isError) {...} },
   * }
   * ```
   *
   * Node 25+ natively imports .ts files (type stripping).
   */
  async loadRenderer(filePath: string): Promise<{ loaded: string[]; errors: string[] }> {
    const loaded: string[] = [];
    const errors: string[] = [];

    try {
      const mod = await import(filePath);
      const renderers = mod.default ?? mod;

      if (typeof renderers !== "object" || renderers === null) {
        errors.push(`${filePath}: default export is not an object`);
        return { loaded, errors };
      }

      for (const [toolName, renderer] of Object.entries(renderers)) {
        const candidate = asRecord(renderer);
        const renderCall = candidate?.renderCall;
        const renderResult = candidate?.renderResult;

        if (typeof renderCall === "function" && typeof renderResult === "function") {
          this.renderers.set(toolName, {
            renderCall: (args) => renderCall(args) as StyledSegment[],
            renderResult: (details, isError) => renderResult(details, isError) as StyledSegment[],
          });
          loaded.push(toolName);
        } else {
          errors.push(`${filePath}: "${toolName}" missing renderCall or renderResult`);
        }
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      errors.push(`${filePath}: ${message}`);
    }

    return { loaded, errors };
  }

  /**
   * Discover and load all renderer files from the mobile-renderers directory.
   * Returns summary of what was loaded and any errors.
   */
  async loadAllRenderers(renderersDir?: string): Promise<{ loaded: string[]; errors: string[] }> {
    const files = MobileRendererRegistry.discoverRenderers(renderersDir);
    const allLoaded: string[] = [];
    const allErrors: string[] = [];

    for (const filePath of files) {
      const { loaded, errors } = await this.loadRenderer(filePath);
      allLoaded.push(...loaded);
      allErrors.push(...errors);
    }

    return { loaded: allLoaded, errors: allErrors };
  }
}
