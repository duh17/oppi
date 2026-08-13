#!/usr/bin/env bun

/**
 * Compare bounded Oppi agent-flow traces without retaining prompt or response text.
 *
 * The collector accepts raw Pi JSONL traces or the sanitized row export produced by
 * the personal Oppi trace analysis. It keeps only command shape, outcome, sizes,
 * timings, token totals, and disclosure depth so the result can be replayed and
 * compared without becoming a prompt/response archive.
 */

import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { extname, join, resolve } from "node:path";

export const EVALUATION_SCENARIOS = [
  "session-orientation",
  "current-progress",
  "latest-response",
  "historical-investigation",
  "multi-session-monitoring",
  "dialog-handling",
  "safe-mutation",
  "unclassified",
] as const;

export type EvaluationScenario = (typeof EVALUATION_SCENARIOS)[number];

type KnownRoute = {
  command: string;
  action: string;
  view?: string;
};

type EvaluationStep = KnownRoute & {
  ok: boolean;
  completed: boolean;
  resultBytes: number;
  roundTripMs: number | null;
  flags: string[];
};

export type EvaluationJob = {
  id: string;
  scenario: EvaluationScenario;
  correct: boolean;
  calls: number;
  roundTrips: number;
  elapsedMs: number | null;
  invalidCalls: number;
  repeatedCalls: number;
  resultBytes: number;
  estimatedResultTokens: number;
  modelTokens: number | null;
  disclosureDepth: number;
  steps: EvaluationStep[];
};

export type EvaluationBundle = {
  schemaVersion: 1;
  variant: string;
  source: {
    kind: "pi-jsonl" | "sanitized-rows" | "bundle";
    files: number;
    jobs: number;
  };
  jobs: EvaluationJob[];
};

type NumericStats = {
  count: number;
  median: number | null;
  p90: number | null;
};

export type ScenarioSummary = {
  jobs: number;
  correctness: {
    correct: number;
    incorrect: number;
    rate: number | null;
  };
  metrics: {
    calls: NumericStats;
    roundTrips: NumericStats;
    elapsedMs: NumericStats;
    invalidCalls: NumericStats;
    repeatedCalls: NumericStats;
    resultBytes: NumericStats;
    estimatedResultTokens: NumericStats;
    modelTokens: NumericStats;
    disclosureDepth: NumericStats;
  };
};

export type EvaluationSummary = {
  variant: string;
  jobs: number;
  scenarios: Record<EvaluationScenario, ScenarioSummary>;
};

export type EvaluationComparison = {
  baseline: EvaluationSummary;
  candidate: EvaluationSummary;
  delta: Record<
    EvaluationScenario,
    Record<"calls" | "roundTrips" | "elapsedMs" | "resultBytes" | "disclosureDepth", number | null>
  >;
};

type RawCall = {
  id: string;
  route: KnownRoute;
  flags: string[];
  timestamp: number | null;
  result?: {
    ok: boolean;
    bytes: number;
    timestamp: number | null;
  };
};

type SanitizedRow = {
  file?: unknown;
  timestamp?: unknown;
  command?: unknown;
  action?: unknown;
  view?: unknown;
  result_bytes?: unknown;
  is_error?: unknown;
};

const KNOWN_COMMANDS = new Set([
  "agent",
  "config",
  "doctor",
  "help",
  "init",
  "pair",
  "schedule",
  "serve",
  "server",
  "session",
  "start",
  "status",
  "token",
  "update",
  "version",
  "wait",
  "workspace",
  "worktree",
]);

const KNOWN_ACTIONS = new Set([
  "abort",
  "archive",
  "changes",
  "create",
  "delete",
  "dialogs",
  "diff",
  "events",
  "file",
  "fork",
  "get",
  "inspect",
  "install",
  "list",
  "open",
  "pause",
  "preview",
  "read",
  "remove",
  "rename",
  "respond",
  "restart",
  "restore",
  "resume",
  "rotate",
  "run",
  "runs",
  "search",
  "send",
  "set",
  "show",
  "start",
  "status",
  "stop",
  "trace",
  "trace-outline",
  "trace-page",
  "uninstall",
  "update",
  "validate",
  "wait",
  "watch",
]);

