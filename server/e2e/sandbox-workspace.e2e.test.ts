/**
 * E2E: Sandbox workspace lifecycle
 *
 * Tests that sandbox workspaces can be created, retrieved, updated,
 * and listed via the REST API with the runtime and sandboxConfig fields
 * properly persisted and returned.
 *
 * Does NOT test actual VM execution (requires QEMU) — this validates
 * the API contract for sandbox workspaces.
 */

import { describe, it, expect, beforeAll, inject } from "vitest";
import { api, pairFreshDevice } from "./harness.js";

declare module "vitest" {
  export interface ProvidedContext {
    e2eLmsReady: boolean;
    e2eModel: string;
  }
}

describe("E2E: Sandbox Workspace Lifecycle", { timeout: 300_000 }, () => {
  const lmsReady = () => inject("e2eLmsReady");
  let deviceToken = "";
  let sandboxWorkspaceId = "";

  beforeAll(async () => {
    if (!lmsReady()) return;

    deviceToken = await pairFreshDevice("e2e-sandbox-test");
    expect(deviceToken).toBeTruthy();
  }, 120_000);

  it("creates a sandbox workspace", async () => {
    if (!lmsReady()) return;

    const res = await api("POST", "/workspaces", deviceToken, {
      name: "e2e-sandbox-workspace",
      tools: ["read", "bash", "edit", "write", "ask"],
      runtime: "sandbox",
      sandboxConfig: {
        allowedHosts: ["api.anthropic.com", "api.openai.com"],
        env: { SEARXNG_URL: "http://192.168.127.1:8888" },
      },
    });

    expect(res.status).toBe(201);
    expect(res.json?.workspace).toBeTruthy();

    const ws = res.json!.workspace as Record<string, unknown>;
    sandboxWorkspaceId = ws.id as string;
    expect(sandboxWorkspaceId).toBeTruthy();
    expect(ws.runtime).toBe("sandbox");
    expect(ws.tools).toEqual(["read", "bash", "edit", "write", "ask"]);
    expect(ws.sandboxConfig).toEqual({
      allowedHosts: ["api.anthropic.com", "api.openai.com"],
      env: { SEARXNG_URL: "http://192.168.127.1:8888" },
    });
  });

  it("retrieves sandbox workspace with runtime fields", async () => {
    if (!lmsReady()) return;

    const res = await api("GET", `/workspaces/${sandboxWorkspaceId}`, deviceToken);
    expect(res.status).toBe(200);

    const ws = res.json!.workspace as Record<string, unknown>;
    expect(ws.runtime).toBe("sandbox");
    expect(ws.tools).toEqual(["read", "bash", "edit", "write", "ask"]);
    expect(ws.sandboxConfig).toEqual({
      allowedHosts: ["api.anthropic.com", "api.openai.com"],
      env: { SEARXNG_URL: "http://192.168.127.1:8888" },
    });
  });

  it("updates sandbox tools and config", async () => {
    if (!lmsReady()) return;

    const res = await api("PUT", `/workspaces/${sandboxWorkspaceId}`, deviceToken, {
      tools: ["read", "bash", "web_search", "web_fetch"],
      sandboxConfig: {
        allowedHosts: ["*"],
        env: { SEARXNG_URL: "http://192.168.127.1:8888" },
      },
    });

    expect(res.status).toBe(200);
    const ws = res.json!.workspace as Record<string, unknown>;
    expect(ws.tools).toEqual(["read", "bash", "web_search", "web_fetch"]);
    expect(ws.sandboxConfig).toEqual({
      allowedHosts: ["*"],
      env: { SEARXNG_URL: "http://192.168.127.1:8888" },
    });
    expect(ws.runtime).toBe("sandbox");
  });

  it("lists workspaces including sandbox runtime", async () => {
    if (!lmsReady()) return;

    const res = await api("GET", "/workspaces", deviceToken);
    expect(res.status).toBe(200);

    const workspaces = res.json!.workspaces as Array<Record<string, unknown>>;
    const sandbox = workspaces.find((w) => w.id === sandboxWorkspaceId);
    expect(sandbox).toBeTruthy();
    expect(sandbox!.runtime).toBe("sandbox");
    expect(sandbox!.tools).toEqual(["read", "bash", "web_search", "web_fetch"]);
  });

  it("creates a host workspace without runtime field", async () => {
    if (!lmsReady()) return;

    const res = await api("POST", "/workspaces", deviceToken, {
      name: "e2e-host-workspace",
    });

    expect(res.status).toBe(201);
    const ws = res.json!.workspace as Record<string, unknown>;
    // runtime should be undefined/absent for backwards compat
    expect(ws.runtime).toBeUndefined();
    expect(ws.sandboxConfig).toBeUndefined();
  });

  it("switches workspace from host to sandbox", async () => {
    if (!lmsReady()) return;

    // Create a host workspace first
    const createRes = await api("POST", "/workspaces", deviceToken, {
      name: "e2e-switch-test",
      runtime: "host",
    });
    expect(createRes.status).toBe(201);
    const wsId = (createRes.json!.workspace as Record<string, unknown>).id as string;

    // Switch to sandbox
    const updateRes = await api("PUT", `/workspaces/${wsId}`, deviceToken, {
      runtime: "sandbox",
      sandboxConfig: { allowedHosts: ["example.com"] },
    });
    expect(updateRes.status).toBe(200);

    const ws = updateRes.json!.workspace as Record<string, unknown>;
    expect(ws.runtime).toBe("sandbox");
    expect(ws.sandboxConfig).toEqual({ allowedHosts: ["example.com"] });
  });
});
