import { afterEach, describe, expect, it, vi } from "vitest";

import {
  api,
  dockerStartupCleanupCommand,
  E2EPairingError,
  enrollE2EDevice,
  listWorkspaceSessions,
  nativeStartupStepsForTarget,
  pairDevice,
  refreshE2EAccessToken,
  resetE2EAuthSessions,
} from "../e2e/harness.js";

function requestPath(url: string | URL): string {
  return new URL(String(url), "http://127.0.0.1").pathname;
}

function requestAuth(init?: RequestInit): string | undefined {
  const headers = init?.headers;
  if (!headers || headers instanceof Headers || Array.isArray(headers)) {
    if (headers instanceof Headers) return headers.get("Authorization") ?? undefined;
    if (Array.isArray(headers)) {
      const match = headers.find(([key]) => key.toLowerCase() === "authorization");
      return match?.[1];
    }
    return undefined;
  }
  const record = headers as Record<string, string>;
  return record.Authorization ?? record.authorization;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("E2E harness helpers", () => {
  afterEach(() => {
    resetE2EAuthSessions();
    vi.unstubAllGlobals();
  });

  it("builds source targets before checking the native server entrypoint", () => {
    expect(nativeStartupStepsForTarget("/repo/server", "/repo/server")).toEqual([
      "build",
      "assertEntrypoint",
    ]);
    expect(nativeStartupStepsForTarget("/repo/package", "/repo/server")).toEqual([
      "assertEntrypoint",
    ]);
  });

  it("clears the Docker E2E data volume before a fresh startup", () => {
    expect(dockerStartupCleanupCommand("/tmp/docker-compose.e2e.yml")).toBe(
      "docker compose -f /tmp/docker-compose.e2e.yml down -v --timeout 60",
    );
  });

  it("fails fast when the requested session-list status array is missing", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify({ sessions: [] }), { status: 200 })),
    );

    await expect(listWorkspaceSessions("device-token", "w1", "active")).rejects.toThrow(
      "missing active session list",
    );
  });

  it("returns the requested session-list status rows", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(JSON.stringify({ active: [{ id: "s1" }] }), {
            status: 200,
          }),
      ),
    );

    await expect(listWorkspaceSessions("device-token", "w1", "active")).resolves.toEqual([
      { id: "s1" },
    ]);
  });

  it("refreshes an expired enrollment before authenticated HTTP and uses the new bearer", async () => {
    const calls: Array<{ path: string; auth?: string; body?: Record<string, unknown> }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL, init?: RequestInit) => {
        const path = requestPath(url);
        const auth = requestAuth(init);
        const body =
          typeof init?.body === "string"
            ? (JSON.parse(init.body) as Record<string, unknown>)
            : undefined;
        calls.push({ path, auth, body });
        expect(String(url)).not.toContain("at_");
        expect(String(url)).not.toContain("BEGIN");
        if (path === "/pair") {
          return jsonResponse({
            accessToken: "at_old",
            deviceId: "dev_1",
            expiresAt: Date.now() - 1_000,
          });
        }
        if (path === "/auth/challenge") {
          return jsonResponse({
            nonce: "nonce-1",
            audience: "oppi:refresh:v1",
            expiresAt: Date.now() + 60_000,
          });
        }
        if (path === "/auth/refresh") {
          expect(typeof body?.signature).toBe("string");
          expect(String(body?.signature).length).toBeGreaterThan(0);
          expect(body?.deviceId).toBe("dev_1");
          expect(body?.nonce).toBe("nonce-1");
          return jsonResponse({
            accessToken: "at_new",
            expiresAt: Date.now() + 600_000,
          });
        }
        if (path === "/me") {
          if (auth === "Bearer at_new") return jsonResponse({ user: "owner" });
          return new Response("expired", { status: 401 });
        }
        return new Response("missing stub", { status: 500 });
      }),
    );

    const token = await pairDevice("pt_test", "e2e-refresh");
    expect(token).toBe("at_old");
    const me = await api("GET", "/me", token);
    expect(me.status).toBe(200);
    expect(me.json).toEqual({ user: "owner" });
    expect(calls.some((call) => call.path === "/auth/challenge")).toBe(true);
    expect(calls.some((call) => call.path === "/auth/refresh")).toBe(true);
    const meCalls = calls.filter((call) => call.path === "/me");
    expect(meCalls.at(-1)?.auth).toBe("Bearer at_new");
  });

  it("coalesces concurrent refresh for one enrolled device", async () => {
    let releaseChallenge: (() => void) | undefined;
    let sawChallenge!: () => void;
    const challengeEntered = new Promise<void>((resolve) => {
      sawChallenge = resolve;
    });
    const challengeHold = new Promise<void>((resolve) => {
      releaseChallenge = resolve;
    });
    let challengeCalls = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL, init?: RequestInit) => {
        const path = requestPath(url);
        const auth = requestAuth(init);
        if (path === "/pair") {
          return jsonResponse({
            accessToken: "at_old",
            deviceId: "dev_1",
            expiresAt: Date.now() - 1_000,
          });
        }
        if (path === "/auth/challenge") {
          challengeCalls += 1;
          sawChallenge();
          await challengeHold;
          return jsonResponse({
            nonce: "nonce-1",
            audience: "oppi:refresh:v1",
            expiresAt: Date.now() + 60_000,
          });
        }
        if (path === "/auth/refresh") {
          return jsonResponse({
            accessToken: "at_new",
            expiresAt: Date.now() + 600_000,
          });
        }
        if (path === "/me" && auth === "Bearer at_new") {
          return jsonResponse({ user: "owner" });
        }
        if (path === "/workspaces" && auth === "Bearer at_new") {
          return jsonResponse({ workspaces: [] });
        }
        return new Response("expired", { status: 401 });
      }),
    );

    const token = await pairDevice("pt_test", "e2e-refresh-coalesce");
    const first = api("GET", "/me", token);
    const second = api("GET", "/workspaces", token);
    await challengeEntered;
    await Promise.resolve();
    await Promise.resolve();
    expect(challengeCalls).toBe(1);
    releaseChallenge?.();
    const [me, workspaces] = await Promise.all([first, second]);
    expect(me.status).toBe(200);
    expect(workspaces.status).toBe(200);
    expect(challengeCalls).toBe(1);
  });

  it("retries one authenticated HTTP 401 after a forced refresh", async () => {
    let meCalls = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL, init?: RequestInit) => {
        const path = requestPath(url);
        const auth = requestAuth(init);
        if (path === "/pair") {
          return jsonResponse({
            accessToken: "at_live",
            deviceId: "dev_1",
            expiresAt: Date.now() + 600_000,
          });
        }
        if (path === "/auth/challenge") {
          return jsonResponse({
            nonce: "nonce-2",
            audience: "oppi:refresh:v1",
            expiresAt: Date.now() + 60_000,
          });
        }
        if (path === "/auth/refresh") {
          return jsonResponse({
            accessToken: "at_rotated",
            expiresAt: Date.now() + 600_000,
          });
        }
        if (path === "/me") {
          meCalls += 1;
          if (auth === "Bearer at_rotated") return jsonResponse({ user: "owner" });
          return new Response("unknown_token", { status: 401 });
        }
        return new Response("missing stub", { status: 500 });
      }),
    );

    const token = await pairDevice("pt_test", "e2e-refresh-401");
    const me = await api("GET", "/me", token);
    expect(me.status).toBe(200);
    expect(meCalls).toBe(2);
    expect(await refreshE2EAccessToken(token)).toBe("at_rotated");
  });

  it("does not treat a successful /pair mutation as retryable", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL) => {
        if (requestPath(url) === "/pair") {
          return jsonResponse({ ok: true });
        }
        return new Response("missing stub", { status: 500 });
      }),
    );

    const error = await enrollE2EDevice("pt_test", "e2e-pair-malformed").catch(
      (caught: unknown) => caught,
    );
    expect(error).toBeInstanceOf(E2EPairingError);
    expect((error as E2EPairingError).retryable).toBe(false);
  });

  it("treats a failed /pair status as retryable", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string | URL) => {
        if (requestPath(url) === "/pair") {
          return new Response(JSON.stringify({ error: "Invalid or expired pairing token" }), {
            status: 401,
          });
        }
        return new Response("missing stub", { status: 500 });
      }),
    );

    const error = await enrollE2EDevice("pt_test", "e2e-pair-401").catch(
      (caught: unknown) => caught,
    );
    expect(error).toBeInstanceOf(E2EPairingError);
    expect((error as E2EPairingError).retryable).toBe(true);
  });
});
