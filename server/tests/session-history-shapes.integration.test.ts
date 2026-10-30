import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { join } from "node:path";
import { gunzipSync } from "node:zlib";

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { UserEntry } from "@earendil-works/pi-durable";

import type { DurableHarness } from "../src/durable-harness.js";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import type { Session } from "../src/types.js";
import { makeTempDir } from "./harness/temp-dir.js";

/**
 * Every client gets the current shapes: a real server on its owner socket, queried with no
 * capability header, both without a user agent and with an Apple URLSession one. Builds 55 and
 * older, which needed inline images and four control domains, are not supported.
 */

const IMAGE_BASE64 = Buffer.from("not-really-a-png-but-valid-base64-bytes").toString("base64");

const timestamp = "2026-01-01T00:00:00.000Z";
const traceLines = [
  {
    type: "message",
    id: "u1",
    parentId: null,
    timestamp,
    message: {
      role: "user",
      content: [
        { type: "text", text: "look at this" },
        { type: "image", data: IMAGE_BASE64, mimeType: "image/png" },
      ],
    },
  },
  {
    type: "message",
    id: "a1",
    parentId: "u1",
    timestamp,
    message: { role: "assistant", content: [{ type: "text", text: "seen" }] },
  },
]
  .map((line) => JSON.stringify(line))
  .join("\n");

interface TraceEventBody {
  type: string;
  text?: string;
  media?: Array<Record<string, unknown>>;
}
interface SessionBody {
  control?: { domain: string; intent: string };
}

interface Fixture {
  workspaceId: string;
  workspaceSessionId: string;
  controlSessionId: string;
  /** A durable session, not yet bound to a conversation; `bindDurableConversation` binds it. */
  durableSession: Session;
}

const clients = [
  { name: "no user agent", headers: {} as Record<string, string> },
  {
    name: "Apple URLSession user agent",
    headers: { "User-Agent": "Oppi/57 CFNetwork/1568.300.101 Darwin/24.4.0" },
  },
];

