/**
 * A Workspace write is stored as it is sent or refused: the route answers 400 with the reason
 * instead of the store turning a loose runtime or sandbox config into a different Workspace.
 */

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createRouteHelpers } from "../src/routes/http.js";
import type { RouteContext } from "../src/routes/types.js";
import { createWorkspaceRoutes } from "../src/routes/workspaces.js";
import { Storage } from "../src/storage.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

let dataDir: string;
let storage: Storage;

beforeEach(() => {
  dataDir = mkdtempSync(join(tmpdir(), "oppi-ws-write-"));
  storage = new Storage(dataDir);
});

afterEach(() => {
  rmSync(dataDir, { recursive: true, force: true });
});

async function send(
  method: "POST" | "PUT",
  path: string,
  body: unknown,
): Promise<{ status: number; body: { error?: string; workspace?: Record<string, unknown> } }> {
  const dispatch = createWorkspaceRoutes(
    { storage } as unknown as RouteContext,
    createRouteHelpers(),
  );
  const res = makeResponse();
  await dispatch({
    method,
    path,
    url: new URL(`http://localhost${path}`),
    req: makeRequest(body) as never,
    res: res as never,
  });
  return { status: res.statusCode, body: JSON.parse(res.body) };
}

const sandboxConfig = {
  allowedHosts: ["github.com"],
  env: { LANG: "C" },
  mcpServers: ["fs"],
};

describe("Workspace writes", () => {
  it("stores a valid create and update exactly as sent", async () => {
    const created = await send("POST", "/workspaces", {
      name: "Sandboxed",
      runtime: "sandbox",
      sandboxConfig,
    });
    expect(created.status).toBe(201);
    expect(created.body.workspace).toMatchObject({ runtime: "sandbox", sandboxConfig });
    const id = created.body.workspace?.id as string;

    const update = await send("PUT", `/workspaces/${id}`, {
      sandboxConfig: { allowedHosts: [], env: { BASH_ENV: "/tmp/b" } },
    });
    expect(update.status).toBe(200);
    // The config is replaced whole, and an empty allow-list stays an empty allow-list.
    expect(update.body.workspace?.sandboxConfig).toEqual({
      allowedHosts: [],
      env: { BASH_ENV: "/tmp/b" },
    });

    const cleared = await send("PUT", `/workspaces/${id}`, { sandboxConfig: null });
    expect(cleared.status).toBe(200);
    expect(cleared.body.workspace?.sandboxConfig).toBeUndefined();
  });

  it("accepts the bodies the apps send", async () => {
    const workspace = storage.createWorkspace({ name: "Apps", runtime: "sandbox", sandboxConfig });
    const bodies = [
      { name: "Renamed", description: null, icon: { kind: "default" }, hostMount: null },
      { systemPrompt: null, systemPromptMode: "append" },
      { systemPrompt: "Be brief.", gitStatusEnabled: false },
      { sandboxConfig: { allowedHosts: ["*"], mcpServers: [] } },
      { sandboxConfig: { allowedHosts: ["*"], mcpServers: ["fs"], env: { LANG: "C" } } },
      { tools: ["read", "grep"] },
      { tools: null },
    ];
    for (const body of bodies) {
      const update = await send("PUT", `/workspaces/${workspace.id}`, body);
      expect(update.status, JSON.stringify(body)).toBe(200);
    }
    const created = await send("POST", "/workspaces", {
      name: "From iOS",
      description: "d",
      icon: { kind: "default" },
      gitStatusEnabled: true,
      runtime: "sandbox",
      sandboxConfig: {},
    });
    expect(created.status).toBe(201);
  });

  it.each([
    ["a runtime with a trailing space", { runtime: "sandbox " }, /runtime must be/],
    ["a runtime in capitals", { runtime: "Sandbox" }, /runtime must be/],
    ["a null runtime", { runtime: null }, /runtime must be/],
    ["an unknown top-level field", { "sandboxConfig.allowedHosts": [] }, /Unknown Workspace field/],
    ["a stored-record field", { id: "x", createdAt: 1 }, /Unknown Workspace field/],
    ["the retired skills field", { skills: [] }, /Unknown Workspace field/],
    ["tools of only a space", { tools: [" "] }, /tools must be an array/],
    ["an empty tool name", { tools: ["read", ""] }, /tools must be an array/],
    ["an untrimmed tool name", { tools: [" read"] }, /tools must be an array/],
    ["tools as a string", { tools: "read" }, /tools must be an array/],
    [
      "a systemPrompt that is a list",
      { systemPrompt: ["Never push", "Run tests"] },
      /systemPrompt must be a string/,
    ],
    ["a description that is an object", { description: { a: 1 } }, /description must be a string/],
    [
      "gitStatusEnabled as a string",
      { gitStatusEnabled: "false" },
      /gitStatusEnabled must be true or false/,
    ],
    ["a null name", { name: null }, /name (required|must be a non-empty string)/],
    ["an object name", { name: { a: 1 } }, /name must be a non-empty string/],
    ["an empty name", { name: "" }, /name (required|must be a non-empty string)/],
    [
      "allowedHosts as a string",
      { sandboxConfig: { allowedHosts: "github.com" } },
      /allowedHosts must be an array/,
    ],
    [
      "a non-string host",
      { sandboxConfig: { allowedHosts: ["a", 5] } },
      /allowedHosts must be an array/,
    ],
    [
      "a non-string env value",
      { sandboxConfig: { env: { X: 5 } } },
      /env must be an object of string/,
    ],
    ["env as an array", { sandboxConfig: { env: ["X=1"] } }, /env must be an object of string/],
    [
      "a dotted key in the config",
      { sandboxConfig: { "env.BASH_ENV": "/etc/profile" } },
      /Unknown sandboxConfig field/,
    ],
    [
      "an unknown config field",
      { sandboxConfig: { network: "off" } },
      /Unknown sandboxConfig field/,
    ],
    [
      "an invalid MCP server name",
      { sandboxConfig: { mcpServers: ["fs", "a b"] } },
      /mcpServers must be an array/,
    ],
    [
      "a sandboxConfig that is not an object",
      { sandboxConfig: "none" },
      /sandboxConfig must be an object/,
    ],
  ])("refuses %s with 400 and changes nothing", async (_what, body, message) => {
    const workspace = storage.createWorkspace({
      name: "Kept",
      runtime: "sandbox",
      sandboxConfig,
    });

    const update = await send("PUT", `/workspaces/${workspace.id}`, body);
    expect(update.status).toBe(400);
    expect(update.body.error).toMatch(message);
    expect(storage.getWorkspace(workspace.id)).toMatchObject({
      runtime: "sandbox",
      sandboxConfig,
      updatedAt: workspace.updatedAt,
    });

    const create = await send("POST", "/workspaces", { name: "New", ...body });
    expect(create.status).toBe(400);
    expect(create.body.error).toMatch(message);
    expect(storage.listWorkspaces().map((item) => item.name)).toEqual(["Kept"]);
  });
});
