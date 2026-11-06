import { randomUUID } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import { deleteClassicControlSessions } from "../src/classic-control-sessions.js";
import { newControlSessionRow } from "../src/control-session.js";
import { getPiSessionsRoot } from "../src/local-sessions.js";
import {
  SessionLifecycleService,
  type SessionLifecycleServiceDeps,
} from "../src/session-lifecycle-service.js";
import { openDatabase } from "../src/sqlite-compat.js";
import { Storage } from "../src/storage.js";
import type { Session } from "../src/types.js";
import { makeTempDir } from "./harness/temp-dir.js";

const CONTROL_JSON = '{"domain":"agents","intent":"revise","targetName":"Sensei"}';

/** The real session delete, with no runtime attached: what a server start runs. */
function lifecycleFor(storage: Storage): SessionLifecycleService {
  return new SessionLifecycleService({
    storage,
    sessions: {},
    sessionRuntimes: { stopSessionIfActive: async () => {} },
    ensureSessionContextWindow: (session: Session) => session,
  } as unknown as SessionLifecycleServiceDeps);
}

/** A Pi trace file under the local Pi sessions root, as a classic control session left one. */
function writeTrace(sessionId: string, body: string): string {
  const dir = join(getPiSessionsRoot(), `--classic-control-${randomUUID()}--`);
  mkdirSync(dir, { recursive: true });
  const path = join(dir, `2026-10-24T10-00-00-000Z_${sessionId}.jsonl`);
  writeFileSync(
    path,
    `${JSON.stringify({ type: "session", id: sessionId, cwd: "/tmp/control-sessions/cwd" })}\n${body}\n`,
  );
  return path;
}

function writeAttachment(dataDir: string, sessionId: string): string {
  const dir = join(dataDir, "session-attachments", sessionId);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "photo.png"), "png bytes");
  return dir;
}

function markClassic(dataDir: string, ids: string[]): void {
  const db = openDatabase(join(dataDir, "session-state.db"));
  try {
    const mark = db.prepare("UPDATE session_state_sessions SET control_json = ? WHERE id = ?");
    for (const id of ids) mark.run(CONTROL_JSON, id);
  } finally {
    db.close();
  }
}

/** Stored Pi Control rows as servers wrote them before Oppi Control ran on the durable engine. */
function seed(storage: Storage, dataDir: string) {
  const withFiles = storage.createSession("Revise Sensei");
  const trace = writeTrace(withFiles.id, '{"type":"message","text":"keep me"}');
  storage.saveSession({ ...withFiles, piSessionFile: trace, piSessionFiles: [trace] });
  const attachments = writeAttachment(dataDir, withFiles.id);
  const bare = storage.createSession("Create Theme");

  const workspace = storage.createWorkspace({ name: "Project", hostMount: dataDir });
  const plain = storage.createSession("Workspace-less, never control");
  const inWorkspace = storage.createSession("In a workspace");
  storage.saveSession({ ...inWorkspace, workspaceId: workspace.id });
  const now = Date.now();
  const durable = newControlSessionRow({
    now,
    name: "Oppi Control",
    status: "stopped",
    launch: { status: "accepted", requestedAt: now },
  });
  storage.saveSession(durable);

  // Pi Control metadata on a workspace row never made it a control session.
  markClassic(dataDir, [withFiles.id, bare.id, inWorkspace.id]);
  return { withFiles, trace, attachments, bare, kept: [plain, inWorkspace, durable] };
}

function backupFolders(dataDir: string): string[] {
  const dir = join(dataDir, "backups");
  return existsSync(dir) ? readdirSync(dir).map((name) => join(dir, name)) : [];
}

describe("deleteClassicControlSessions", () => {
  it("backs up each classic row's files before removing the rows, once", async () => {
    const dataDir = makeTempDir("oppi-classic-control-");
    const storage = new Storage(dataDir);
    const lifecycle = lifecycleFor(storage);
    const { withFiles, trace, attachments, bare, kept } = seed(storage, dataDir);
    const traceBytes = readFileSync(trace, "utf8");

    await deleteClassicControlSessions(storage, lifecycle);

    expect(storage.getSession(withFiles.id)).toBeUndefined();
    expect(storage.getSession(bare.id)).toBeUndefined();
    for (const session of kept) expect(storage.getSession(session.id)).toBeDefined();
    expect(existsSync(trace)).toBe(false);
    expect(existsSync(attachments)).toBe(false);

    const [folder, ...others] = backupFolders(dataDir);
    expect(others).toEqual([]);
    expect(folder).toMatch(/pi-control-sessions-pre-[a-z_0-9]+-\d+-[0-9a-f]{8}$/);
    const saved = join(folder!, withFiles.id);
    expect(readFileSync(join(saved, "traces", trace.split("/").at(-1)!), "utf8")).toBe(traceBytes);
    expect(readFileSync(join(saved, "attachments", "photo.png"), "utf8")).toBe("png bytes");
    const row = JSON.parse(readFileSync(join(saved, "session.json"), "utf8"));
    expect(row).toMatchObject({
      id: withFiles.id,
      name: "Revise Sensei",
      control: { domain: "agents", targetName: "Sensei" },
    });
    expect(JSON.parse(readFileSync(join(folder!, bare.id, "session.json"), "utf8")).name).toBe(
      "Create Theme",
    );

    // Recorded in the ledger: a later start leaves even a newly marked row alone.
    const late = storage.createSession("Marked after the migration");
    markClassic(dataDir, [late.id]);
    await deleteClassicControlSessions(storage, lifecycle);
    expect(storage.getSession(late.id)).toBeDefined();
    expect(backupFolders(dataDir)).toEqual([folder]);
  });

  it("keeps a row whose backup fails, with its files, and retries it at the next start", async () => {
    const dataDir = makeTempDir("oppi-classic-control-");
    const storage = new Storage(dataDir);
    const lifecycle = lifecycleFor(storage);
    const { withFiles, trace, attachments, bare } = seed(storage, dataDir);

    // The trace copies, then the attachments cannot be read: the half-made backup must go.
    chmodSync(attachments, 0o000);
    try {
      await deleteClassicControlSessions(storage, lifecycle);
    } finally {
      chmodSync(attachments, 0o700);
    }

    expect(storage.getSession(withFiles.id)).toBeDefined();
    expect(existsSync(trace)).toBe(true);
    expect(existsSync(join(attachments, "photo.png"))).toBe(true);
    expect(storage.getSession(bare.id)).toBeUndefined();
    const [first] = backupFolders(dataDir);
    expect(readdirSync(first!)).toEqual([bare.id]);

    await deleteClassicControlSessions(storage, lifecycle);

    expect(storage.getSession(withFiles.id)).toBeUndefined();
    expect(existsSync(trace)).toBe(false);
    const second = backupFolders(dataDir).find((folder) => folder !== first);
    expect(readdirSync(second!)).toEqual([withFiles.id]);
    expect(readdirSync(join(second!, withFiles.id, "traces"))).toHaveLength(1);
    expect(readdirSync(first!)).toEqual([bare.id]);
  });
});
