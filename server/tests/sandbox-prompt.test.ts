import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, readFileSync, rmSync, existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { generateSystemPrompt } from "../src/sandbox-prompt.js";
import type { Workspace } from "../src/types.js";

function ws(overrides: Partial<Workspace> = {}): Workspace {
  return {
    id: "ws-test",
    name: "research",
    runtime: "container",
    skills: [],
    createdAt: Date.now(),
    updatedAt: Date.now(),
    ...overrides,
  };
}

describe("generateSystemPrompt", () => {
  let piDir: string;

  beforeEach(() => {
    piDir = mkdtempSync(join(tmpdir(), "oppi-prompt-"));
  });

  afterEach(() => {
    if (existsSync(piDir)) rmSync(piDir, { recursive: true });
  });

  function readPrompt(): string {
    return readFileSync(join(piDir, "system-prompt.md"), "utf-8");
  }

  it("writes system-prompt.md to piDir", () => {
    generateSystemPrompt(piDir, ["search", "fetch"], "10.201.0.1");
    expect(existsSync(join(piDir, "system-prompt.md"))).toBe(true);
  });

  it("includes host gateway in prompt", () => {
    generateSystemPrompt(piDir, [], "10.201.0.1");
    expect(readPrompt()).toContain("10.201.0.1");
  });

  it("lists installed skills", () => {
    generateSystemPrompt(piDir, ["search", "fetch", "web-browser"], "10.201.0.1");
    const prompt = readPrompt();
    expect(prompt).toContain("**search**");
    expect(prompt).toContain("**fetch**");
    expect(prompt).toContain("**web-browser**");
  });

  it("includes search CLI tool when search skill installed", () => {
    generateSystemPrompt(piDir, ["search"], "10.201.0.1");
    expect(readPrompt()).toContain("SearXNG web search");
  });

  it("includes fetch CLI tool variants when fetch skill installed", () => {
    generateSystemPrompt(piDir, ["fetch"], "10.201.0.1");
    const prompt = readPrompt();
    expect(prompt).toContain("Extract readable content");
    expect(prompt).toContain("--browser");
  });

  it("always includes standard dev tools", () => {
    generateSystemPrompt(piDir, [], "10.201.0.1");
    const prompt = readPrompt();
    expect(prompt).toContain("git");
    expect(prompt).toContain("rg");
    expect(prompt).toContain("jq");
  });

  it("includes username when provided", () => {
    generateSystemPrompt(piDir, [], "10.201.0.1", { userName: "Chen" });
    expect(readPrompt()).toContain("Chen");
  });

  it("includes model when provided", () => {
    generateSystemPrompt(piDir, [], "10.201.0.1", { model: "claude-sonnet-4" });
    expect(readPrompt()).toContain("claude-sonnet-4");
  });

  it("includes workspace name and description", () => {
    generateSystemPrompt(piDir, [], "10.201.0.1", {
      workspace: ws({ name: "oppi-dev", description: "Main coding workspace" }),
    });
    const prompt = readPrompt();
    expect(prompt).toContain("**oppi-dev**");
    expect(prompt).toContain("Main coding workspace");
  });

  it("appends workspace custom system prompt", () => {
    generateSystemPrompt(piDir, [], "10.201.0.1", {
      workspace: ws({ systemPrompt: "Always use TypeScript strict mode." }),
    });
    expect(readPrompt()).toContain("Always use TypeScript strict mode.");
    expect(readPrompt()).toContain("Workspace Instructions");
  });

  it("does not include workspace instructions section when no custom prompt", () => {
    generateSystemPrompt(piDir, [], "10.201.0.1", { workspace: ws() });
    expect(readPrompt()).not.toContain("Workspace Instructions");
  });

  it("includes memory section when memoryEnabled", () => {
    generateSystemPrompt(piDir, [], "10.201.0.1", {
      workspace: ws({ memoryEnabled: true, memoryNamespace: "shared" }),
    });
    const prompt = readPrompt();
    expect(prompt).toContain("Memory");
    expect(prompt).toContain("shared");
    expect(prompt).toContain("recall");
    expect(prompt).toContain("remember");
  });

  it("does not include memory section when memoryEnabled is false", () => {
    generateSystemPrompt(piDir, [], "10.201.0.1", {
      workspace: ws({ memoryEnabled: false }),
    });
    expect(readPrompt()).not.toContain("## Memory");
  });

  it("includes security contract", () => {
    generateSystemPrompt(piDir, [], "10.201.0.1");
    const prompt = readPrompt();
    expect(prompt).toContain("Security contract");
    expect(prompt).toContain("untrusted");
  });

  it("includes mobile output contract", () => {
    generateSystemPrompt(piDir, [], "10.201.0.1");
    const prompt = readPrompt();
    expect(prompt).toContain("Mobile output contract");
    expect(prompt).toContain("phone");
    expect(prompt).toContain("autonomously");
  });

  it("includes permission gate section", () => {
    generateSystemPrompt(piDir, [], "10.201.0.1");
    expect(readPrompt()).toContain("Permission gate");
  });
});
