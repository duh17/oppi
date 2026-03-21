import { describe, it, expect, beforeEach, afterEach } from "vitest";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

import type { RunDetails } from "./autoresearch-extension.js";
import { WORKTREE_MARKER, computeWorktreePaths } from "./autoresearch-extension.js";

// ---------------------------------------------------------------------------
// Minimal mock of ExtensionAPI for unit testing the factory
// ---------------------------------------------------------------------------

interface RegisteredTool {
  name: string;
  label: string;
  description: string;
  parameters: unknown;
  execute: (
    toolCallId: string,
    params: Record<string, unknown>,
    signal?: AbortSignal,
    onUpdate?: (update: { content: unknown[]; details: unknown }) => void,
    ctx?: unknown,
  ) => Promise<{
    content: { type: string; text: string }[];
    details?: unknown;
    isError?: boolean;
  }>;
}

interface MockExtensionAPI {
  tools: Map<string, RegisteredTool>;
  handlers: Map<string, ((...args: unknown[]) => unknown)[]>;
  execResults: Map<string, { stdout: string; stderr: string; code: number; killed?: boolean }>;
  /** Called before every exec — use to simulate side effects like directory creation. */
  execSideEffect: ((cmd: string, args: string[]) => void) | null;
  sentMessages: string[];
  registerTool(tool: RegisteredTool): void;
  on(event: string, handler: (...args: unknown[]) => unknown): void;
  exec(
    cmd: string,
    args: string[],
    opts?: { signal?: AbortSignal; timeout?: number; cwd?: string },
  ): Promise<{ stdout: string; stderr: string; code: number; killed?: boolean }>;
  sendUserMessage(content: string): void;
}

function createMockAPI(): MockExtensionAPI {
  const api: MockExtensionAPI = {
    tools: new Map(),
    handlers: new Map(),
    execResults: new Map(),
    execSideEffect: null,
    sentMessages: [],
    registerTool(tool) {
      api.tools.set(tool.name, tool);
    },
    on(event, handler) {
      if (!api.handlers.has(event)) api.handlers.set(event, []);
      api.handlers.get(event)!.push(handler);
    },
    async exec(cmd, args) {
      api.execSideEffect?.(cmd, args);
      const key = `${cmd} ${args.join(" ")}`;
      // Check for partial match
      for (const [pattern, result] of api.execResults) {
        if (key.includes(pattern)) return result;
      }
      return { stdout: "", stderr: "", code: 0 };
    },
    sendUserMessage(content) {
      api.sentMessages.push(typeof content === "string" ? content : JSON.stringify(content));
    },
  };
  return api;
}

async function fireEvent(
  api: MockExtensionAPI,
  event: string,
  ...args: unknown[]
): Promise<unknown> {
  const handlers = api.handlers.get(event) || [];
  let result: unknown;
  for (const handler of handlers) {
    result = await handler(...args);
  }
  return result;
}