const KNOWN_VIEWS = new Set(["summary", "response", "outline", "messages", "tools"]);
const MUTATING_ACTIONS = new Set([
  "abort",
  "archive",
  "create",
  "delete",
  "fork",
  "install",
  "open",
  "pause",
  "remove",
  "rename",
  "respond",
  "restart",
  "restore",
  "resume",
  "rotate",
  "run",
  "send",
  "set",
  "stop",
  "uninstall",
  "update",
]);
const READ_ACTIONS = new Set([
  "changes",
  "dialogs",
  "diff",
  "events",
  "file",
  "get",
  "inspect",
  "list",
  "preview",
  "read",
  "runs",
  "search",
  "show",
  "status",
  "trace",
  "trace-outline",
  "trace-page",
  "validate",
  "wait",
  "watch",
]);

export function collectEvaluationBundle(input: string, variant: string): EvaluationBundle {
  const inputPath = resolve(input);
  if (!existsSync(inputPath)) throw new Error(`Evaluation input does not exist: ${input}`);

  if (extname(inputPath).toLowerCase() === ".json") {
    const parsed: unknown = JSON.parse(readFileSync(inputPath, "utf8"));
    if (isEvaluationBundle(parsed)) {
      return {
        ...parsed,
        variant,
        source: { ...parsed.source, kind: "bundle" },
      };
    }
    if (isSanitizedRowsDocument(parsed)) {
      return bundleFromSanitizedRows(parsed.rows, variant);
    }
    throw new Error("JSON input must contain an evaluation bundle or sanitized rows");
  }

  const files = traceFiles(inputPath);
  if (files.length === 0) throw new Error(`No .jsonl trace files found under ${input}`);
  return {
    schemaVersion: 1,
    variant,
    source: { kind: "pi-jsonl", files: files.length, jobs: files.length },
    jobs: files.map((file) => collectTraceJob(file)),
  };
}

export function summarizeEvaluationBundle(bundle: EvaluationBundle): EvaluationSummary {
  const scenarios = Object.fromEntries(
    EVALUATION_SCENARIOS.map((scenario) => {
      const jobs = bundle.jobs.filter((job) => job.scenario === scenario);
      return [scenario, summarizeScenario(jobs)];
    }),
  ) as Record<EvaluationScenario, ScenarioSummary>;

  return { variant: bundle.variant, jobs: bundle.jobs.length, scenarios };
}

export function compareEvaluationBundles(
  baseline: EvaluationBundle,
  candidate: EvaluationBundle,
): EvaluationComparison {
  const baselineSummary = summarizeEvaluationBundle(baseline);
  const candidateSummary = summarizeEvaluationBundle(candidate);
  const delta = Object.fromEntries(
    EVALUATION_SCENARIOS.map((scenario) => {
      const before = baselineSummary.scenarios[scenario];
      const after = candidateSummary.scenarios[scenario];
      return [
        scenario,
        {
          calls: medianDelta(before.metrics.calls, after.metrics.calls),
          roundTrips: medianDelta(before.metrics.roundTrips, after.metrics.roundTrips),
          elapsedMs: medianDelta(before.metrics.elapsedMs, after.metrics.elapsedMs),
          resultBytes: medianDelta(before.metrics.resultBytes, after.metrics.resultBytes),
          disclosureDepth: medianDelta(
            before.metrics.disclosureDepth,
            after.metrics.disclosureDepth,
          ),
        },
      ];
    }),
  ) as EvaluationComparison["delta"];

  return { baseline: baselineSummary, candidate: candidateSummary, delta };
}

