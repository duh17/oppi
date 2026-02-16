import { EventEmitter } from "node:events";
import type { ChildProcess } from "node:child_process";
import { PassThrough } from "node:stream";
import { PolicyEngine } from "../src/policy.js";
import type { SpawnDeps } from "../src/session-spawn.js";
import type { Session, Workspace } from "../src/types.js";
import { expect, vi } from "vitest";

export function makeSession(): Session {
  const now = Date.now();
  return {
    id: "s1",
    status: "starting",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
  };
}

export function makeWorkspace(overrides?: Partial<Workspace>): Workspace {
  const now = Date.now();
  return {
    id: "w1",
    name: "pios",
    runtime: "host",
    skills: [],
    policyPreset: "host",
    hostMount: "~/workspace/oppi",
    createdAt: now,
    updatedAt: now,
    ...overrides,
  };
}

export class StubProcess extends EventEmitter {
  stdout = new PassThrough();
  stderr = new PassThrough();
  stdin = { write: vi.fn(), writable: true, on: vi.fn() };
  killed = false;
}

export function makeDeps(overrides?: Partial<SpawnDeps>): SpawnDeps {
  return {
    gate: {} as SpawnDeps["gate"],
    sandbox: {} as SpawnDeps["sandbox"],
    authProxy: null,
    piExecutable: "pi",
    onRpcLine: vi.fn(),
    onSessionEnd: vi.fn(),
    ...overrides,
  };
}

export function getSpawnPolicy(
  setSessionPolicy: ReturnType<typeof vi.fn>,
  sessionId: string,
  expectedPreset: "host" | "container",
): PolicyEngine {
  expect(setSessionPolicy).toHaveBeenCalledWith(sessionId, expect.any(PolicyEngine));
  const call = setSessionPolicy.mock.calls.at(-1);
  if (!call) throw new Error("setSessionPolicy was not called");
  const [, policy] = call as [string, PolicyEngine];
  expect(policy.getPresetName()).toBe(expectedPreset);
  return policy;
}

export async function awaitProcessReady(
  startPromise: Promise<ChildProcess>,
  proc: StubProcess,
): Promise<void> {
  setImmediate(() => {
    proc.stdout.write('{"type":"agent_start"}\n');
  });
  await startPromise;
  proc.killed = true;
}
