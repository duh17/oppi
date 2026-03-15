import { describe, it, expect, beforeEach, afterEach } from "vitest";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

import type { RunDetails } from "./autoresearch-extension.js";

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
    sentMessages: [],
    registerTool(tool) {
      api.tools.set(tool.name, tool);
    },
    on(event, handler) {
      if (!api.handlers.has(event)) api.handlers.set(event, []);
      api.handlers.get(event)!.push(handler);
    },
    async exec(cmd, args) {
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
  });

  async function loadFactory(
    cwd: string,
  ): Promise<{ api: MockExtensionAPI; tool: (name: string) => RegisteredTool }> {
    // Dynamic import to avoid issues with module state
    const { createAutoresearchFactory } = await import("./autoresearch-extension.js");
    const api = createMockAPI();
    const factory = createAutoresearchFactory(cwd);
    await factory(api as unknown as Parameters<typeof factory>[0]);
    const tool = (name: string): RegisteredTool => {
      const t = api.tools.get(name);
      if (!t) throw new Error(`Tool ${name} not registered`);
      return t;
    };
    return { api, tool };
  }

  describe("init_experiment", () => {
    it("registers three tools", async () => {
      const { api } = await loadFactory(tmpDir);
      expect(api.tools.has("init_experiment")).toBe(true);
      expect(api.tools.has("run_experiment")).toBe(true);
      expect(api.tools.has("log_experiment")).toBe(true);
    });

    it("writes config to autoresearch.jsonl", async () => {
      const { tool } = await loadFactory(tmpDir);
      const result = await tool("init_experiment").execute("tc1", {
        name: "Test Optimization",
        metric_name: "duration_ms",
        metric_unit: "ms",
        direction: "lower",
      });

      expect(result.content[0].text).toContain("Experiment initialized");
      expect(result.content[0].text).toContain("Test Optimization");

      const jsonlPath = path.join(tmpDir, "autoresearch.jsonl");
      expect(fs.existsSync(jsonlPath)).toBe(true);

      const content = fs.readFileSync(jsonlPath, "utf-8").trim();
      const config = JSON.parse(content);
      expect(config.type).toBe("config");
      expect(config.name).toBe("Test Optimization");
      expect(config.metricName).toBe("duration_ms");
      expect(config.metricUnit).toBe("ms");
      expect(config.bestDirection).toBe("lower");
    });
  });

  describe("log_experiment", () => {
    it("appends result to autoresearch.jsonl", async () => {
      const { api, tool } = await loadFactory(tmpDir);

      // Set up git mock
      api.execResults.set("git add", { stdout: "committed", stderr: "", code: 0 });
      api.execResults.set("git rev-parse", { stdout: "abc1234", stderr: "", code: 0 });

      // Init first
      await tool("init_experiment").execute("tc1", {
        name: "Speed",
        metric_name: "seconds",
        direction: "lower",
      });

      // Log a result
      const result = await tool("log_experiment").execute("tc2", {
        commit: "abc1234",
        metric: 42.3,
        status: "keep",
        description: "baseline measurement",
      });

      expect(result.content[0].text).toContain("Logged #1");
      expect(result.content[0].text).toContain("keep");

      // Check jsonl has config + result
      const lines = fs
        .readFileSync(path.join(tmpDir, "autoresearch.jsonl"), "utf-8")
        .trim()
        .split("\n");
      expect(lines.length).toBe(2);

      const resultLine = JSON.parse(lines[1]);
      expect(resultLine.metric).toBe(42.3);
      expect(resultLine.status).toBe("keep");
      expect(resultLine.description).toBe("baseline measurement");
    });

    it("emits chart payload in details.ui", async () => {
      const { api, tool } = await loadFactory(tmpDir);
      api.execResults.set("git add", { stdout: "committed", stderr: "", code: 0 });
      api.execResults.set("git rev-parse", { stdout: "abc1234", stderr: "", code: 0 });

      await tool("init_experiment").execute("tc1", {
        name: "Build Speed",
        metric_name: "build_s",
        metric_unit: "s",
        direction: "lower",
      });

      // Log baseline
      await tool("log_experiment").execute("tc2", {
        commit: "abc1234",
        metric: 60,
        status: "keep",
        description: "baseline",
      });

      // Log improvement
      const result = await tool("log_experiment").execute("tc3", {
        commit: "def5678",
        metric: 45,
        status: "keep",
        description: "parallel compilation",
      });

      const details = result.details as Record<string, unknown>;
      expect(details).toBeDefined();

      // Check chart payload
      const ui = details.ui as Record<string, unknown>[];
      expect(ui).toBeDefined();
      expect(ui.length).toBe(1);
      expect(ui[0].kind).toBe("chart");
      expect(ui[0].version).toBe(1);

      const spec = (ui[0] as Record<string, unknown>).spec as Record<string, unknown>;
      expect(spec).toBeDefined();

      const dataset = spec.dataset as { rows: Record<string, unknown>[] };
      expect(dataset.rows.length).toBe(2);
      expect(dataset.rows[0].build_s).toBe(60);
      expect(dataset.rows[1].build_s).toBe(45);

      // Check expandedText
      expect(details.expandedText).toBeDefined();
      expect(typeof details.expandedText).toBe("string");
    });

    it("rejects keep when checks failed", async () => {
      const { api, tool } = await loadFactory(tmpDir);
      api.execResults.set("git add", { stdout: "committed", stderr: "", code: 0 });

      await tool("init_experiment").execute("tc1", {
        name: "Test",
        metric_name: "val",
        direction: "lower",
      });

      // Write a checks file so run_experiment runs it
      const checksPath = path.join(tmpDir, "autoresearch.checks.sh");
      fs.writeFileSync(checksPath, "exit 1\n");

      // Run experiment — benchmark passes but checks fail
      api.execResults.set("bash -c echo", { stdout: "ok", stderr: "", code: 0 });
      api.execResults.set("bash " + checksPath, { stdout: "lint error", stderr: "", code: 1 });
      await tool("run_experiment").execute("tc2", { command: "echo ok" });

      // Try to keep — should be rejected
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
      api.execResults.set("git add", { stdout: "committed", stderr: "", code: 0 });
      api.execResults.set("git rev-parse", { stdout: "abc1234", stderr: "", code: 0 });

      await tool("init_experiment").execute("tc1", {
        name: "Multi-Metric",
        metric_name: "total",
        direction: "lower",
      });

      // First log with secondary metrics
      await tool("log_experiment").execute("tc2", {
        commit: "abc1234",
        metric: 100,
        status: "keep",
        description: "baseline",
        metrics: { compile_ms: 50, render_ms: 30 },
      });

      // Second log missing a metric
      const result = await tool("log_experiment").execute("tc3", {
        commit: "def5678",
        metric: 90,
        status: "keep",
        description: "optimization",
        metrics: { compile_ms: 40 },
      });

      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("Missing secondary metrics");
      expect(result.content[0].text).toContain("render_ms");
    });
  });

  describe("run_experiment", () => {
    it("captures timing and exit code", async () => {
      const { api, tool } = await loadFactory(tmpDir);

      api.execResults.set("echo hello", { stdout: "hello\n", stderr: "", code: 0 });

      const result = await tool("run_experiment").execute("tc1", {
        command: "echo hello",
      });

      expect(result.content[0].text).toContain("PASSED");
      const details = result.details as RunDetails;
      expect(details.passed).toBe(true);
      expect(details.crashed).toBe(false);
      expect(typeof details.durationSeconds).toBe("number");
    });

    it("detects failures", async () => {
      const { api, tool } = await loadFactory(tmpDir);

      api.execResults.set("false", { stdout: "", stderr: "error", code: 1 });

      const result = await tool("run_experiment").execute("tc1", {
        command: "false",
      });

      expect(result.content[0].text).toContain("FAILED");
      const details = result.details as RunDetails;
      expect(details.passed).toBe(false);
      expect(details.crashed).toBe(true);
    });
  });

  describe("state reconstruction", () => {
    it("reconstructs state from existing jsonl on session_start", async () => {
      // Pre-populate jsonl
      const jsonlPath = path.join(tmpDir, "autoresearch.jsonl");
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
      fs.writeFileSync(jsonlPath, lines.join("\n") + "\n");

      const { api, tool } = await loadFactory(tmpDir);

      // Fire session_start to trigger reconstruction
      await fireEvent(api, "session_start");

      // Log another experiment — it should know about the 2 existing ones
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

      // Chart should have 3 data points
      const details = result.details as Record<string, unknown>;
      const ui = details.ui as Record<string, unknown>[];
      const spec = (ui[0] as Record<string, unknown>).spec as Record<string, unknown>;
      const dataset = spec.dataset as { rows: Record<string, unknown>[] };
      expect(dataset.rows.length).toBe(3);
    });
  });

  describe("before_agent_start", () => {
    it("injects autoresearch context when mode is active", async () => {
      // Create jsonl to activate mode
      const jsonlPath = path.join(tmpDir, "autoresearch.jsonl");
      fs.writeFileSync(
        jsonlPath,
        JSON.stringify({
          type: "config",
          name: "Test",
          metricName: "val",
          bestDirection: "lower",
        }) + "\n",
      );

      const { api } = await loadFactory(tmpDir);
      await fireEvent(api, "session_start");

      const result = (await fireEvent(api, "before_agent_start", {
        prompt: "hello",
        systemPrompt: "You are an assistant.",
      })) as { systemPrompt?: string } | undefined;

      expect(result).toBeDefined();
      expect(result!.systemPrompt).toContain("Autoresearch Mode (ACTIVE)");
      expect(result!.systemPrompt).toContain("NEVER STOP until interrupted");
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
