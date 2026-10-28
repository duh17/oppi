import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SdkBackend } from "../src/sdk-backend.js";
import type { Session, Workspace } from "../src/types.js";

const cleanups: Array<() => void> = [];
afterEach(() => {
  for (const cleanup of cleanups.splice(0).reverse()) cleanup();
});

/** A Pi session file with `entries` after its header. */
function piSessionFile(entries: unknown[]): string {
  const dir = mkdtempSync(join(tmpdir(), "oppi-name-session-"));
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  const file = join(dir, "session.jsonl");
  const header = {
    type: "session",
    version: 3,
    id: "11111111-1111-4111-8111-111111111111",
    timestamp: "2026-10-27T00:00:00.000Z",
    cwd: dir,
  };
  writeFileSync(file, [header, ...entries].map((line) => JSON.stringify(line)).join("\n") + "\n");
  return file;
}

/** A classic session in an empty agent dir, so no user extension joins in. */
async function classicSession(overrides: Partial<Session>): Promise<SdkBackend> {
  const cwd = mkdtempSync(join(tmpdir(), "oppi-name-cwd-"));
  const agentDir = mkdtempSync(join(tmpdir(), "oppi-name-agent-"));
  mkdirSync(join(agentDir, "extensions"), { recursive: true });
  writeFileSync(join(agentDir, "auth.json"), "{}");
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = agentDir;
  cleanups.push(() => {
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(agentDir, { recursive: true, force: true });
  });
  const now = Date.now();
  const backend = await SdkBackend.create({
    session: {
      id: "named-1",
      workspaceId: "w1",
      status: "starting",
      createdAt: now,
      lastActivity: now,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
      ...overrides,
    },
    workspace: { id: "w1", name: "Names", runtime: "host", hostMount: cwd } as Workspace,
    onEvent: vi.fn(),
    onEnd: vi.fn(),
  });
  cleanups.push(() => void backend.dispose());
  return backend;
}

describe("a name Oppi holds from creation", () => {
  it("is the Pi session's name, so an extension that names unnamed sessions leaves it alone", async () => {
    const backend = await classicSession({ name: "Chosen at creation" });
    expect(backend.session.sessionName).toBe("Chosen at creation");
  });

  it("leaves a new session without a name unnamed", async () => {
    const backend = await classicSession({});
    expect(backend.session.sessionName).toBeUndefined();
  });

  it("hands the name over when a resumed session has not talked yet", async () => {
    const file = piSessionFile([]);
    const backend = await classicSession({ name: "Chosen at creation", piSessionFile: file });
    expect(backend.session.sessionName).toBe("Chosen at creation");
  });

  it("does not write the name into a session that already has messages", async () => {
    const file = piSessionFile([
      {
        type: "message",
        id: "m1",
        parentId: null,
        timestamp: "2026-10-27T00:00:01.000Z",
        message: { role: "user", content: "fix the bug", timestamp: 1 },
      },
    ]);
    const backend = await classicSession({ name: "Adopted", messageCount: 3, piSessionFile: file });
    expect(backend.session.sessionName).toBeUndefined();
  });
});
