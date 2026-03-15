/**
 * Autoresearch — autonomous experiment loop extension.
 *
 * Provides tools for iterative optimization: the agent edits code, benchmarks,
 * keeps or reverts, and repeats. Results render natively in the iOS timeline
 * via details.ui[] chart payloads and StyledSegment collapsed rows.
 *
 * Inspired by davebcn87/pi-autoresearch, rebuilt as a first-class Oppi feature.
 *
 * Tools:
 *   init_experiment  — one-time session config (name, metric, unit, direction)
 *   run_experiment   — runs a command, times wall-clock, captures output, runs checks
 *   log_experiment   — records result, auto-commits on keep, updates state + chart
 *
 * Persistence:
 *   autoresearch.jsonl  — append-only log (config headers + result lines)
 *   autoresearch.md     — living session document (agent reads each turn)
 *   autoresearch.checks.sh — optional backpressure (tests, types, lint)
 */

import { Type } from "@sinclair/typebox";
import * as fs from "node:fs";
import * as path from "node:path";

import type { ExtensionFactory } from "@mariozechner/pi-coding-agent";
import { truncateTail } from "@mariozechner/pi-coding-agent";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface ExperimentResult {
  commit: string;
  metric: number;
  metrics: Record<string, number>;
  status: "keep" | "discard" | "crash" | "checks_failed";
  description: string;
  timestamp: number;
  segment: number;
}

interface MetricDef {
  name: string;
  unit: string;
}

interface ExperimentState {
  results: ExperimentResult[];
  bestMetric: number | null;
  bestDirection: "lower" | "higher";
  metricName: string;
  metricUnit: string;
  secondaryMetrics: MetricDef[];
  name: string | null;
  currentSegment: number;
}

export interface RunDetails {
  command: string;
  exitCode: number | null;
  durationSeconds: number;
  passed: boolean;
  crashed: boolean;
  timedOut: boolean;
  tailOutput: string;
  checksPass: boolean | null;
  checksTimedOut: boolean;
  checksOutput: string;
  checksDuration: number;
}

export interface LogDetails {
  experiment: ExperimentResult;
  state: ExperimentState;
}

// ---------------------------------------------------------------------------
// Tool Schemas
// ---------------------------------------------------------------------------

const InitParams = Type.Object({
  name: Type.String({
    description: "Human-readable name for this experiment session",
  }),
  metric_name: Type.String({
    description: "Display name for the primary metric (e.g. total_us, bundle_kb, val_bpb)",
  }),
  metric_unit: Type.Optional(
    Type.String({
      description: 'Unit for the primary metric (e.g. us, ms, s, kb). Default: ""',
    }),
  ),
  direction: Type.Optional(
    Type.String({
      description: 'Whether "lower" or "higher" is better. Default: "lower".',
    }),
  ),
});

const RunParams = Type.Object({
  command: Type.String({
    description: "Shell command to run",
  }),
  timeout_seconds: Type.Optional(
    Type.Number({ description: "Kill after this many seconds (default: 600)" }),
  ),
  checks_timeout_seconds: Type.Optional(
    Type.Number({
      description:
        "Kill autoresearch.checks.sh after this many seconds (default: 300). Only relevant when the checks file exists.",
    }),
  ),
});

