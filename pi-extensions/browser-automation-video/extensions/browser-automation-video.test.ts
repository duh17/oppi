import { describe, expect, it } from "vitest";

import browserAutomationVideoExtension, {
  defaultOutputName,
  normalizeURL,
  resolveOutputDir,
  safeBaseName,
  stepToCommand,
  type BrowserStep,
} from "./browser-automation-video.js";

type RegisteredTool = {
  name: string;
  label?: string;
  description?: string;
  promptSnippet?: string;
  promptGuidelines?: string[];
  parameters?: unknown;
  execute?: (
    toolCallId: string,
    params: Record<string, unknown>,
    signal: AbortSignal | undefined,
    onUpdate: unknown,
    ctx: { cwd?: string },
  ) => Promise<unknown>;
};

function createMockAPI(): {
  tools: Map<string, RegisteredTool>;
  registerTool(tool: RegisteredTool): void;
} {
  const tools = new Map<string, RegisteredTool>();
  return {
    tools,
    registerTool(tool: RegisteredTool) {
      tools.set(tool.name, tool);
    },
  };
}

describe("browser automation video extension", () => {
  it("registers browser_automation_video with Oppi media guidance", () => {
    const api = createMockAPI();
    browserAutomationVideoExtension(api as never);

    const tool = api.tools.get("browser_automation_video");
    expect(tool).toBeDefined();
    expect(tool?.promptGuidelines?.join("\n")).toContain("session attachment");
    expect(tool?.promptGuidelines?.join("\n")).toContain("outputDir");
  });

  it("requires outputDir when Oppi attachment storage is unavailable", async () => {
    const api = createMockAPI();
    browserAutomationVideoExtension(api as never);
    const tool = api.tools.get("browser_automation_video");

    await expect(
      tool?.execute?.("tool-call-1", {}, undefined, undefined, {
        cwd: "/tmp/workspace",
      }),
    ).rejects.toThrow("outputDir is required");
  });

  it("normalizes browser URLs", () => {
    expect(normalizeURL(undefined)).toBe("https://example.com");
    expect(normalizeURL("example.org/path")).toBe("https://example.org/path");
    expect(normalizeURL("http://localhost:5173")).toBe("http://localhost:5173");
  });

  it("converts structured steps to agent-browser batch commands", () => {
    const steps: BrowserStep[] = [
      { action: "click", selector: "#submit" },
      { action: "fill", selector: "input[name=q]", text: "hello world" },
      { action: "keyboardType", text: "done" },
      { action: "press", key: "Enter" },
      { action: "wait", text: "Results loaded" },
      { action: "scroll", direction: "down", pixels: 900 },
      { action: "eval", script: "document.title" },
      { action: "snapshot" },
    ];

    expect(steps.map(stepToCommand)).toEqual([
      "click #submit",
      'fill "input[name=q]" "hello world"',
      "keyboard type done",
      "press Enter",
      'wait --text "Results loaded"',
      "scroll down 900",
      "eval document.title",
      "snapshot",
    ]);
  });

  it("validates required step fields", () => {
    expect(() => stepToCommand({ action: "click" })).toThrow(
      "Missing click.selector",
    );
    expect(() => stepToCommand({ action: "drag" })).toThrow(
      "Unsupported browser automation step action",
    );
  });

  it("keeps generated file names safe and bounded", () => {
    expect(safeBaseName("Example Demo!.mp4")).toBe("example-demo");
    expect(safeBaseName("***")).toMatch(/^browser-video-/);
    expect(safeBaseName("a".repeat(120))).toHaveLength(80);
  });

  it("resolves output directories relative to cwd", () => {
    expect(resolveOutputDir("/tmp/workspace", "recordings")).toBe(
      "/tmp/workspace/recordings",
    );
    expect(resolveOutputDir("/tmp/workspace", "/tmp/out")).toBe("/tmp/out");
  });

  it("derives default output names from URL hostnames", () => {
    expect(defaultOutputName("https://example.com/a")).toMatch(
      /^example\.com-\d{4}-\d{2}-\d{2}T/,
    );
  });
});
