import { describe, expect, it, vi } from "vitest";

import { SessionCommandCoordinator, type CommandSessionState } from "./session-commands.js";
import type { Session } from "./types.js";

function makeSession(): Session {
  const now = Date.now();
  return {
    id: "s1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
  };
}

function makeCoordinator(
  active: CommandSessionState,
  reloadRuntimeConfig = vi.fn(),
): { coordinator: SessionCommandCoordinator; reloadRuntimeConfig: ReturnType<typeof vi.fn> } {
  return {
    coordinator: new SessionCommandCoordinator({
      getActiveSession: vi.fn(() => active),
      persistSessionNow: vi.fn(),
      broadcast: vi.fn(),
      applyPiStateSnapshot: vi.fn(() => false),
      getContextWindowResolver: vi.fn(() => null),
      reloadRuntimeConfig,
    }),
    reloadRuntimeConfig,
  };
}

describe("SessionCommandCoordinator reload", () => {
  it("allows reload and refreshes runtime config before SDK resources", async () => {
    const calls: string[] = [];
    const active = {
      session: makeSession(),
      sdkBackend: {
        reloadResources: vi.fn(async () => {
          calls.push("resources");
          return { success: true as const };
        }),
      },
    } as unknown as CommandSessionState;
    const reloadRuntimeConfig = vi.fn(() => calls.push("config"));
    const { coordinator } = makeCoordinator(active, reloadRuntimeConfig);

    expect(coordinator.isAllowedCommand("reload")).toBe(true);

    const result = await coordinator.sendCommandAsync("s1", { type: "reload" });

    expect(result).toEqual({ success: true });
    expect(reloadRuntimeConfig).toHaveBeenCalledOnce();
    expect(active.sdkBackend.reloadResources).toHaveBeenCalledOnce();
    expect(calls).toEqual(["config", "resources"]);
  });
});
