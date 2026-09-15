import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { beforeEach, describe, expect, it, vi } from "vitest";

import { parseCliArgs } from "../src/cli/args.js";
import { cmdAgent } from "../src/cli/commands/agent.js";
import { localApiRequest, type LocalApiConnection } from "../src/cli/local-api-client.js";
import { captureCliOutput } from "../src/cli/output.js";

vi.mock("../src/cli/local-api-client.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/local-api-client.js")>();
  return { ...actual, localApiRequest: vi.fn() };
});

const storage = {} as LocalApiConnection;
const request = vi.mocked(localApiRequest);

const created = { agent: { id: "agent-1", name: "Reviewer", status: "active", version: 1 } };
const updated = { agent: { id: "agent-1", name: "Reviewer", status: "active", version: 4 } };

async function runAgent(
  action: string,
  positional: string[],
  flags: Record<string, string>,
): Promise<{ stdout: string; exitCode: number }> {
  return captureCliOutput(() => cmdAgent(storage, action, positional, { json: "true", ...flags }));
}

function postedBody(): Record<string, unknown> {
  const call = request.mock.calls.find((entry) => entry[1] === "/agents");
  expect(call).toBeDefined();
  return (call?.[2] as { body: Record<string, unknown> }).body;
}

function patchedBody(): Record<string, unknown> {
  const call = request.mock.calls.find((entry) => String(entry[1]).startsWith("/agents/"));
  expect(call).toBeDefined();
  return (call?.[2] as { body: Record<string, unknown> }).body;
}