describe("autoresearch-extension", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "autoresearch-test-"));
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
    // Also clean up any worktree directories created alongside tmpDir
    const worktreeBase = path.resolve(tmpDir, "..", `${path.basename(tmpDir)}-autoresearch`);
    if (fs.existsSync(worktreeBase)) {
      fs.rmSync(worktreeBase, { recursive: true, force: true });
    }
  });

  async function loadFactory(
    cwd: string,
    sessionId = "test-session-1",
  ): Promise<{ api: MockExtensionAPI; tool: (name: string) => RegisteredTool }> {
    const { createAutoresearchFactory } = await import("./autoresearch-extension.js");
    const api = createMockAPI();
    const factory = createAutoresearchFactory(cwd, { sessionId });
    await factory(api as unknown as Parameters<typeof factory>[0]);
    const tool = (name: string): RegisteredTool => {
      const t = api.tools.get(name);
      if (!t) throw new Error(`Tool ${name} not registered`);
      return t;
    };
    return { api, tool };
  }

  /** Set up the mock to simulate git worktree creation (creates the directory). */
  function mockGitWorktree(api: MockExtensionAPI): void {
    api.execSideEffect = (cmd, args) => {
      if (cmd === "git" && args[0] === "worktree" && args[1] === "add") {
        // Find the worktree path — it's after all flags
        const pathArg = args.find(
          (a, i) => i >= 2 && !a.startsWith("-") && !args[i - 1]?.startsWith("-"),
        );
        if (pathArg) {
          fs.mkdirSync(pathArg, { recursive: true });
        }
      }
    };
  }

  describe("init_experiment", () => {
    it("registers three tools", async () => {
      const { api } = await loadFactory(tmpDir);
      expect(api.tools.has("init_experiment")).toBe(true);
      expect(api.tools.has("run_experiment")).toBe(true);
      expect(api.tools.has("log_experiment")).toBe(true);
    });

    it("creates worktree and writes config there", async () => {
      const { api, tool } = await loadFactory(tmpDir);
      mockGitWorktree(api);

      const result = await tool("init_experiment").execute("tc1", {
        name: "Speed Test",
        metric_name: "duration_ms",
        metric_unit: "ms",
        direction: "lower",
      });

      expect(result.content[0].text).toContain("Experiment initialized");
      expect(result.content[0].text).toContain("Speed Test");
      expect(result.content[0].text).toContain("Worktree:");

      // Verify marker file at workspace root
      const markerPath = path.join(tmpDir, WORKTREE_MARKER);
      expect(fs.existsSync(markerPath)).toBe(true);

      // Verify marker is JSONL with sessionId
      const markerLine = JSON.parse(fs.readFileSync(markerPath, "utf-8").trim().split("\n")[0]);
      expect(markerLine.sessionId).toBe("test-session-1");
      expect(markerLine.worktreePath).toBeDefined();

      const worktreePath = markerLine.worktreePath;

      // Verify jsonl is in the worktree, NOT in workspace root
      expect(fs.existsSync(path.join(worktreePath, "autoresearch.jsonl"))).toBe(true);
      expect(fs.existsSync(path.join(tmpDir, "autoresearch.jsonl"))).toBe(false);

      // Verify config content
      const content = fs
        .readFileSync(path.join(worktreePath, "autoresearch.jsonl"), "utf-8")
        .trim();
      const config = JSON.parse(content);
      expect(config.type).toBe("config");
      expect(config.name).toBe("Speed Test");
    });

    it("returns worktreePath in details", async () => {
      const { api, tool } = await loadFactory(tmpDir);
      mockGitWorktree(api);

      const result = await tool("init_experiment").execute("tc1", {
        name: "Test",
        metric_name: "val",
        direction: "lower",
      });

      const details = result.details as Record<string, unknown>;
      expect(details.worktreePath).toBeDefined();
      expect(typeof details.worktreePath).toBe("string");
      expect(details.worktreePath).not.toBe(tmpDir);
    });

    it("errors when git worktree creation fails", async () => {
      const { api, tool } = await loadFactory(tmpDir);
      api.execResults.set("git worktree", {
        stdout: "",
        stderr: "not a git repository",
        code: 128,
      });

      const result = await tool("init_experiment").execute("tc1", {
        name: "Test",
        metric_name: "val",
        direction: "lower",
      });

      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("Failed to create git worktree");
    });

    it("reuses existing worktree directory", async () => {
      const { worktreePath } = computeWorktreePaths(tmpDir, "Test");
      fs.mkdirSync(worktreePath, { recursive: true });

      const { tool } = await loadFactory(tmpDir);

      const result = await tool("init_experiment").execute("tc1", {
        name: "Test",
        metric_name: "val",
        direction: "lower",
      });

      expect(result.isError).toBeUndefined();
      expect(result.content[0].text).toContain("Experiment initialized");
      expect(fs.existsSync(path.join(worktreePath, "autoresearch.jsonl"))).toBe(true);
    });
  });

  describe("session-scoped isolation", () => {
    it("only resumes from own session marker", async () => {
      // Set up a worktree with marker from session "parent-1"
      const { worktreePath } = computeWorktreePaths(tmpDir, "Parent Task");
      fs.mkdirSync(worktreePath, { recursive: true });

      // Write marker for parent session
      const markerContent = JSON.stringify({
        sessionId: "parent-1",
        worktreePath,
      });
      fs.writeFileSync(path.join(tmpDir, WORKTREE_MARKER), markerContent + "\n");

      // Write jsonl in the worktree
      fs.writeFileSync(
        path.join(worktreePath, "autoresearch.jsonl"),
        JSON.stringify({
          type: "config",
          name: "Parent Task",
          metricName: "val",
          bestDirection: "lower",
        }) + "\n",
      );

      // Child session with different ID should NOT pick up the parent's worktree
      const { api: childApi } = await loadFactory(tmpDir, "child-1");
      await fireEvent(childApi, "session_start");

      const result = (await fireEvent(childApi, "before_agent_start", {
        prompt: "fix a bug",
        systemPrompt: "You are an assistant.",
      })) as { systemPrompt?: string } | undefined;

      // Child should NOT be in autoresearch mode
      expect(result).toBeUndefined();
    });

    it("same session ID reconstructs state but does not auto-activate", async () => {
      const { worktreePath } = computeWorktreePaths(tmpDir, "My Task");
      fs.mkdirSync(worktreePath, { recursive: true });

      // Write marker for this session
      const markerContent = JSON.stringify({
        sessionId: "session-A",
        worktreePath,
      });
      fs.writeFileSync(path.join(tmpDir, WORKTREE_MARKER), markerContent + "\n");

      fs.writeFileSync(
        path.join(worktreePath, "autoresearch.jsonl"),
        JSON.stringify({
          type: "config",
          name: "My Task",
          metricName: "val",
          bestDirection: "lower",
        }) + "\n",
      );

      // Same session ID should reconstruct state but NOT auto-activate mode
      // (autoresearch is now on-demand only — activated by tool calls)
      const { api } = await loadFactory(tmpDir, "session-A");
      await fireEvent(api, "session_start");

      const result = (await fireEvent(api, "before_agent_start", {
        prompt: "continue",
        systemPrompt: "You are an assistant.",
      })) as { systemPrompt?: string } | undefined;

      // No system prompt injection without explicit tool usage
      expect(result).toBeUndefined();
    });

    it("multiple sessions coexist in marker file", async () => {
      // Set up two worktrees with markers from different sessions
      const wt1 = computeWorktreePaths(tmpDir, "Task A").worktreePath;
      const wt2 = computeWorktreePaths(tmpDir, "Task B").worktreePath;
      fs.mkdirSync(wt1, { recursive: true });
      fs.mkdirSync(wt2, { recursive: true });

      // Write marker with two entries
      const lines = [
        JSON.stringify({ sessionId: "sess-1", worktreePath: wt1 }),
        JSON.stringify({ sessionId: "sess-2", worktreePath: wt2 }),
      ];
      fs.writeFileSync(path.join(tmpDir, WORKTREE_MARKER), lines.join("\n") + "\n");

      // Write different jsonl in each worktree
      fs.writeFileSync(
        path.join(wt1, "autoresearch.jsonl"),
        JSON.stringify({
          type: "config",
          name: "Task A",
          metricName: "metric_a",
          bestDirection: "lower",
        }) + "\n",
      );
      fs.writeFileSync(
        path.join(wt2, "autoresearch.jsonl"),
        JSON.stringify({
          type: "config",
          name: "Task B",
          metricName: "metric_b",
          bestDirection: "higher",
        }) + "\n",
      );

      // Session 2 should find its own worktree
      const { api: api2, tool: tool2 } = await loadFactory(tmpDir, "sess-2");
      await fireEvent(api2, "session_start");
      api2.execResults.set("git add", { stdout: "committed", stderr: "", code: 0 });
      api2.execResults.set("git rev-parse", { stdout: "abc1234", stderr: "", code: 0 });

      const result = await tool2("log_experiment").execute("tc1", {
        commit: "abc1234",
        metric: 100,
        status: "keep",
        description: "test",
      });

      // Should have loaded Task B's state, not Task A's
      expect(result.content[0].text).toContain("Logged #1");

      // Verify result was written to wt2, not wt1
      const wt2Lines = fs
        .readFileSync(path.join(wt2, "autoresearch.jsonl"), "utf-8")
        .trim()
        .split("\n");
      expect(wt2Lines.length).toBe(2); // config + result
    });

    it("child can run its own autoresearch independently", async () => {
      // Parent has its own worktree
      const parentWt = computeWorktreePaths(tmpDir, "Parent Opt").worktreePath;
      fs.mkdirSync(parentWt, { recursive: true });
      fs.writeFileSync(
        path.join(tmpDir, WORKTREE_MARKER),
        JSON.stringify({ sessionId: "parent", worktreePath: parentWt }) + "\n",
      );

      // Child session starts, no autoresearch active (different sessionId)
      const { api, tool } = await loadFactory(tmpDir, "child");
      mockGitWorktree(api);
      await fireEvent(api, "session_start");

      // Child calls init_experiment — gets its own worktree
      const result = await tool("init_experiment").execute("tc1", {
        name: "Child Opt",
        metric_name: "child_metric",
        direction: "lower",
      });

      expect(result.isError).toBeUndefined();
      expect(result.content[0].text).toContain("Experiment initialized");
      expect(result.content[0].text).toContain("Worktree:");

      // Verify marker now has TWO entries
      const markerContent = fs.readFileSync(path.join(tmpDir, WORKTREE_MARKER), "utf-8").trim();
      const markerLines = markerContent.split("\n").map((l) => JSON.parse(l));
      expect(markerLines.length).toBe(2);
      expect(
        markerLines.find((e: { sessionId: string }) => e.sessionId === "parent"),
      ).toBeDefined();
      expect(markerLines.find((e: { sessionId: string }) => e.sessionId === "child")).toBeDefined();

      // Child's worktree is different from parent's
      const childEntry = markerLines.find((e: { sessionId: string }) => e.sessionId === "child");
      expect(childEntry.worktreePath).not.toBe(parentWt);
    });
  });

  describe("log_experiment", () => {
    it("appends result to worktree autoresearch.jsonl", async () => {
      const { api, tool } = await loadFactory(tmpDir);
      mockGitWorktree(api);
      api.execResults.set("git add", { stdout: "committed", stderr: "", code: 0 });
      api.execResults.set("git rev-parse", { stdout: "abc1234", stderr: "", code: 0 });

      await tool("init_experiment").execute("tc1", {
        name: "Speed",
        metric_name: "seconds",
        direction: "lower",
      });

      const result = await tool("log_experiment").execute("tc2", {
        commit: "abc1234",
        metric: 42.3,
        status: "keep",
        description: "baseline measurement",
      });

      expect(result.content[0].text).toContain("Logged #1");
      expect(result.content[0].text).toContain("keep");

      const { worktreePath } = computeWorktreePaths(tmpDir, "Speed");
      const lines = fs
        .readFileSync(path.join(worktreePath, "autoresearch.jsonl"), "utf-8")
        .trim()
        .split("\n");
      expect(lines.length).toBe(2);
      expect(fs.existsSync(path.join(tmpDir, "autoresearch.jsonl"))).toBe(false);
    });

    it("emits expandedText in details", async () => {
      const { api, tool } = await loadFactory(tmpDir);
      mockGitWorktree(api);
      api.execResults.set("git add", { stdout: "committed", stderr: "", code: 0 });
      api.execResults.set("git rev-parse", { stdout: "abc1234", stderr: "", code: 0 });

      await tool("init_experiment").execute("tc1", {
        name: "Build Speed",
        metric_name: "build_s",
        metric_unit: "s",
        direction: "lower",
      });

      await tool("log_experiment").execute("tc2", {
        commit: "abc1234",
        metric: 60,
        status: "keep",
        description: "baseline",
      });

      const result = await tool("log_experiment").execute("tc3", {
        commit: "def5678",
        metric: 45,
        status: "keep",
        description: "parallel compilation",
      });

      const details = result.details as Record<string, unknown>;
      expect(details.ui).toBeUndefined();
      expect(details.expandedText).toBeDefined();
      expect(typeof details.expandedText).toBe("string");
      expect((details.expandedText as string).length).toBeGreaterThan(0);
    });

    it("rejects keep when checks failed", async () => {
      const { api, tool } = await loadFactory(tmpDir);
      mockGitWorktree(api);
      api.execResults.set("git add", { stdout: "committed", stderr: "", code: 0 });

      await tool("init_experiment").execute("tc1", {
        name: "Test",
        metric_name: "val",
        direction: "lower",
      });

      const { worktreePath } = computeWorktreePaths(tmpDir, "Test");
      const checksPath = path.join(worktreePath, "autoresearch.checks.sh");
      fs.writeFileSync(checksPath, "exit 1\n");

      api.execResults.set("bash -c echo", { stdout: "ok", stderr: "", code: 0 });
      api.execResults.set("bash " + checksPath, { stdout: "lint error", stderr: "", code: 1 });
      await tool("run_experiment").execute("tc2", { command: "echo ok" });

      const result = await tool("log_experiment").execute("tc3", {
        commit: "abc1234",
        metric: 10,
        status: "keep",
        description: "should fail",
      });

      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("Cannot keep");
    });

    it("validates secondary metrics consistency", async () => {
      const { api, tool } = await loadFactory(tmpDir);
      mockGitWorktree(api);
      api.execResults.set("git add", { stdout: "committed", stderr: "", code: 0 });
      api.execResults.set("git rev-parse", { stdout: "abc1234", stderr: "", code: 0 });

      await tool("init_experiment").execute("tc1", {
        name: "Multi-Metric",
        metric_name: "total",
        direction: "lower",
      });

      await tool("log_experiment").execute("tc2", {
        commit: "abc1234",
        metric: 100,
        status: "keep",
        description: "baseline",
        metrics: { compile_ms: 50, render_ms: 30 },
      });

      const result = await tool("log_experiment").execute("tc3", {
        commit: "def5678",
        metric: 90,
        status: "keep",
        description: "optimization",
        metrics: { compile_ms: 40 },
      });

      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("Missing secondary metrics");
    });
  });

  describe("run_experiment", () => {
    it("captures timing and exit code", async () => {
      const { api, tool } = await loadFactory(tmpDir);
      api.execResults.set("echo hello", { stdout: "hello\n", stderr: "", code: 0 });

      const result = await tool("run_experiment").execute("tc1", { command: "echo hello" });

      expect(result.content[0].text).toContain("PASSED");
      const details = result.details as RunDetails;
      expect(details.passed).toBe(true);
      expect(details.crashed).toBe(false);
    });

    it("detects failures", async () => {
      const { api, tool } = await loadFactory(tmpDir);
      api.execResults.set("false", { stdout: "", stderr: "error", code: 1 });

      const result = await tool("run_experiment").execute("tc1", { command: "false" });

      expect(result.content[0].text).toContain("FAILED");
      const details = result.details as RunDetails;
      expect(details.passed).toBe(false);
    });
  });

  describe("state reconstruction", () => {
    it("reconstructs state from worktree jsonl via marker", async () => {
      const { worktreePath } = computeWorktreePaths(tmpDir, "Resume");
      fs.mkdirSync(worktreePath, { recursive: true });

      // Write session-scoped marker
      fs.writeFileSync(
        path.join(tmpDir, WORKTREE_MARKER),
        JSON.stringify({ sessionId: "resume-sess", worktreePath }) + "\n",
      );

      const lines = [
        JSON.stringify({
          type: "config",
          name: "Speed Test",
          metricName: "seconds",
          metricUnit: "s",
          bestDirection: "lower",
        }),
        JSON.stringify({
          run: 1,
          commit: "abc1234",
          metric: 60,
          metrics: {},
          status: "keep",
          description: "baseline",
          timestamp: Date.now(),
          segment: 0,
        }),
        JSON.stringify({
          run: 2,
          commit: "def5678",
          metric: 45,
          metrics: {},
          status: "keep",
          description: "parallel",
          timestamp: Date.now(),
          segment: 0,
        }),
      ];
      fs.writeFileSync(path.join(worktreePath, "autoresearch.jsonl"), lines.join("\n") + "\n");

      const { api, tool } = await loadFactory(tmpDir, "resume-sess");
      await fireEvent(api, "session_start");

      api.execResults.set("git add", { stdout: "committed", stderr: "", code: 0 });
      api.execResults.set("git rev-parse", { stdout: "ghi9012", stderr: "", code: 0 });

      const result = await tool("log_experiment").execute("tc1", {
        commit: "ghi9012",
        metric: 40,
        status: "keep",
        description: "more optimization",
      });

      expect(result.content[0].text).toContain("Logged #3");
      expect(result.content[0].text).toContain("3 experiments total");

      const details = result.details as Record<string, unknown>;
      expect(details.ui).toBeUndefined();
      expect(details.expandedText).toBeDefined();
      expect(details.expandedText as string).toContain("3");
    });
  });

  describe("before_agent_start", () => {
    it("does not inject from file presence alone — requires tool activation", async () => {
      const { worktreePath } = computeWorktreePaths(tmpDir, "Active");
      fs.mkdirSync(worktreePath, { recursive: true });
      fs.writeFileSync(
        path.join(tmpDir, WORKTREE_MARKER),
        JSON.stringify({ sessionId: "active-sess", worktreePath }) + "\n",
      );
      fs.writeFileSync(
        path.join(worktreePath, "autoresearch.jsonl"),
        JSON.stringify({
          type: "config",
          name: "Active",
          metricName: "val",
          bestDirection: "lower",
        }) + "\n",
      );

      const { api } = await loadFactory(tmpDir, "active-sess");
      await fireEvent(api, "session_start");

      // Files exist but mode should NOT auto-activate — on-demand only
      const result = (await fireEvent(api, "before_agent_start", {
        prompt: "hello",
        systemPrompt: "You are an assistant.",
      })) as { systemPrompt?: string } | undefined;

      expect(result).toBeUndefined();
    });

    it("does not inject when autoresearch mode is inactive", async () => {
      const { api } = await loadFactory(tmpDir);

      const result = (await fireEvent(api, "before_agent_start", {
        prompt: "hello",
        systemPrompt: "You are an assistant.",
      })) as { systemPrompt?: string } | undefined;

      expect(result).toBeUndefined();
    });
  });

  describe("computeWorktreePaths", () => {
    it("sanitizes experiment name for branch", () => {
      const { branch, worktreePath } = computeWorktreePaths("/workspace/oppi", "DiffBuilder Perf");
      expect(branch).toMatch(/^autoresearch\/diffbuilder-perf-\d{4}-\d{2}-\d{2}$/);
      expect(worktreePath).toContain("oppi-autoresearch");
    });

    it("handles special characters", () => {
      const { branch } = computeWorktreePaths("/workspace/oppi", "---test!!!---");
      expect(branch).toMatch(/^autoresearch\/test-\d{4}-\d{2}-\d{2}$/);
    });

    it("falls back to 'experiment' for empty name", () => {
      const { branch } = computeWorktreePaths("/workspace/oppi", "---");
      expect(branch).toMatch(/^autoresearch\/experiment-\d{4}-\d{2}-\d{2}$/);
    });
  });

  describe("mobile renderers", () => {
    it("init_experiment renderer produces segments", async () => {
      const { MobileRendererRegistry } = await import("./mobile-renderer.js");
      const registry = new MobileRendererRegistry();

      const callSegs = registry.renderCall("init_experiment", { name: "Speed Test" });
      expect(callSegs).toBeDefined();
      expect(callSegs!.length).toBeGreaterThan(0);
      expect(callSegs!.some((s) => s.text.includes("Speed Test"))).toBe(true);
    });

    it("run_experiment renderer shows duration on success", async () => {
      const { MobileRendererRegistry } = await import("./mobile-renderer.js");
      const registry = new MobileRendererRegistry();

      const resultSegs = registry.renderResult(
        "run_experiment",
        { durationSeconds: 4.2, passed: true, crashed: false, timedOut: false, checksPass: null },
        false,
      );
      expect(resultSegs).toBeDefined();
      expect(resultSegs!.some((s) => s.text.includes("4.2"))).toBe(true);
    });

    it("log_experiment renderer shows status and metric", async () => {
      const { MobileRendererRegistry } = await import("./mobile-renderer.js");
      const registry = new MobileRendererRegistry();

      const callSegs = registry.renderCall("log_experiment", {
        status: "keep",
        description: "parallel build",
      });
      expect(callSegs).toBeDefined();
      expect(callSegs!.some((s) => s.style === "success")).toBe(true);

      const resultSegs = registry.renderResult(
        "log_experiment",
        {
          experiment: { status: "keep", metric: 42.3 },
          state: {
            metricName: "seconds",
            metricUnit: "s",
            bestMetric: 60,
            bestDirection: "lower",
          },
        },
        false,
      );
      expect(resultSegs).toBeDefined();
      expect(resultSegs!.some((s) => s.text.includes("keep"))).toBe(true);
      expect(resultSegs!.some((s) => s.text.includes("42.3"))).toBe(true);
    });
  });
});