const LogParams = Type.Object({
  commit: Type.String({ description: "Git commit hash (short, 7 chars)" }),
  metric: Type.Number({ description: "The primary optimization metric value. 0 for crashes." }),
  status: Type.Union(
    [
      Type.Literal("keep"),
      Type.Literal("discard"),
      Type.Literal("crash"),
      Type.Literal("checks_failed"),
    ],
    { description: "Experiment outcome" },
  ),
  description: Type.String({ description: "Short description of what this experiment tried" }),
  metrics: Type.Optional(
    Type.Record(Type.String(), Type.Number(), {
      description: "Additional metrics to track as { name: value } pairs",
    }),
  ),
  force: Type.Optional(
    Type.Boolean({
      description:
        "Set to true to allow adding a new secondary metric that was not tracked before.",
    }),
  ),
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const BENCHMARK_GUARDRAIL =
  "Be careful not to overfit to the benchmarks and do not cheat on the benchmarks.";
const MAX_AUTORESUME_TURNS = 20;

function formatNum(value: number | null, unit: string): string {
  if (value === null) return "—";
  const u = unit || "";
  if (value === Math.round(value)) {
    return commas(value) + u;
  }
  return commas(Math.floor(Math.abs(value))) + (Math.abs(value) % 1).toFixed(2).slice(1) + u;
}

function commas(n: number): string {
  const s = String(Math.abs(Math.round(n)));
  const parts: string[] = [];
  for (let i = s.length; i > 0; i -= 3) {
    parts.unshift(s.slice(Math.max(0, i - 3), i));
  }
  return (n < 0 ? "-" : "") + parts.join(",");
}

function isBetter(current: number, best: number, direction: "lower" | "higher"): boolean {
  return direction === "lower" ? current < best : current > best;
}

function currentResults(results: ExperimentResult[], segment: number): ExperimentResult[] {
  return results.filter((r) => r.segment === segment);
}

function findBaselineMetric(results: ExperimentResult[], segment: number): number | null {
  const cur = currentResults(results, segment);
  return cur.length > 0 ? cur[0].metric : null;
}

function findBaselineSecondary(
  results: ExperimentResult[],
  segment: number,
  knownMetrics?: MetricDef[],
): Record<string, number> {
  const cur = currentResults(results, segment);
  const base: Record<string, number> = cur.length > 0 ? { ...(cur[0].metrics ?? {}) } : {};
  if (knownMetrics) {
    for (const sm of knownMetrics) {
      if (base[sm.name] === undefined) {
        for (const r of cur) {
          const val = (r.metrics ?? {})[sm.name];
          if (val !== undefined) {
            base[sm.name] = val;
            break;
          }
        }
      }
    }
  }
  return base;
}

/** Build a details.ui[] chart payload from experiment state. */
function buildChartPayload(state: ExperimentState): Record<string, unknown> | undefined {
  const cur = currentResults(state.results, state.currentSegment);
  if (cur.length === 0) return undefined;

  // Build chart rows from current segment results
  const rows: Record<string, unknown>[] = [];
  const globalOffset = state.results.indexOf(cur[0]);
  for (let i = 0; i < cur.length; i++) {
    const r = cur[i];
    const row: Record<string, unknown> = {
      run: globalOffset + i + 1,
      [state.metricName]: r.metric,
      status: r.status,
    };
    // Add secondary metrics
    for (const sm of state.secondaryMetrics) {
      const val = (r.metrics ?? {})[sm.name];
      if (val !== undefined) {
        row[sm.name] = val;
      }
    }
    rows.push(row);
  }

  const baseline = state.bestMetric;

  // Build marks: line + points for primary metric, rule for baseline
  const marks: Record<string, unknown>[] = [
    {
      type: "line",
      x: "run",
      y: state.metricName,
      series: "status",
      label: state.metricName,
      interpolation: "linear",
    },
    {
      type: "point",
      x: "run",
      y: state.metricName,
      series: "status",
    },
  ];

  if (baseline !== null) {
    marks.push({
      type: "rule",
      yValue: baseline,
      label: "baseline",
    });
  }

  return {
    kind: "chart",
    version: 1,
    title: state.name ? `${state.name}` : `Experiment: ${state.metricName}`,
    spec: {
      title: state.name ? `${state.name}` : `Experiment: ${state.metricName}`,
      dataset: { rows },
      marks,
      axes: {
        x: { label: "Run" },
        y: { label: `${state.metricName}${state.metricUnit ? ` (${state.metricUnit})` : ""}` },
      },
      renderHints: {
        xAxis: { type: "numeric" },
        yAxis: { zeroBaseline: "never" },
        legend: { mode: "hide" },
      },
    },
    fallbackText: buildFallbackText(state),
  };
}

/** Build a markdown summary for expandedText. */
function buildFallbackText(state: ExperimentState): string {
  const cur = currentResults(state.results, state.currentSegment);
  const kept = cur.filter((r) => r.status === "keep").length;
  const discarded = cur.filter((r) => r.status === "discard").length;
  const crashed = cur.filter((r) => r.status === "crash").length;
  const checksFailed = cur.filter((r) => r.status === "checks_failed").length;
  const baseline = state.bestMetric;

  let bestPrimary: number | null = null;
  let bestRunNum = 0;
  for (let i = state.results.length - 1; i >= 0; i--) {
    const r = state.results[i];
    if (r.segment !== state.currentSegment) continue;
    if (r.status === "keep" && r.metric > 0) {
      if (bestPrimary === null || isBetter(r.metric, bestPrimary, state.bestDirection)) {
        bestPrimary = r.metric;
        bestRunNum = i + 1;
      }
    }
  }

  const lines: string[] = [];
  lines.push(`Runs: ${state.results.length} (${kept} kept, ${discarded} discarded`);
  if (crashed > 0) lines[lines.length - 1] += `, ${crashed} crashed`;
  if (checksFailed > 0) lines[lines.length - 1] += `, ${checksFailed} checks failed`;
  lines[lines.length - 1] += ")";

  if (baseline !== null) {
    lines.push(`Baseline: ${formatNum(baseline, state.metricUnit)}`);
  }
  if (bestPrimary !== null && baseline !== null && baseline !== 0) {
    const pct = ((bestPrimary - baseline) / baseline) * 100;
    const sign = pct > 0 ? "+" : "";
    lines.push(
      `Best: ${formatNum(bestPrimary, state.metricUnit)} #${bestRunNum} (${sign}${pct.toFixed(1)}%)`,
    );
  }

  return lines.join("\n");
}

/** Infer metric unit from name suffix. */
function inferUnit(name: string): string {
  if (name.endsWith("_us") || name.includes("us")) return "us";
  if (name.endsWith("_ms") || name.includes("ms")) return "ms";
  if (name.endsWith("_s") || name.includes("sec")) return "s";
  return "";
}

// ---------------------------------------------------------------------------
// Extension Factory
// ---------------------------------------------------------------------------

export function createAutoresearchFactory(workspaceCwd: string): ExtensionFactory {
  return (pi) => {
    let state: ExperimentState = {
      results: [],
      bestMetric: null,
      bestDirection: "lower",
      metricName: "metric",
      metricUnit: "",
      secondaryMetrics: [],
      name: null,
      currentSegment: 0,
    };

    let autoresearchMode = false;
    let lastRunChecks: { pass: boolean; output: string; duration: number } | null = null;
    let experimentsThisSession = 0;
    let autoResumeTurns = 0;
    let lastAutoResumeTime = 0;

    // ─── State reconstruction ───

    const reconstructState = (): void => {
      lastRunChecks = null;
      state = {
        results: [],
        bestMetric: null,
        bestDirection: "lower",
        metricName: "metric",
        metricUnit: "",
        secondaryMetrics: [],
        name: null,
        currentSegment: 0,
      };

      const jsonlPath = path.join(workspaceCwd, "autoresearch.jsonl");
      try {
        if (fs.existsSync(jsonlPath)) {
          let segment = 0;
          const lines = fs.readFileSync(jsonlPath, "utf-8").trim().split("\n").filter(Boolean);
          for (const line of lines) {
            try {
              const entry = JSON.parse(line);
              if (entry.type === "config") {
                if (entry.name) state.name = entry.name;
                if (entry.metricName) state.metricName = entry.metricName;
                if (entry.metricUnit !== undefined) state.metricUnit = entry.metricUnit;
                if (entry.bestDirection) state.bestDirection = entry.bestDirection;
                if (state.results.length > 0) segment++;
                state.currentSegment = segment;
                continue;
              }
              state.results.push({
                commit: entry.commit ?? "",
                metric: entry.metric ?? 0,
                metrics: entry.metrics ?? {},
                status: entry.status ?? "keep",
                description: entry.description ?? "",
                timestamp: entry.timestamp ?? 0,
                segment,
              });
              for (const name of Object.keys(entry.metrics ?? {})) {
                if (!state.secondaryMetrics.find((m) => m.name === name)) {
                  state.secondaryMetrics.push({ name, unit: inferUnit(name) });
                }
              }
            } catch {
              // Skip malformed lines
            }
          }
          if (state.results.length > 0) {
            state.bestMetric = findBaselineMetric(state.results, state.currentSegment);
          }
        }
      } catch {
        // Fall through
      }

      autoresearchMode = fs.existsSync(jsonlPath);
    };

    // ─── Lifecycle hooks ───

    pi.on("session_start", async () => reconstructState());

    pi.on("agent_start", async () => {
      experimentsThisSession = 0;
    });

    pi.on("before_agent_start", async (event) => {
      if (!autoresearchMode) return;

      const mdPath = path.join(workspaceCwd, "autoresearch.md");
      const ideasPath = path.join(workspaceCwd, "autoresearch.ideas.md");
      const checksPath = path.join(workspaceCwd, "autoresearch.checks.sh");
      const hasIdeas = fs.existsSync(ideasPath);
      const hasChecks = fs.existsSync(checksPath);

      let extra =
        "\n\n## Autoresearch Mode (ACTIVE)" +
        "\nYou are in autoresearch mode. Optimize the primary metric through an autonomous experiment loop." +
        "\nUse init_experiment, run_experiment, and log_experiment tools. NEVER STOP until interrupted." +
        `\nExperiment rules: ${mdPath} — read this file at the start of every session and after compaction.` +
        "\nWrite promising but deferred optimizations as bullet points to autoresearch.ideas.md." +
        `\n${BENCHMARK_GUARDRAIL}` +
        "\nIf the user sends a follow-on message while an experiment is running, finish the current run_experiment + log_experiment cycle first, then address their message in the next iteration.";

      if (hasChecks) {
        extra +=
          "\n\n## Backpressure Checks (ACTIVE)" +
          `\n${checksPath} exists and runs automatically after every passing benchmark.` +
          "\nIf checks fail, use status 'checks_failed' in log_experiment." +
          "\nYou cannot use status 'keep' when checks have failed.";
      }

      if (hasIdeas) {
        extra += `\n\nIdeas backlog exists at ${ideasPath} — check it for promising experiment paths.`;
      }

      return { systemPrompt: event.systemPrompt + extra };
    });

    pi.on("agent_end", async () => {
      if (!autoresearchMode) return;
      if (experimentsThisSession === 0) return;

      const now = Date.now();
      if (now - lastAutoResumeTime < 5 * 60 * 1000) return;
      lastAutoResumeTime = now;

      if (autoResumeTurns >= MAX_AUTORESUME_TURNS) return;

      const ideasPath = path.join(workspaceCwd, "autoresearch.ideas.md");
      const hasIdeas = fs.existsSync(ideasPath);
      let resumeMsg =
        "Autoresearch loop ended (likely context limit). Resume the experiment loop — read autoresearch.md and git log for context.";
      if (hasIdeas) {
        resumeMsg +=
          " Check autoresearch.ideas.md for promising paths to explore. Prune stale/tried ideas.";
      }
      resumeMsg += ` ${BENCHMARK_GUARDRAIL}`;

      autoResumeTurns++;
      pi.sendUserMessage(resumeMsg);
    });

    // ─── init_experiment ───

    pi.registerTool({
      name: "init_experiment",
      label: "Init Experiment",
      description:
        "Initialize the experiment session. Call once before the first run_experiment to set the name, primary metric, unit, and direction.",
      promptSnippet:
        "Initialize experiment session (name, metric, unit, direction). Call once before first run.",
      promptGuidelines: [
        "Call init_experiment exactly once at the start of an autoresearch session, before the first run_experiment.",
        "If autoresearch.jsonl already exists with a config, do NOT call init_experiment again.",
        "If the optimization target changes, call init_experiment again to insert a new config header and reset the baseline.",
      ],
      parameters: InitParams,
      async execute(_toolCallId, params) {
        const isReinit = state.results.length > 0;
        state.name = params.name;
        state.metricName = params.metric_name;
        state.metricUnit = params.metric_unit ?? "";
        if (params.direction === "lower" || params.direction === "higher") {
          state.bestDirection = params.direction;
        }

        state.results = [];
        state.bestMetric = null;
        state.secondaryMetrics = [];

        try {
          const jsonlPath = path.join(workspaceCwd, "autoresearch.jsonl");
          const config = JSON.stringify({
            type: "config",
            name: state.name,
            metricName: state.metricName,
            metricUnit: state.metricUnit,
            bestDirection: state.bestDirection,
          });
          if (isReinit) {
            fs.appendFileSync(jsonlPath, config + "\n");
          } else {
            fs.writeFileSync(jsonlPath, config + "\n");
          }
        } catch (e) {
          return {
            content: [
              {
                type: "text" as const,
                text: `Failed to write autoresearch.jsonl: ${e instanceof Error ? e.message : String(e)}`,
              },
            ],
            isError: true,
            details: { state: { ...state } },
          };
        }

        autoresearchMode = true;

        const reinitNote = isReinit
          ? " (re-initialized — previous results archived, new baseline needed)"
          : "";
        return {
          content: [
            {
              type: "text" as const,
              text:
                `Experiment initialized: "${state.name}"${reinitNote}\n` +
                `Metric: ${state.metricName} (${state.metricUnit || "unitless"}, ${state.bestDirection} is better)\n` +
                `Config written to autoresearch.jsonl. Now run the baseline with run_experiment.`,
            },
          ],
          details: { state: { ...state } },
        };
      },
    });

    // ─── run_experiment ───

    pi.registerTool({
      name: "run_experiment",
      label: "Run Experiment",
      description:
        "Run a shell command as an experiment. Times wall-clock duration, captures output, detects pass/fail via exit code.",
      promptSnippet: "Run a timed experiment command (captures duration, output, exit code)",
      promptGuidelines: [
        "Use run_experiment instead of bash when running experiment commands — it handles timing and output capture automatically.",
        "After run_experiment, always call log_experiment to record the result.",
      ],
      parameters: RunParams,
      async execute(_toolCallId, params, signal, onUpdate) {
        const timeout = (params.timeout_seconds ?? 600) * 1000;

        onUpdate?.({
          content: [{ type: "text", text: `Running: ${params.command}` }],
          details: { phase: "running" } as unknown,
        });

        const t0 = Date.now();
        let result;
        try {
          result = await pi.exec("bash", ["-c", params.command], {
            signal,
            timeout,
            cwd: workspaceCwd,
          });
        } catch (e) {
          return {
            content: [
              {
                type: "text" as const,
                text: `Execution error: ${e instanceof Error ? e.message : String(e)}`,
              },
            ],
            isError: true,
            details: {
              command: params.command,
              exitCode: null,
              durationSeconds: (Date.now() - t0) / 1000,
              passed: false,
              crashed: true,
              timedOut: false,
              tailOutput: "",
              checksPass: null,
              checksTimedOut: false,
              checksOutput: "",
              checksDuration: 0,
            } satisfies RunDetails,
          };
        }

        const durationSeconds = (Date.now() - t0) / 1000;
        const output = (result.stdout + "\n" + result.stderr).trim();
        const benchmarkPassed = result.code === 0 && !result.killed;

        // Run backpressure checks if benchmark passed
        let checksPass: boolean | null = null;
        let checksTimedOut = false;
        let checksOutput = "";
        let checksDuration = 0;
        const checksPath = path.join(workspaceCwd, "autoresearch.checks.sh");

        if (benchmarkPassed && fs.existsSync(checksPath)) {
          const checksTimeout = (params.checks_timeout_seconds ?? 300) * 1000;
          const ct0 = Date.now();
          try {
            const checksResult = await pi.exec("bash", [checksPath], {
              signal,
              timeout: checksTimeout,
              cwd: workspaceCwd,
            });
            checksDuration = (Date.now() - ct0) / 1000;
            checksTimedOut = !!checksResult.killed;
            checksPass = checksResult.code === 0 && !checksResult.killed;
            checksOutput = (checksResult.stdout + "\n" + checksResult.stderr).trim();
          } catch (e) {
            checksDuration = (Date.now() - ct0) / 1000;
            checksPass = false;
            checksOutput = e instanceof Error ? e.message : String(e);
          }
        }

        lastRunChecks =
          checksPass !== null
            ? { pass: checksPass, output: checksOutput, duration: checksDuration }
            : null;

        const passed = benchmarkPassed && (checksPass === null || checksPass);
        const details: RunDetails = {
          command: params.command,
          exitCode: result.code,
          durationSeconds,
          passed,
          crashed: !passed,
          timedOut: !!result.killed,
          tailOutput: output.split("\n").slice(-80).join("\n"),
          checksPass,
          checksTimedOut,
          checksOutput: checksOutput.split("\n").slice(-80).join("\n"),
          checksDuration,
        };

        // Build response text
        let text = "";
        if (details.timedOut) {
          text += `TIMEOUT after ${durationSeconds.toFixed(1)}s\n`;
        } else if (!benchmarkPassed) {
          text += `FAILED (exit code ${result.code}) in ${durationSeconds.toFixed(1)}s\n`;
        } else if (checksTimedOut) {
          text += `Benchmark PASSED in ${durationSeconds.toFixed(1)}s\n`;
          text += `CHECKS TIMEOUT after ${checksDuration.toFixed(1)}s\n`;
          text += `Log this as 'checks_failed'.\n`;
        } else if (checksPass === false) {
          text += `Benchmark PASSED in ${durationSeconds.toFixed(1)}s\n`;
          text += `CHECKS FAILED in ${checksDuration.toFixed(1)}s\n`;
          text += `Log this as 'checks_failed'.\n`;
        } else {
          text += `PASSED in ${durationSeconds.toFixed(1)}s\n`;
          if (checksPass === true) {
            text += `Checks passed in ${checksDuration.toFixed(1)}s\n`;
          }
        }

        if (state.bestMetric !== null) {
          text += `Current best ${state.metricName}: ${formatNum(state.bestMetric, state.metricUnit)}\n`;
        }

        text += `\nLast 80 lines of output:\n${details.tailOutput}`;
        if (checksPass === false) {
          text += `\n\n-- Checks output (last 80 lines) --\n${details.checksOutput}`;
        }

        const truncation = truncateTail(text, { maxLines: 150, maxBytes: 40000 });

        return {
          content: [{ type: "text" as const, text: truncation.content }],
          details,
        };
      },
    });

    // ─── log_experiment ───

    pi.registerTool({
      name: "log_experiment",
      label: "Log Experiment",
      description:
        "Record an experiment result. Tracks metrics, auto-commits on keep. Call after every run_experiment.",
      promptSnippet: "Log experiment result (commit, metric, status, description)",
      promptGuidelines: [
        "Always call log_experiment after run_experiment to record the result.",
        "log_experiment automatically runs git add -A && git commit with the description. Do NOT commit manually.",
        "Use status 'keep' if the PRIMARY metric improved. 'discard' if worse or unchanged. 'crash' if it failed.",
        "Secondary metrics are for monitoring — they almost never affect keep/discard.",
        "If you discover promising optimizations you won't pursue immediately, append them to autoresearch.ideas.md.",
      ],
      parameters: LogParams,
      async execute(_toolCallId, params) {
        const secondaryMetrics = params.metrics ?? {};

        // Gate: prevent "keep" when last run's checks failed
        if (params.status === "keep" && lastRunChecks && !lastRunChecks.pass) {
          return {
            content: [
              {
                type: "text" as const,
                text: `Cannot keep — autoresearch.checks.sh failed.\n\n${lastRunChecks.output.slice(-500)}\n\nLog as 'checks_failed' instead.`,
              },
            ],
            isError: true,
            details: {},
          };
        }

        // Validate secondary metrics consistency
        if (state.secondaryMetrics.length > 0) {
          const knownNames = new Set(state.secondaryMetrics.map((m) => m.name));
          const providedNames = new Set(Object.keys(secondaryMetrics));

          const missing = [...knownNames].filter((n) => !providedNames.has(n));
          if (missing.length > 0) {
            return {
              content: [
                {
                  type: "text" as const,
                  text: `Missing secondary metrics: ${missing.join(", ")}\n\nExpected: ${[...knownNames].join(", ")}\nGot: ${[...providedNames].join(", ") || "(none)"}`,
                },
              ],
              isError: true,
              details: {},
            };
          }

          const newMetrics = [...providedNames].filter((n) => !knownNames.has(n));
          if (newMetrics.length > 0 && !params.force) {
            return {
              content: [
                {
                  type: "text" as const,
                  text: `New secondary metric(s) not previously tracked: ${newMetrics.join(", ")}\n\nExisting: ${[...knownNames].join(", ")}\n\nCall log_experiment again with force: true to add it.`,
                },
              ],
              isError: true,
              details: {},
            };
          }
        }

        const experiment: ExperimentResult = {
          commit: params.commit.slice(0, 7),
          metric: params.metric,
          metrics: secondaryMetrics,
          status: params.status,
          description: params.description,
          timestamp: Date.now(),
          segment: state.currentSegment,
        };

        state.results.push(experiment);
        experimentsThisSession++;

        // Register new secondary metric names
        for (const name of Object.keys(secondaryMetrics)) {
          if (!state.secondaryMetrics.find((m) => m.name === name)) {
            state.secondaryMetrics.push({ name, unit: inferUnit(name) });
          }
        }

        state.bestMetric = findBaselineMetric(state.results, state.currentSegment);

        // Build response text
        const curCount = currentResults(state.results, state.currentSegment).length;
        let text = `Logged #${state.results.length}: ${experiment.status} — ${experiment.description}`;

        if (state.bestMetric !== null) {
          text += `\nBaseline ${state.metricName}: ${formatNum(state.bestMetric, state.metricUnit)}`;
          if (curCount > 1 && params.status === "keep" && params.metric > 0) {
            const delta = params.metric - state.bestMetric;
            const pct = ((delta / state.bestMetric) * 100).toFixed(1);
            const sign = delta > 0 ? "+" : "";
            text += ` | this: ${formatNum(params.metric, state.metricUnit)} (${sign}${pct}%)`;
          }
        }

        // Show secondary metrics
        if (Object.keys(secondaryMetrics).length > 0) {
          const baselines = findBaselineSecondary(
            state.results,
            state.currentSegment,
            state.secondaryMetrics,
          );
          const parts: string[] = [];
          for (const [name, value] of Object.entries(secondaryMetrics)) {
            const def = state.secondaryMetrics.find((m) => m.name === name);
            const unit = def?.unit ?? "";
            let part = `${name}: ${formatNum(value, unit)}`;
            const bv = baselines[name];
            if (bv !== undefined && state.results.length > 1 && bv !== 0) {
              const d = value - bv;
              const p = ((d / bv) * 100).toFixed(1);
              const s = d > 0 ? "+" : "";
              part += ` (${s}${p}%)`;
            }
            parts.push(part);
          }
          text += `\nSecondary: ${parts.join(" ")}`;
        }

        text += `\n(${state.results.length} experiments total)`;

        // Auto-commit on keep
        if (params.status === "keep") {
          try {
            const resultData: Record<string, unknown> = {
              status: params.status,
              [state.metricName || "metric"]: params.metric,
              ...secondaryMetrics,
            };
            const trailerJson = JSON.stringify(resultData);
            const commitMsg = `${params.description}\n\nResult: ${trailerJson}`;
            const gitResult = await pi.exec(
              "bash",
              [
                "-c",
                `git add -A && git diff --cached --quiet && echo "NOTHING_TO_COMMIT" || git commit -m ${JSON.stringify(commitMsg)}`,
              ],
              { cwd: workspaceCwd, timeout: 10000 },
            );
            const gitOutput = (gitResult.stdout + gitResult.stderr).trim();

            if (gitOutput.includes("NOTHING_TO_COMMIT")) {
              text += `\nGit: nothing to commit (working tree clean)`;
            } else if (gitResult.code === 0) {
              const firstLine = gitOutput.split("\n")[0] || "";
              text += `\nGit: committed — ${firstLine}`;

              // Update commit hash to actual
              try {
                const shaResult = await pi.exec("git", ["rev-parse", "--short=7", "HEAD"], {
                  cwd: workspaceCwd,
                  timeout: 5000,
                });
                const newSha = (shaResult.stdout || "").trim();
                if (newSha && newSha.length >= 7) {
                  experiment.commit = newSha;
                }
              } catch {
                // Keep original
              }
            } else {
              text += `\nGit commit failed (exit ${gitResult.code}): ${gitOutput.slice(0, 200)}`;
            }
          } catch (e) {
            text += `\nGit commit error: ${e instanceof Error ? e.message : String(e)}`;
          }
        } else {
          text += `\nGit: skipped commit (${params.status}) — revert with git checkout -- .`;
        }

        // Persist to autoresearch.jsonl
        try {
          const jsonlPath = path.join(workspaceCwd, "autoresearch.jsonl");
          fs.appendFileSync(
            jsonlPath,
            JSON.stringify({ run: state.results.length, ...experiment }) + "\n",
          );
        } catch {
          // Don't fail if write fails
        }

        // Clear checks state
        lastRunChecks = null;

        // Build details with chart payload
        const chartPayload = buildChartPayload(state);

        return {
          content: [{ type: "text" as const, text }],
          details: {
            experiment,
            state: { ...state },
            ...(chartPayload ? { ui: [chartPayload] } : {}),
            expandedText: buildFallbackText(state),
            presentationFormat: "markdown",
          } as unknown as LogDetails,
        };
      },
    });
  };
}