describe("agent create/update editor-flag parity", () => {
  beforeEach(() => {
    request.mockReset();
    request.mockResolvedValue(created as never);
  });

  it("maps first-class create flags onto the native-editor definition fields", async () => {
    const captured = await runAgent("create", [], {
      name: "Reviewer",
      description: "Reviews diffs",
      icon: "🧘",
      instructions: "Be careful",
      "instructions-mode": "replace",
      skills: "review, security",
      extensions: "git, search",
      "allowed-workspaces": "ws-1, ws-2",
      "required-runtime": "sandbox",
      tools: "read, grep",
    });

    expect(captured.exitCode).toBe(0);
    expect(postedBody()).toEqual({
      name: "Reviewer",
      description: "Reviews diffs",
      icon: { kind: "emoji", value: "🧘" },
      instructions: { mode: "replace", text: "Be careful" },
      resources: {
        skillPaths: ["review", "security"],
        extensionIds: ["git", "search"],
      },
      launchConstraints: {
        allowedWorkspaceIds: ["ws-1", "ws-2"],
        requiredRuntime: "sandbox",
      },
      sessionDefaults: { tools: ["read", "grep"] },
    });
  });

  it("lets create omission inherit defaults instead of sending empty editor fields", async () => {
    await runAgent("create", [], { name: "Reviewer" });
    expect(postedBody()).toEqual({ name: "Reviewer" });
  });

  it("defaults instruction mode to append when creating from text without --instructions-mode", async () => {
    await runAgent("create", [], { name: "Reviewer", instructions: "Review diffs" });
    expect(postedBody()).toEqual({
      name: "Reviewer",
      instructions: { mode: "append", text: "Review diffs" },
    });
  });

  it("keeps JSON instructions.mode when overlaying --instructions without --instructions-mode", async () => {
    await runAgent("create", [], {
      name: "Reviewer",
      instructions: "new",
      "definition-json": JSON.stringify({
        instructions: { mode: "replace", text: "old" },
      }),
    });
    expect(postedBody()).toEqual({
      name: "Reviewer",
      instructions: { mode: "replace", text: "new" },
    });
  });

  it("reads --instructions-file and rejects combining it with --instructions", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-agent-instructions-"));
    try {
      const path = join(dir, "instructions.md");
      writeFileSync(path, "From file");
      await runAgent("create", [], {
        name: "Reviewer",
        "instructions-file": path,
        "instructions-mode": "replace",
      });
      expect(postedBody()).toEqual({
        name: "Reviewer",
        instructions: { mode: "replace", text: "From file" },
      });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }

    request.mockClear();
    const captured = await runAgent("create", [], {
      name: "Reviewer",
      instructions: "inline",
      "instructions-file": "instructions.md",
    });
    expect(captured.exitCode).toBe(1);
    expect(JSON.parse(captured.stdout)).toMatchObject({
      ok: false,
      error: { message: "--instructions and --instructions-file cannot be used together" },
    });
    expect(request).not.toHaveBeenCalled();
  });

  it("treats empty --skills and --extensions CSV as exact none, not inherit", async () => {
    await runAgent("create", [], { name: "Reviewer", skills: "", extensions: "  , " });
    expect(postedBody()).toEqual({
      name: "Reviewer",
      resources: { skillPaths: [], extensionIds: [] },
    });
  });

  it("maps parseCliArgs empty --skills/--extensions values through cmdAgent to exact none", async () => {
    const parsed = parseCliArgs([
      "agent",
      "create",
      "--name",
      "Reviewer",
      "--skills",
      "",
      "--extensions",
      "",
    ]);
    expect(parsed.flags).toMatchObject({ name: "Reviewer", skills: "", extensions: "" });
    await runAgent(parsed.positional[0] ?? "create", parsed.positional.slice(1), parsed.flags);
    expect(postedBody()).toEqual({
      name: "Reviewer",
      resources: { skillPaths: [], extensionIds: [] },
    });
  });

  it("maps parseCliArgs empty --allowed-workspaces to the empty-list rejection", async () => {
    const parsed = parseCliArgs([
      "agent",
      "create",
      "--name",
      "Reviewer",
      "--allowed-workspaces",
      "",
    ]);
    expect(parsed.flags["allowed-workspaces"]).toBe("");
    const captured = await runAgent(
      parsed.positional[0] ?? "create",
      parsed.positional.slice(1),
      parsed.flags,
    );
    expect(captured.exitCode).toBe(1);
    expect(JSON.parse(captured.stdout)).toMatchObject({
      ok: false,
      error: { message: "--allowed-workspaces must not be empty" },
    });
    expect(request).not.toHaveBeenCalled();
  });

  it("rejects an empty --allowed-workspaces list", async () => {
    const captured = await runAgent("create", [], {
      name: "Reviewer",
      "allowed-workspaces": " , ",
    });
    expect(captured.exitCode).toBe(1);
    expect(JSON.parse(captured.stdout)).toMatchObject({
      ok: false,
      error: { message: "--allowed-workspaces must not be empty" },
    });
    expect(request).not.toHaveBeenCalled();
  });

  it("rejects --clear-* flags on create", async () => {
    const captured = await runAgent("create", [], {
      name: "Reviewer",
      "clear-description": "true",
    });
    expect(captured.exitCode).toBe(1);
    expect(JSON.parse(captured.stdout).error.message).toMatch(
      /--clear-description is only valid on agent update/,
    );
    expect(request).not.toHaveBeenCalled();
  });

  it("patches from editor flags without JSON and overlays --name", async () => {
    request.mockResolvedValueOnce(updated as never);
    const captured = await runAgent("update", ["Reviewer"], {
      name: "FlagName",
      description: "Updated from flags",
      icon: "folder",
      "required-runtime": "host",
      "expected-version": "3",
    });

    expect(captured.exitCode).toBe(0);
    expect(request).toHaveBeenCalledWith(storage, "/agents/Reviewer?expectedVersion=3", {
      method: "PATCH",
      body: {
        name: "FlagName",
        description: "Updated from flags",
        icon: { kind: "symbol", name: "folder" },
        launchConstraints: { requiredRuntime: "host" },
      },
    });
  });

  it("rejects nested flags when definition JSON already set the parent object to null", async () => {
    const resources = await runAgent("update", ["Reviewer"], {
      skills: "review",
      "definition-json": JSON.stringify({ resources: null }),
    });
    expect(resources.exitCode).toBe(1);
    expect(JSON.parse(resources.stdout)).toMatchObject({
      ok: false,
      error: {
        message:
          "cannot overlay resources.skillPaths because resources is null in the definition JSON",
      },
    });
    expect(request).not.toHaveBeenCalled();

    const constraints = await runAgent("update", ["Reviewer"], {
      "required-runtime": "sandbox",
      "definition-json": JSON.stringify({ launchConstraints: null }),
    });
    expect(constraints.exitCode).toBe(1);
    expect(JSON.parse(constraints.stdout).error.message).toBe(
      "cannot overlay launchConstraints.requiredRuntime because launchConstraints is null in the definition JSON",
    );
    expect(request).not.toHaveBeenCalled();
  });

  it("overlays flags onto JSON without dropping sibling nested fields", async () => {
    request.mockResolvedValueOnce(updated as never);
    await runAgent("update", ["Reviewer"], {
      skills: "new-skill",
      "required-runtime": "sandbox",
      "definition-json": JSON.stringify({
        resources: {
          skillPaths: ["old-skill"],
          extensionIds: ["git"],
          agentsFiles: [{ path: "AGENTS.md", content: "keep" }],
        },
        launchConstraints: { allowedWorkspaceIds: ["ws-1"], requiredRuntime: "host" },
        sessionDefaults: { model: "json-model", tools: ["write"] },
      }),
    });

    expect(patchedBody()).toEqual({
      resources: {
        skillPaths: ["new-skill"],
        extensionIds: ["git"],
        agentsFiles: [{ path: "AGENTS.md", content: "keep" }],
      },
      launchConstraints: { allowedWorkspaceIds: ["ws-1"], requiredRuntime: "sandbox" },
      sessionDefaults: { model: "json-model", tools: ["write"] },
    });
  });

  it("requires instruction text from flags or JSON when --instructions-mode is set", async () => {
    const modeOnly = await runAgent("update", ["Reviewer"], { "instructions-mode": "replace" });
    expect(modeOnly.exitCode).toBe(1);
    expect(JSON.parse(modeOnly.stdout)).toMatchObject({
      ok: false,
      error: {
        message:
          "--instructions-mode requires --instructions, --instructions-file, or instructions.text in the definition JSON",
      },
    });
    expect(request).not.toHaveBeenCalled();

    request.mockResolvedValueOnce(updated as never);
    await runAgent("update", ["Reviewer"], {
      "instructions-mode": "replace",
      "definition-json": JSON.stringify({
        instructions: { mode: "append", text: "Keep me" },
      }),
    });
    expect(patchedBody()).toEqual({
      instructions: { mode: "replace", text: "Keep me" },
    });
  });

  it("writes update reset flags as JSON-null nested keys and rejects value/clear twins", async () => {
    request.mockResolvedValueOnce(updated as never);
    await runAgent("update", ["Reviewer"], {
      "clear-description": "true",
      "clear-icon": "true",
      "clear-instructions": "true",
      "clear-skills": "true",
      "clear-extensions": "true",
      "clear-allowed-workspaces": "true",
      "clear-required-runtime": "true",
    });
    expect(patchedBody()).toEqual({
      description: null,
      icon: null,
      instructions: null,
      resources: { skillPaths: null, extensionIds: null },
      launchConstraints: { allowedWorkspaceIds: null, requiredRuntime: null },
    });

    request.mockClear();
    const captured = await runAgent("update", ["Reviewer"], {
      description: "keep",
      "clear-description": "true",
    });
    expect(captured.exitCode).toBe(1);
    expect(JSON.parse(captured.stdout)).toMatchObject({
      ok: false,
      error: { message: "--description and --clear-description cannot be used together" },
    });
    expect(request).not.toHaveBeenCalled();
  });

  it.each([
    ["icon", "clear-icon"],
    ["instructions", "clear-instructions"],
    ["instructions-file", "clear-instructions"],
    ["instructions-mode", "clear-instructions"],
    ["skills", "clear-skills"],
    ["extensions", "clear-extensions"],
    ["allowed-workspaces", "clear-allowed-workspaces"],
    ["required-runtime", "clear-required-runtime"],
  ] as const)("rejects combining --%s with --%s", async (valueFlag, clearFlag) => {
    const captured = await runAgent("update", ["Reviewer"], {
      [valueFlag]: valueFlag === "required-runtime" ? "host" : "x",
      [clearFlag]: "true",
    });
    expect(captured.exitCode).toBe(1);
    expect(JSON.parse(captured.stdout).error.message).toMatch(
      new RegExp(`--${valueFlag}.*--${clearFlag}|--${clearFlag}`),
    );
    expect(request).not.toHaveBeenCalled();
  });

  it("keeps JSON-only create and update bodies unchanged when no editor flags are set", async () => {
    await runAgent("create", [], {
      "definition-json": JSON.stringify({
        name: "Inline Reviewer",
        description: "Inline create",
        resources: { skillPaths: ["review"] },
      }),
    });
    expect(postedBody()).toEqual({
      name: "Inline Reviewer",
      description: "Inline create",
      resources: { skillPaths: ["review"] },
    });

    request.mockResolvedValueOnce(updated as never);
    await runAgent("update", ["agent-1"], {
      "definition-json": JSON.stringify({ description: "Inline update" }),
    });
    expect(patchedBody()).toEqual({ description: "Inline update" });
  });
});

describe("agent get human inspection", () => {
  beforeEach(() => {
    request.mockReset();
    request.mockResolvedValue({
      agent: { id: "agent-1", name: "Sensei", status: "active", version: 2 },
    } as never);
  });

  it("prints metadata and tells agents to pass --json for the full definition", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    try {
      await cmdAgent(storage, "get", ["Sensei"], {});
      const text = log.mock.calls.flat().join("\n");
      expect(text).toContain("agent-1");
      expect(text).toContain("Sensei");
      expect(text).toContain("active");
      expect(text).toContain("v2");
      expect(text).toContain("For the full definition, run `oppi agent get Sensei --json`.");
      expect(text).not.toContain("sessionDefaults");
      expect(text).not.toContain("skillPaths");
    } finally {
      log.mockRestore();
    }
  });
});
