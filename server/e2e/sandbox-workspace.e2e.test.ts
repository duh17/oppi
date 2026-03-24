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
import { api, generateTestInvite } from "./harness.js";

declare module "vitest" {
  export interface ProvidedContext {
    e2eLmsReady: boolean;
    e2eModel: string;
  }
}

describe("E2E: Sandbox Workspace Lifecycle", { timeout: 120_000 }, () => {
  const lmsReady = () => inject("e2eLmsReady");
  let deviceToken = "";
  let sandboxWorkspaceId = "";

  beforeAll(async () => {
    if (!lmsReady()) return;

    // Pair a device
    for (let attempt = 0; attempt < 3; attempt++) {
      const invite = await generateTestInvite();
      const pairRes = await api("POST", "/pair", undefined, {
        pairingToken: invite.pairingToken,
        deviceName: "e2e-sandbox-test",
        pushToken: null,
      });
      if (pairRes.status === 200 && pairRes.json?.deviceToken) {
        deviceToken = pairRes.json.deviceToken as string;
        break;
      }
    }
    expect(deviceToken).toBeTruthy();
  });

  it("creates a sandbox workspace", async () => {
    if (!lmsReady()) return;

    const res = await api("POST", "/workspaces", deviceToken, {
      name: "e2e-sandbox-workspace",
      skills: [],
      runtime: "sandbox",
      sandboxConfig: { allowedHosts: ["api.anthropic.com", "api.openai.com"] },
    });

    expect(res.status).toBe(201);
    expect(res.json?.workspace).toBeTruthy();

    const ws = res.json!.workspace as Record<string, unknown>;
    sandboxWorkspaceId = ws.id as string;
    expect(sandboxWorkspaceId).toBeTruthy();
    expect(ws.runtime).toBe("sandbox");
    expect(ws.sandboxConfig).toEqual({
      allowedHosts: ["api.anthropic.com", "api.openai.com"],
    });
  });

  it("retrieves sandbox workspace with runtime fields", async () => {
    if (!lmsReady()) return;

    const res = await api("GET", `/workspaces/${sandboxWorkspaceId}`, deviceToken);
    expect(res.status).toBe(200);

    const ws = res.json!.workspace as Record<string, unknown>;
    expect(ws.runtime).toBe("sandbox");
    expect(ws.sandboxConfig).toEqual({
      allowedHosts: ["api.anthropic.com", "api.openai.com"],
    });
  });

  it("updates sandbox config (change allowed hosts)", async () => {
    if (!lmsReady()) return;

    const res = await api("PUT", `/workspaces/${sandboxWorkspaceId}`, deviceToken, {
      sandboxConfig: { allowedHosts: ["*"] },
    });

    expect(res.status).toBe(200);
    const ws = res.json!.workspace as Record<string, unknown>;
    expect(ws.sandboxConfig).toEqual({ allowedHosts: ["*"] });
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
  });

  it("creates a host workspace without runtime field", async () => {
    if (!lmsReady()) return;

    const res = await api("POST", "/workspaces", deviceToken, {
      name: "e2e-host-workspace",
      skills: [],
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
      skills: [],
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
