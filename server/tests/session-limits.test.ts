import { describe, expect, it } from "vitest";
import { WorkspaceRuntime } from "../src/workspace-runtime.js";

describe("WorkspaceRuntime session limits", () => {
  it("enforces per-workspace limits across starting + active sessions", () => {
    const runtime = new WorkspaceRuntime({
      maxSessionsPerWorkspace: 2,
      maxSessionsGlobal: 10,
      sessionIdleTimeoutMs: 10 * 60_000,
      workspaceIdleTimeoutMs: 30 * 60_000,
    });

    runtime.reserveSessionStart({ workspaceId: "w1", sessionId: "s1" });
    runtime.reserveSessionStart({ workspaceId: "w1", sessionId: "s2" });

    expect(() => {
      runtime.reserveSessionStart({ workspaceId: "w1", sessionId: "s3" });
    }).toThrow("Workspace session limit reached (2)");

    runtime.markSessionReady({ workspaceId: "w1", sessionId: "s1" });
    runtime.releaseSession({ workspaceId: "w1", sessionId: "s2" });

    runtime.reserveSessionStart({ workspaceId: "w1", sessionId: "s3" });
    expect(runtime.getWorkspaceSessionCount("w1")).toBe(2);
  });

  it("enforces global limits across workspaces", () => {
    const runtime = new WorkspaceRuntime({
      maxSessionsPerWorkspace: 5,
      maxSessionsGlobal: 2,
      sessionIdleTimeoutMs: 10 * 60_000,
      workspaceIdleTimeoutMs: 30 * 60_000,
    });

    runtime.reserveSessionStart({ workspaceId: "w1", sessionId: "s1" });
    runtime.reserveSessionStart({ workspaceId: "w2", sessionId: "s2" });

    expect(() => {
      runtime.reserveSessionStart({ workspaceId: "w3", sessionId: "s3" });
    }).toThrow("Global session limit reached (2)");

    runtime.releaseSession({ workspaceId: "w1", sessionId: "s1" });
    runtime.reserveSessionStart({ workspaceId: "w3", sessionId: "s3" });

    expect(runtime.getGlobalSessionCount()).toBe(2);
  });
});