describe.each(clients)("session history shapes for a client with $name", ({ headers }) => {
  let dataDir = "";
  let server: Server;
  let storage: Storage;
  let token: string;
  let fixture: Fixture;
  let previousAgentDir: string | undefined;

  beforeEach(async () => {
    dataDir = makeTempDir("oppi-history-shapes-");
    // The durable harness loads extensions from the Pi agent directory.
    previousAgentDir = process.env.PI_CODING_AGENT_DIR;
    process.env.PI_CODING_AGENT_DIR = join(dataDir, "agent");
    storage = new Storage(dataDir);
    token = storage.ensurePaired();
    storage.mutateConfig(() => ({
      host: "127.0.0.1",
      port: 0,
      tls: { mode: "tailscale" },
      experimental: { serverDurable: true },
    }));
    fixture = seed(storage, dataDir);
    const originalPath = process.env.PATH;
    process.env.PATH = dataDir;
    server = new Server(storage);
    try {
      await server.start();
    } finally {
      process.env.PATH = originalPath;
    }
  }, 30_000);

  afterEach(async () => {
    await server.stop().catch(() => {});
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
    rmSync(dataDir, { recursive: true, force: true });
  });

  /**
   * Gives the durable session a real conversation in the server's own Harness whose first
   * message is a user photo, so the durable history routes have something to project.
   */
  async function bindDurableConversation(): Promise<void> {
    const sessions = (
      server as unknown as { sessions: { durableHarness: Promise<DurableHarness> } }
    ).sessions;
    const durable = await sessions.durableHarness;
    const { durableSession } = fixture;
    const { harness } = await (await durable.openHost(durableSession.id, { cwd: dataDir })).open();
    const conversation = await harness.createConversation(
      {
        ownership: { kind: "ownerless" },
        agent: { model: { provider: "faux", modelId: "faux-1" }, cwd: dataDir },
      },
      context,
    );
    await conversation.commit(
      async (tx) =>
        tx.appendEntry(UserEntry, conversation.id, {
          model: [
            {
              role: "user",
              content: [
                { type: "text", text: "look at this" },
                { type: "image", data: IMAGE_BASE64, mimeType: "image/png" },
              ],
              timestamp: 1,
            },
          ],
        }),
      context,
    );
    storage.saveSession({
      ...durableSession,
      serverDurable: { storeId: durableSession.id, conversationId: conversation.id },
    });
  }

  async function get<T>(path: string): Promise<T> {
    const response = await new Promise<{ status: number; body: string }>((resolve, reject) => {
      const req = httpRequest(
        {
          socketPath: server.socketPath,
          path,
          headers: { Authorization: `Bearer ${token}`, "Accept-Encoding": "gzip", ...headers },
        },
        (res) => {
          const chunks: Buffer[] = [];
          res.on("data", (chunk: Buffer) => chunks.push(chunk));
          res.on("end", () => {
            const raw = Buffer.concat(chunks);
            const body = res.headers["content-encoding"] === "gzip" ? gunzipSync(raw) : raw;
            resolve({ status: res.statusCode ?? 0, body: body.toString("utf8") });
          });
        },
      );
      req.on("error", reject);
      req.end();
    });
    expect(response.status, `${path}: ${response.body.slice(0, 200)}`).toBe(200);
    return JSON.parse(response.body) as T;
  }

  /**
   * The attachment records the session's manifest holds, read at the store's own path.
   * The data directory must not be walked recursively: beside `session-attachments` the durable
   * store creates and removes its directory lock (`durable/sessions/<storeId>.lock`) whenever a
   * request opens the store or the idle close releases it, and `readdirSync(…, { recursive: true })`
   * throws ENOENT when that directory goes away between listing it and opening it.
   *
   * `storeUserMessageImages` writes this manifest before the history response is built, so the
   * records are on disk by the time a route's trace assertions above have run.
   */
  function storedAttachments(sessionId: string): Array<Record<string, unknown>> {
    const path = join(dataDir, "session-attachments", sessionId, "manifest.json");
    if (!existsSync(path)) return [];
    const manifest = JSON.parse(readFileSync(path, "utf8")) as {
      attachments?: Array<Record<string, unknown>>;
    };
    return manifest.attachments ?? [];
  }

  function expectStoredImageRef(trace: TraceEventBody[], label: string): void {
    const event = trace.find((candidate) => candidate.type === "user");
    if (!event) throw new Error(`${label}: no user event in trace`);
    expect(event.text, label).toBe("look at this");
    expect(event.text, label).not.toContain("data:image");
    expect(event.media, label).toHaveLength(1);
    expect(event.media?.[0], label).toMatchObject({ kind: "image", mimeType: "image/png" });
  }

  it("returns user images as stored media refs on every classic history route", async () => {
    const { workspaceId, workspaceSessionId, controlSessionId } = fixture;
    const routes = [
      `/workspaces/${workspaceId}/sessions/${workspaceSessionId}/trace-page`,
      `/workspaces/${workspaceId}/sessions/${workspaceSessionId}`,
      `/control-sessions/${controlSessionId}/trace-page`,
      `/control-sessions/${controlSessionId}`,
    ];
    for (const path of routes) {
      expectStoredImageRef((await get<{ trace: TraceEventBody[] }>(path)).trace, path);
    }
    for (const sessionId of [workspaceSessionId, controlSessionId]) {
      expect(storedAttachments(sessionId), sessionId).toMatchObject([
        { kind: "image", mimeType: "image/png" },
      ]);
    }
  });

  it("returns a durable session's user images as stored media refs", async () => {
    await bindDurableConversation();
    const { workspaceId, durableSession } = fixture;
    for (const path of [
      `/workspaces/${workspaceId}/sessions/${durableSession.id}/trace-page`,
      `/workspaces/${workspaceId}/sessions/${durableSession.id}`,
    ]) {
      expectStoredImageRef((await get<{ trace: TraceEventBody[] }>(path)).trace, path);
    }
    expect(storedAttachments(durableSession.id)).toMatchObject([
      { kind: "image", mimeType: "image/png" },
    ]);
  }, 30_000);

  it("keeps a control session's domain unchanged in the session list", async () => {
    const listed = await get<{ sessions: SessionBody[] }>("/sessions/recent");
    const domains = listed.sessions.flatMap((session) =>
      session.control ? [session.control.domain] : [],
    );
    expect(domains).toEqual(["extensions"]);
  });
});

/**
 * A workspace session whose JSONL sits in the canonical trace directory, and an `extensions`
 * control session (no workspace) whose JSONL is its Pi session file. Both open on a user
 * message with one image.
 */
function seed(storage: Storage, dataDir: string): Fixture {
  const workspace = storage.createWorkspace({ name: "history-shapes", hostMount: dataDir });
  const workspaceSession: Session = {
    ...storage.createSession("Photo chat"),
    workspaceId: workspace.id,
    workspaceName: workspace.name,
    status: "stopped",
  };
  storage.saveSession(workspaceSession);
  const traceDir = join(
    dataDir,
    workspace.id,
    "sessions",
    workspaceSession.id,
    "agent",
    "sessions",
    "--work--",
  );
  mkdirSync(traceDir, { recursive: true });
  writeFileSync(join(traceDir, "20260101T000000Z-photo.jsonl"), traceLines);

  const controlFile = join(dataDir, "control-session.jsonl");
  const header = JSON.stringify({
    type: "session",
    version: 3,
    id: "control-pi-session",
    timestamp,
    cwd: dataDir,
  });
  writeFileSync(controlFile, `${header}\n${traceLines}\n`);
  const controlSession: Session = {
    ...storage.createSession("Edit with Oppi"),
    status: "stopped",
    control: { domain: "extensions", intent: "revise", targetId: "ext-1" },
    piSessionFile: controlFile,
  };
  storage.saveSession(controlSession);

  const durableSession: Session = {
    ...storage.createSession("Durable photo chat", "faux/faux-1"),
    workspaceId: workspace.id,
    workspaceName: workspace.name,
    status: "stopped",
  };
  durableSession.serverDurable = { storeId: durableSession.id };
  storage.saveSession(durableSession);
  return {
    workspaceId: workspace.id,
    workspaceSessionId: workspaceSession.id,
    controlSessionId: controlSession.id,
    durableSession,
  };
}
