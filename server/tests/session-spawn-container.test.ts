import type { ChildProcess } from "node:child_process";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { spawnPiContainer, type SpawnDeps } from "../src/session-spawn.js";
import {
  awaitProcessReady,
  getSpawnPolicy,
  makeDeps,
  makeSession,
  makeWorkspace,
  StubProcess,
} from "./session-spawn.helpers.js";

describe("session-spawn spawnPiContainer", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("wires sandbox, gate, and auth-proxy with expected spawn payload", async () => {
    const session = makeSession();
    session.model = "openai-codex/gpt-5.3-codex";
    const workspace = makeWorkspace({ runtime: "container" });

    const proc = new StubProcess();
    const createSessionSocket = vi.fn(async () => 51111);
    const setSessionPolicy = vi.fn();
    const spawnPi = vi.fn(() => proc as unknown as ChildProcess);
    const registerSession = vi.fn();

    const deps = makeDeps({
      gate: { createSessionSocket, setSessionPolicy } as unknown as SpawnDeps["gate"],
      sandbox: { spawnPi } as unknown as SpawnDeps["sandbox"],
      authProxy: { registerSession } as unknown as NonNullable<SpawnDeps["authProxy"]>,
    });

    await awaitProcessReady(spawnPiContainer(session, "w-container", "Bob", workspace, deps), proc);

    expect(registerSession).toHaveBeenCalledWith("s1");
    expect(createSessionSocket).toHaveBeenCalledWith("s1", "w-container");

    const containerPolicy = getSpawnPolicy(setSessionPolicy, "s1", "container");
    const containerDecision = containerPolicy.evaluate({
      tool: "bash",
      input: { command: "ls -la" },
      toolCallId: "tc-container",
    });
    expect(containerDecision.action).toBe("allow");

    expect(spawnPi).toHaveBeenCalledWith(
      expect.objectContaining({
        sessionId: "s1",
        workspaceId: "w-container",
        userName: "Bob",
        model: "openai-codex/gpt-5.3-codex",
        workspace,
        gatePort: 51111,
      }),
    );
  });

  it("works without authProxy and allows undefined workspace/userName", async () => {
    const session = makeSession();
    const proc = new StubProcess();

    const createSessionSocket = vi.fn(async () => 52222);
    const setSessionPolicy = vi.fn();
    const spawnPi = vi.fn(() => proc as unknown as ChildProcess);

    const deps = makeDeps({
      gate: { createSessionSocket, setSessionPolicy } as unknown as SpawnDeps["gate"],
      sandbox: { spawnPi } as unknown as SpawnDeps["sandbox"],
      authProxy: null,
    });

    await awaitProcessReady(spawnPiContainer(session, "w-no-auth", undefined, undefined, deps), proc);

    expect(createSessionSocket).toHaveBeenCalledWith("s1", "w-no-auth");

    const containerPolicy = getSpawnPolicy(setSessionPolicy, "s1", "container");
    const denyDecision = containerPolicy.evaluate({
      tool: "bash",
      input: { command: "sudo ls" },
      toolCallId: "tc-deny",
    });
    expect(denyDecision.action).toBe("deny");

    expect(spawnPi).toHaveBeenCalledWith(
      expect.objectContaining({
        sessionId: "s1",
        workspaceId: "w-no-auth",
        userName: undefined,
        model: undefined,
        workspace: undefined,
        gatePort: 52222,
      }),
    );
  });
});