export function renderEvaluationMarkdown(comparison: EvaluationComparison): string {
  const lines = [
    "# Oppi CLI agent-flow evaluation",
    "",
    "Correctness is reported before efficiency. Metrics are derived from sanitized command shape, outcomes, sizes, timings, and token totals; prompt and response contents are not retained.",
    "",
    "## Correctness",
    "",
    "| Scenario | Baseline | Candidate |",
    "| --- | ---: | ---: |",
  ];

  for (const scenario of EVALUATION_SCENARIOS) {
    const before = comparison.baseline.scenarios[scenario].correctness;
    const after = comparison.candidate.scenarios[scenario].correctness;
    lines.push(
      `| ${scenario} | ${formatRate(before.rate, before.correct, before.incorrect)} | ${formatRate(after.rate, after.correct, after.incorrect)} |`,
    );
  }

  lines.push(
    "",
    "## Efficiency and disclosure",
    "",
    "Values are `median / P90`; a dash means the source did not provide that metric.",
    "",
    "| Scenario | Calls | Round trips | Elapsed ms | Invalid calls | Repeated calls | Result bytes | Estimated result tokens | Model tokens | Disclosure depth |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );

  for (const scenario of EVALUATION_SCENARIOS) {
    const before = comparison.baseline.scenarios[scenario];
    const after = comparison.candidate.scenarios[scenario];
    lines.push(
      `| ${scenario} | ${formatMetric(before.metrics.calls, after.metrics.calls)} | ${formatMetric(before.metrics.roundTrips, after.metrics.roundTrips)} | ${formatMetric(before.metrics.elapsedMs, after.metrics.elapsedMs)} | ${formatMetric(before.metrics.invalidCalls, after.metrics.invalidCalls)} | ${formatMetric(before.metrics.repeatedCalls, after.metrics.repeatedCalls)} | ${formatMetric(before.metrics.resultBytes, after.metrics.resultBytes)} | ${formatMetric(before.metrics.estimatedResultTokens, after.metrics.estimatedResultTokens)} | ${formatMetric(before.metrics.modelTokens, after.metrics.modelTokens)} | ${formatMetric(before.metrics.disclosureDepth, after.metrics.disclosureDepth)} |`,
    );
  }

  lines.push(
    "",
    "## Interpretation",
    "",
    "- A positive delta means the candidate median increased; lower is generally better for calls, round trips, bytes, and disclosure depth.",
    "- Correctness is heuristic unless the source bundle was curated with an external task verdict. The collector does not infer user intent from prompt or response text.",
    "- Model-token and elapsed-time fields are unavailable for sanitized row exports that contain neither assistant usage nor matched call/result timestamps.",
    "",
  );
  return `${lines.join("\n")}\n`;
}

function collectTraceJob(file: string): EvaluationJob {
  const calls = new Map<string, RawCall>();
  const orderedCalls: RawCall[] = [];
  let modelTokens = 0;
  let hasModelTokens = false;

  for (const line of readLines(file)) {
    if (!isRecord(line)) continue;
    const timestamp = timestampValue(line.timestamp);
    const message = isRecord(line.message) ? line.message : undefined;
    const usage = isRecord(line.usage) ? line.usage : undefined;
    const usageTotal = usage ? numberValue(usage.totalTokens) : null;
    if (usageTotal !== null) {
      modelTokens += usageTotal;
      hasModelTokens = true;
    }

    if (!message) continue;
    const role = typeof message.role === "string" ? message.role : "";
    if (role === "assistant") {
      for (const item of arrayValue(message.content)) {
        if (!isRecord(item) || item.type !== "toolCall" || item.name !== "oppi") continue;
        const id = typeof item.id === "string" ? item.id : `call-${orderedCalls.length}`;
        const args = isRecord(item.arguments) ? item.arguments.args : undefined;
        const route = routeFromArgs(arrayValue(args).map(stringValue));
        const call: RawCall = {
          id,
          route: route.route,
          flags: route.flags,
          timestamp,
        };
        calls.set(id, call);
        orderedCalls.push(call);
      }
      continue;
    }
    if (role !== "toolResult") continue;

    const id = stringValue(message.toolCallId);
    const call = calls.get(id);
    if (!call) continue;
    const bytes = Buffer.byteLength(
      arrayValue(message.content)
        .filter(isRecord)
        .map((item) => (typeof item.text === "string" ? item.text : ""))
        .join(""),
      "utf8",
    );
    call.result = {
      ok: message.isError !== true,
      bytes,
      timestamp,
    };
  }

  const traceTimes = orderedCalls
    .flatMap((call) => [call.timestamp, call.result?.timestamp ?? null])
    .filter((value): value is number => value !== null);
  const traceElapsedMs =
    traceTimes.length > 1 ? Math.max(...traceTimes) - Math.min(...traceTimes) : null;

  return jobFromSteps(
    hashId(file),
    orderedCalls.map((call) => ({
      ...call.route,
      flags: call.flags,
      ok: call.result?.ok ?? false,
      completed: call.result !== undefined,
      resultBytes: call.result?.bytes ?? 0,
      roundTripMs: elapsedBetween(call.timestamp, call.result?.timestamp ?? null),
    })),
    hasModelTokens ? modelTokens : null,
    traceElapsedMs,
  );
}

function bundleFromSanitizedRows(rows: SanitizedRow[], variant: string): EvaluationBundle {
  const groups = new Map<string, SanitizedRow[]>();
  for (const row of rows) {
    const key = typeof row.file === "string" && row.file ? row.file : "unknown";
    const group = groups.get(key) ?? [];
    group.push(row);
    groups.set(key, group);
  }

  const jobs = [...groups.entries()].map(([key, group]) => {
    const steps = group.map((row) => {
      const route = routeFromParts(
        stringValue(row.command),
        stringValue(row.action),
        stringValue(row.view),
      );
      return {
        ...route.route,
        flags: [],
        ok: row.is_error !== true,
        completed: true,
        resultBytes: Math.max(0, numberValue(row.result_bytes) ?? 0),
        roundTripMs: null,
      } satisfies EvaluationStep;
    });
    return jobFromSteps(hashId(key), steps, null);
  });

  return {
    schemaVersion: 1,
    variant,
    source: { kind: "sanitized-rows", files: groups.size, jobs: jobs.length },
    jobs,
  };
}

function jobFromSteps(
  id: string,
  steps: EvaluationStep[],
  modelTokens: number | null,
  elapsedMsOverride?: number | null,
): EvaluationJob {
  const completed = steps.filter((step) => step.completed);
  const roundTrips = completed.length;
  const elapsedValues = steps
    .map((step) => step.roundTripMs)
    .filter((value): value is number => value !== null);
  const elapsedMs =
    elapsedMsOverride !== undefined
      ? elapsedMsOverride
      : elapsedValues.length > 0
        ? elapsedValues.reduce((sum, value) => sum + value, 0)
        : null;
  const invalidCalls = steps.filter((step) => !step.completed || !step.ok).length;
  const signatures = new Set<string>();
  let repeatedCalls = 0;
  for (const step of steps) {
    const signature = [step.command, step.action, step.view ?? "", ...step.flags].join("|");
    if (signatures.has(signature)) repeatedCalls += 1;
    signatures.add(signature);
  }
  const resultBytes = steps.reduce((sum, step) => sum + step.resultBytes, 0);
  const disclosureDepth = steps.reduce((max, step) => Math.max(max, disclosureDepthFor(step)), 0);
  const scenario = classifyScenario(steps);

  return {
    id,
    scenario,
    correct: isTaskCorrect(scenario, steps),
    calls: steps.length,
    roundTrips,
    elapsedMs,
    invalidCalls,
    repeatedCalls,
    resultBytes,
    estimatedResultTokens: Math.ceil(resultBytes / 4),
    modelTokens,
    disclosureDepth,
    steps,
  };
}

function classifyScenario(steps: EvaluationStep[]): EvaluationScenario {
  const hasRoute = (command: string, action: string, view?: string): boolean =>
    steps.some(
      (step) =>
        step.command === command &&
        step.action === action &&
        (view === undefined || step.view === view),
    );
  const hasSessionAction = (actions: string[]): boolean =>
    steps.some((step) => step.command === "session" && actions.includes(step.action));

  if (hasSessionAction(["dialogs", "respond"])) return "dialog-handling";
  if (hasSessionAction(["wait", "watch"]) || hasRoute("wait", "session")) {
    return "multi-session-monitoring";
  }
  if (hasRoute("session", "inspect", "response")) return "latest-response";
  if (
    hasRoute("session", "inspect", "outline") ||
    hasSessionAction(["messages", "tools", "trace", "trace-page", "trace-outline", "tool-output"])
  ) {
    return "historical-investigation";
  }
  if (hasRoute("session", "inspect", "summary")) return "current-progress";
  if (hasRoute("session", "list")) return "session-orientation";
  if (steps.some((step) => MUTATING_ACTIONS.has(step.action))) return "safe-mutation";
  return "unclassified";
}

function isTaskCorrect(scenario: EvaluationScenario, steps: EvaluationStep[]): boolean {
  if (steps.length === 0 || steps.some((step) => !step.completed || !step.ok)) return false;
  const has = (predicate: (step: EvaluationStep) => boolean): boolean => steps.some(predicate);
  switch (scenario) {
    case "session-orientation":
      return has((step) => step.command === "session" && step.action === "list");
    case "current-progress":
      return has(
        (step) =>
          step.command === "session" && step.action === "inspect" && step.view === "summary",
      );
    case "latest-response":
      return has(
        (step) =>
          step.command === "session" && step.action === "inspect" && step.view === "response",
      );
    case "historical-investigation":
      return has(
        (step) =>
          step.command === "session" &&
          [
            "outline",
            "messages",
            "tools",
            "trace",
            "trace-page",
            "trace-outline",
            "tool-output",
          ].includes(step.view ?? step.action),
      );
    case "multi-session-monitoring":
      return has(
        (step) =>
          (step.command === "session" && ["wait", "watch"].includes(step.action)) ||
          (step.command === "wait" && step.action === "session"),
      );
    case "dialog-handling":
      return has((step) => step.command === "session" && step.action === "dialogs");
    case "safe-mutation": {
      const firstMutation = steps.findIndex((step) => MUTATING_ACTIONS.has(step.action));
      return (
        firstMutation > 0 &&
        steps.slice(0, firstMutation).some((step) => READ_ACTIONS.has(step.action)) &&
        steps.slice(firstMutation).some((step) => MUTATING_ACTIONS.has(step.action))
      );
    }
    case "unclassified":
      return false;
  }
}

function disclosureDepthFor(step: EvaluationStep): number {
  if (step.command === "session") {
    if (step.action === "list") return 1;
    if (step.action === "inspect") {
      if (step.view === "summary" || step.view === "response") return 2;
      if (step.view === "outline") return 3;
      return 4;
    }
    if (["messages", "tools", "trace", "trace-outline"].includes(step.action)) return 4;
    if (["trace-page", "tool-output", "read", "diff", "changes"].includes(step.action)) return 5;
    return 2;
  }
  if (step.action === "list" || step.action === "status" || step.action === "show") return 1;
  return 2;
}

function summarizeScenario(jobs: EvaluationJob[]): ScenarioSummary {
  const correct = jobs.filter((job) => job.correct).length;
  return {
    jobs: jobs.length,
    correctness: {
      correct,
      incorrect: jobs.length - correct,
      rate: jobs.length > 0 ? correct / jobs.length : null,
    },
    metrics: {
      calls: numericStats(jobs.map((job) => job.calls)),
      roundTrips: numericStats(jobs.map((job) => job.roundTrips)),
      elapsedMs: numericStats(nonNull(jobs.map((job) => job.elapsedMs))),
      invalidCalls: numericStats(jobs.map((job) => job.invalidCalls)),
      repeatedCalls: numericStats(jobs.map((job) => job.repeatedCalls)),
      resultBytes: numericStats(jobs.map((job) => job.resultBytes)),
      estimatedResultTokens: numericStats(jobs.map((job) => job.estimatedResultTokens)),
      modelTokens: numericStats(nonNull(jobs.map((job) => job.modelTokens))),
      disclosureDepth: numericStats(jobs.map((job) => job.disclosureDepth)),
    },
  };
}

function numericStats(values: number[]): NumericStats {
  const sorted = [...values].filter(Number.isFinite).sort((a, b) => a - b);
  return {
    count: sorted.length,
    median: percentile(sorted, 0.5),
    p90: percentile(sorted, 0.9),
  };
}

function percentile(sorted: number[], fraction: number): number | null {
  if (sorted.length === 0) return null;
  return sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)] ?? null;
}

