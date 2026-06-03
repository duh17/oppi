import { afterEach, describe, expect, it, vi } from "vitest";

import {
  dockerStartupCleanupCommand,
  listWorkspaceSessions,
  nativeStartupStepsForTarget,
} from "../e2e/harness.js";

describe("E2E harness helpers", () => {
  afterEach(() => {
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
      "docker compose -f /tmp/docker-compose.e2e.yml down -v --timeout 10",
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
});
