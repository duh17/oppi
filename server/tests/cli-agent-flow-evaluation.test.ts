import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import {
  collectEvaluationBundle,
  compareEvaluationBundles,
  renderEvaluationMarkdown,
} from "../scripts/cli-agent-flow-evaluation.js";

const tempDirs: string[] = [];

afterEach(() => {
  for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function writeRows(rows: unknown[]): string {
  const dir = mkdtempSync(join(tmpdir(), "oppi-cli-flow-eval-"));
  tempDirs.push(dir);
  const file = join(dir, "sanitized-rows.json");
  writeFileSync(file, JSON.stringify({ rows }), "utf8");
  return file;
}

describe("CLI agent-flow evaluation", () => {
  it("classifies the representative flows and keeps only sanitized measurements", () => {
    const input = writeRows([
      { file: "orientation", command: "session", action: "list", result_bytes: 100 },
      {
        file: "progress",
        command: "session",
        action: "inspect",
        view: "summary",
        result_bytes: 200,
      },
      {
        file: "latest",
        command: "session",
        action: "inspect",
        view: "response",
        result_bytes: 300,
      },
      {
        file: "history",
        command: "session",
        action: "inspect",
        view: "outline",
        result_bytes: 250,
      },
      { file: "history", command: "session", action: "messages", result_bytes: 500 },
      { file: "monitor", command: "session", action: "wait", result_bytes: 150 },
      { file: "mutation", command: "agent", action: "list", result_bytes: 100 },
      { file: "mutation", command: "agent", action: "update", result_bytes: 120 },
    ]);

    const bundle = collectEvaluationBundle(input, "baseline");
    const byScenario = Object.fromEntries(bundle.jobs.map((job) => [job.scenario, job]));

    expect(bundle.source.kind).toBe("sanitized-rows");
    expect(bundle.jobs).toHaveLength(6);
    expect(byScenario["session-orientation"]?.correct).toBe(true);
    expect(byScenario["current-progress"]?.correct).toBe(true);
    expect(byScenario["latest-response"]?.correct).toBe(true);
    expect(byScenario["historical-investigation"]?.correct).toBe(true);
    expect(byScenario["multi-session-monitoring"]?.correct).toBe(true);
    expect(byScenario["safe-mutation"]?.correct).toBe(true);
    expect(JSON.stringify(bundle)).not.toContain("prompt contents");
    expect(JSON.stringify(bundle)).not.toContain("response contents");
  });

  it("compares baseline and candidate medians and P90s by scenario", () => {
    const baselineInput = writeRows([
      {
        file: "latest",
        command: "session",
        action: "inspect",
        view: "response",
        result_bytes: 100,
      },
      {
        file: "latest",
        command: "session",
        action: "inspect",
        view: "response",
        result_bytes: 100,
      },
    ]);
    const candidateInput = writeRows([
      {
        file: "latest",
        command: "session",
        action: "inspect",
        view: "response",
        result_bytes: 100,
      },
    ]);

    const comparison = compareEvaluationBundles(
      collectEvaluationBundle(baselineInput, "baseline"),
      collectEvaluationBundle(candidateInput, "candidate"),
    );

    expect(comparison.baseline.scenarios["latest-response"].jobs).toBe(1);
    expect(comparison.baseline.scenarios["latest-response"].metrics.calls.median).toBe(2);
    expect(comparison.candidate.scenarios["latest-response"].correctness).toMatchObject({
      correct: 1,
      rate: 1,
    });
    expect(renderEvaluationMarkdown(comparison)).toMatch(
      /## Correctness[\s\S]*## Efficiency and disclosure/,
    );
  });

  it("records model tokens and elapsed round trips from raw trace structure", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-cli-flow-trace-"));
    tempDirs.push(dir);
    const file = join(dir, "job.jsonl");
    writeFileSync(
      file,
      [
        JSON.stringify({ type: "session", timestamp: "2026-08-06T00:00:00.000Z" }),
        JSON.stringify({
          type: "message",
          timestamp: "2026-08-06T00:00:01.000Z",
          message: {
            role: "assistant",
            content: [
              {
                type: "toolCall",
                id: "opaque-call-id",
                name: "oppi",
                arguments: { args: ["session", "inspect", "id", "--view", "response"] },
              },
            ],
          },
          usage: { totalTokens: 42 },
        }),
        JSON.stringify({
          type: "message",
          timestamp: "2026-08-06T00:00:01.250Z",
          message: {
            role: "toolResult",
            toolCallId: "opaque-call-id",
            isError: false,
            content: [{ type: "text", text: "redacted result" }],
          },
        }),
      ].join("\n") + "\n",
      "utf8",
    );

    const bundle = collectEvaluationBundle(file, "candidate");

    expect(bundle.jobs[0]).toMatchObject({
      scenario: "latest-response",
      correct: true,
      modelTokens: 42,
      elapsedMs: 250,
      roundTrips: 1,
    });
    expect(JSON.stringify(bundle)).not.toContain("redacted result");
    expect(JSON.stringify(bundle)).not.toContain("opaque-call-id");
  });
});