function medianDelta(before: NumericStats, after: NumericStats): number | null {
  if (before.median === null || after.median === null) return null;
  return after.median - before.median;
}

function formatRate(rate: number | null, correct: number, incorrect: number): string {
  if (rate === null) return "—";
  return `${(rate * 100).toFixed(1)}% (${correct}/${correct + incorrect})`;
}

function formatMetric(before: NumericStats, after: NumericStats): string {
  return `${formatPair(before.median, before.p90)} → ${formatPair(after.median, after.p90)}`;
}

function formatPair(median: number | null, p90: number | null): string {
  if (median === null || p90 === null) return "—";
  return `${formatNumber(median)} / ${formatNumber(p90)}`;
}

function formatNumber(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(1);
}

function routeFromArgs(args: string[]): { route: KnownRoute; flags: string[] } {
  const command = args[0] ?? "";
  const action = args[1] ?? "";
  const route = routeFromParts(command, action, valueAfterFlag(args, "--view"));
  const flags = args
    .filter((arg) => arg.startsWith("--"))
    .map((arg) => arg.slice(2).split("=", 1)[0])
    .filter((flag) => /^[a-z][a-z0-9-]*$/i.test(flag))
    .sort();
  return { route: route.route, flags: [...new Set(flags)] };
}

function routeFromParts(
  commandValue: string,
  actionValue: string,
  viewValue: string,
): { route: KnownRoute } {
  const command = KNOWN_COMMANDS.has(commandValue) ? commandValue : "unknown";
  const action = KNOWN_ACTIONS.has(actionValue) ? actionValue : "";
  const view = KNOWN_VIEWS.has(viewValue) ? viewValue : undefined;
  return { route: { command, action, ...(view ? { view } : {}) } };
}

function valueAfterFlag(args: string[], flag: string): string {
  const index = args.indexOf(flag);
  if (index !== -1) return args[index + 1] ?? "";
  const inline = args.find((arg) => arg.startsWith(`${flag}=`));
  return inline?.slice(flag.length + 1) ?? "";
}

function traceFiles(inputPath: string): string[] {
  const stat = statSync(inputPath);
  if (stat.isFile()) return inputPath.endsWith(".jsonl") ? [inputPath] : [];
  const files: string[] = [];
  for (const entry of readdirSync(inputPath, { withFileTypes: true })) {
    const child = join(inputPath, entry.name);
    if (entry.isDirectory()) files.push(...traceFiles(child));
    else if (entry.isFile() && entry.name.endsWith(".jsonl")) files.push(child);
  }
  return files.sort();
}

function readLines(file: string): unknown[] {
  return readFileSync(file, "utf8")
    .split(/\r?\n/)
    .filter(Boolean)
    .flatMap((line) => {
      try {
        return [JSON.parse(line) as unknown];
      } catch {
        return [];
      }
    });
}

function hashId(value: string): string {
  return createHash("sha256").update(value).digest("hex").slice(0, 16);
}

function elapsedBetween(start: number | null, end: number | null): number | null {
  if (start === null || end === null || end < start) return null;
  return end - start;
}

function nonNull(values: Array<number | null>): number[] {
  return values.filter((value): value is number => value !== null);
}

function arrayValue(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function timestampValue(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value !== "string") return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function isSanitizedRowsDocument(value: unknown): value is { rows: SanitizedRow[] } {
  return isRecord(value) && Array.isArray(value.rows);
}

function isEvaluationBundle(value: unknown): value is EvaluationBundle {
  return (
    isRecord(value) &&
    value.schemaVersion === 1 &&
    typeof value.variant === "string" &&
    isRecord(value.source) &&
    Array.isArray(value.jobs)
  );
}

function parseOptions(args: string[]): Record<string, string> {
  const options: Record<string, string> = {};
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] ?? "";
    if (!arg.startsWith("--")) continue;
    const key = arg.slice(2);
    const next = args[index + 1];
    if (next && !next.startsWith("--")) {
      options[key] = next;
      index += 1;
    } else {
      options[key] = "true";
    }
  }
  return options;
}

function usage(): string {
  return `Oppi CLI agent-flow evaluation

  bun server/scripts/cli-agent-flow-evaluation.ts collect --input <trace-dir|rows.json> --output <bundle.json> [--variant baseline]
  bun server/scripts/cli-agent-flow-evaluation.ts report --baseline <bundle.json> --candidate <bundle.json> [--out report.md] [--json]

The collector stores only sanitized command shape, outcomes, numeric sizes/timings,
model token totals where present, and disclosure depth. It never stores prompt or
response contents.
`;
}

function main(args: string[]): void {
  const mode = args[0];
  const options = parseOptions(args.slice(1));
  if (mode === "collect") {
    const input = options.input;
    const output = options.output;
    if (!input || !output) throw new Error(usage());
    const bundle = collectEvaluationBundle(input, options.variant ?? "baseline");
    writeFileSync(resolve(output), JSON.stringify(bundle, null, 2) + "\n", "utf8");
    console.log(`Collected ${bundle.jobs.length} sanitized jobs into ${resolve(output)}`);
    return;
  }
  if (mode === "report") {
    const baselinePath = options.baseline;
    const candidatePath = options.candidate;
    if (!baselinePath || !candidatePath) throw new Error(usage());
    const baseline = JSON.parse(readFileSync(resolve(baselinePath), "utf8")) as EvaluationBundle;
    const candidate = JSON.parse(readFileSync(resolve(candidatePath), "utf8")) as EvaluationBundle;
    const comparison = compareEvaluationBundles(baseline, candidate);
    if (options.out) {
      writeFileSync(resolve(options.out), renderEvaluationMarkdown(comparison), "utf8");
    }
    if (options.json === "true") console.log(JSON.stringify(comparison, null, 2));
    else if (!options.out) console.log(renderEvaluationMarkdown(comparison));
    else console.log(`Wrote evaluation report to ${resolve(options.out)}`);
    return;
  }
  console.error(usage());
  process.exitCode = 1;
}

if (import.meta.main) {
  try {
    main(process.argv.slice(2));
  } catch (error: unknown) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
