import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { createConnection } from "node:net";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { gunzipSync } from "node:zlib";

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { WebSocket, type RawData } from "ws";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { UserEntry } from "@earendil-works/pi-durable";

import type { DurableHarness } from "../src/durable-harness.js";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import { buildSessionSummary } from "../src/session-summary.js";
import type { SessionBroadcastEvent } from "../src/session-broadcast.js";
import type { ServerMessage, Session } from "../src/types.js";

/**
 * Builds 53 to 55 against a newer server (`src/legacy-app-compat.ts`): a real server on its
 * owner socket, with an Apple URLSession user agent and with or without the capability header.
 */

const IMAGE_BASE64 = Buffer.from("not-really-a-png-but-valid-base64-bytes").toString("base64");
const IMAGE_DATA_URI = `data:image/png;base64,${IMAGE_BASE64}`;

const URLSESSION_USER_AGENT = "Oppi/55 CFNetwork/1568.300.101 Darwin/24.4.0";
const NODE_USER_AGENT = "node";
const CURRENT_APP_CAPABILITIES = "user-image-refs, control-domains";

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
  id: string;
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
  controlSession: Session;
  /** A durable session, not yet bound to a conversation; `bindDurableConversation` binds it. */
  durableSession: Session;
}

describe("old app compatibility with a newer server", () => {
  let dataDir = "";
  let server: Server;
  let storage: Storage;
  let token: string;
  let fixture: Fixture;
  let previousAgentDir: string | undefined;

  beforeEach(async () => {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-legacy-compat-"));
    // The durable harness loads extensions from the Pi agent directory.
    previousAgentDir = process.env.PI_CODING_AGENT_DIR;
    process.env.PI_CODING_AGENT_DIR = join(dataDir, "agent");
    storage = new Storage(dataDir);
    token = storage.ensurePaired();
    storage.updateConfig({
      host: "127.0.0.1",
      port: 0,
      tls: { mode: "tailscale" },
      experimental: { serverDurable: true },
    });
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

  async function get<T>(path: string, headers: Record<string, string>): Promise<T> {
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

  function attachmentManifests(): string[] {
    return readdirSync(dataDir, { recursive: true, encoding: "utf8" }).filter(
      (path) => basename(path) === "manifest.json",
    );
  }

  const legacyApp = { "User-Agent": URLSESSION_USER_AGENT };
  const currentApp = {
    "User-Agent": URLSESSION_USER_AGENT,
    "X-Oppi-Capabilities": CURRENT_APP_CAPABILITIES,
  };
  const nodeClient = { "User-Agent": NODE_USER_AGENT };

  function userEvent(trace: TraceEventBody[]): TraceEventBody {
    const event = trace.find((candidate) => candidate.type === "user");
    if (!event) throw new Error("no user event in trace");
    return event;
  }

  /** Every history route an app uses, in both route families. */
  function historyRoutes(): Array<{ name: string; path: string }> {
    const { workspaceId, workspaceSessionId, controlSessionId } = fixture;
    return [
      {
        name: "workspace trace page",
        path: `/workspaces/${workspaceId}/sessions/${workspaceSessionId}/trace-page`,
      },
      {
        name: "workspace session",
        path: `/workspaces/${workspaceId}/sessions/${workspaceSessionId}`,
      },
      { name: "control trace page", path: `/control-sessions/${controlSessionId}/trace-page` },
      { name: "control session", path: `/control-sessions/${controlSessionId}` },
    ];
  }

  it("sends an app without stored-image support its photos inline, and stores nothing for them", async () => {
    for (const route of historyRoutes()) {
      const body = await get<{ trace: TraceEventBody[] }>(route.path, legacyApp);
      const event = userEvent(body.trace);
      expect(event.text, route.name).toBe(`look at this\n${IMAGE_DATA_URI}`);
      expect(event.media, route.name).toBeUndefined();
    }
    // Nothing was written to the attachment store for the legacy reads...
    expect(attachmentManifests()).toEqual([]);
    // ...while a current app's read of the same history does store the image.
    await get(historyRoutes()[0]!.path, currentApp);
    expect(attachmentManifests()).not.toEqual([]);
  });

  it("sends a current app stored-image refs without the data URI", async () => {
    for (const route of historyRoutes()) {
      const body = await get<{ trace: TraceEventBody[] }>(route.path, currentApp);
      const event = userEvent(body.trace);
      expect(event.text, route.name).toBe("look at this");
      expect(event.media, route.name).toHaveLength(1);
      expect(event.media?.[0], route.name).toMatchObject({ kind: "image", mimeType: "image/png" });
    }
  });

  it("keeps the current shape for non-URLSession clients such as the CLI", async () => {
    for (const route of historyRoutes()) {
      const body = await get<{ trace: TraceEventBody[]; session: SessionBody }>(
        route.path,
        nodeClient,
      );
      const event = userEvent(body.trace);
      expect(event.text, route.name).toBe("look at this");
      expect(event.media, route.name).toHaveLength(1);
    }
    const listed = await get<{ sessions: SessionBody[] }>("/sessions/recent", nodeClient);
    expect(controlDomains(listed.sessions)).toEqual(["extensions"]);
  });

  it("reads each capability token on its own", async () => {
    const path = historyRoutes()[0]!.path;
    const onlyDomains = await get<{ trace: TraceEventBody[] }>(path, {
      ...legacyApp,
      "X-Oppi-Capabilities": " Control-Domains ",
    });
    expect(userEvent(onlyDomains.trace).text).toContain(IMAGE_DATA_URI);

    const onlyRefs = await get<{ trace: TraceEventBody[] }>(path, {
      ...legacyApp,
      "X-Oppi-Capabilities": "USER-IMAGE-REFS",
    });
    expect(userEvent(onlyRefs.trace).media).toHaveLength(1);
    const listed = await get<{ sessions: SessionBody[] }>("/sessions/recent", {
      ...legacyApp,
      "X-Oppi-Capabilities": "user-image-refs",
    });
    expect(controlDomains(listed.sessions)).toEqual(["agents"]);
  });

  it("shows an app that decodes only four control domains an ordinary control session", async () => {
    const legacyList = await get<{ sessions: SessionBody[] }>("/sessions/recent", legacyApp);
    expect(controlDomains(legacyList.sessions)).toEqual(["agents"]);

    const legacyControl = await get<{ session: SessionBody }>(
      `/control-sessions/${fixture.controlSessionId}`,
      legacyApp,
    );
    expect(legacyControl.session.control).toMatchObject({ domain: "agents", intent: "revise" });

    const currentList = await get<{ sessions: SessionBody[] }>("/sessions/recent", currentApp);
    expect(controlDomains(currentList.sessions)).toEqual(["extensions"]);
  });

  it("rewrites control domains in WebSocket frames for a legacy socket only", async () => {
    const summary = buildSessionSummary(fixture.controlSession);
    const legacySocket = connect("/app/events/stream", legacyApp);
    const currentSocket = connect("/app/events/stream", currentApp);
    try {
      const legacyFrames = collectFrames(legacySocket);
      const currentFrames = collectFrames(currentSocket);
      await Promise.all([opened(legacySocket), opened(currentSocket)]);
      await Promise.all([
        waitForFrame(legacyFrames, (frame) => frame["type"] === "app_events_connected"),
        waitForFrame(currentFrames, (frame) => frame["type"] === "app_events_connected"),
      ]);

      const events = (server as unknown as { sessions: SessionEventSource }).sessions;
      events.emit("session_event", {
        sessionId: fixture.controlSessionId,
        event: { type: "session_summary", summary } as ServerMessage,
      });

      const isSummary = (frame: Frame): boolean => frame["type"] === "session_summary";
      const legacy = await waitForFrame(legacyFrames, isSummary);
      const current = await waitForFrame(currentFrames, isSummary);
      expect(summaryControl(legacy)).toMatchObject({ domain: "agents", intent: "revise" });
      expect(summaryControl(current)).toMatchObject({ domain: "extensions", intent: "revise" });
    } finally {
      legacySocket.terminate();
      currentSocket.terminate();
    }
  }, 30_000);

  it("keeps a durable chat's photos inline for an app without stored-image support", async () => {
    await bindDurableConversation();
    const { workspaceId, durableSession } = fixture;
    const routes = [
      `/workspaces/${workspaceId}/sessions/${durableSession.id}/trace-page`,
      `/workspaces/${workspaceId}/sessions/${durableSession.id}`,
    ];

    for (const path of routes) {
      const body = await get<{ trace: TraceEventBody[] }>(path, legacyApp);
      const event = userEvent(body.trace);
      expect(event.text, path).toBe(`look at this\n${IMAGE_DATA_URI}`);
      expect(event.media, path).toBeUndefined();
    }
    expect(attachmentManifests()).toEqual([]);

    for (const path of routes) {
      const body = await get<{ trace: TraceEventBody[] }>(path, currentApp);
      const event = userEvent(body.trace);
      expect(event.text, path).toBe("look at this");
      expect(event.media, path).toHaveLength(1);
    }
    expect(attachmentManifests()).not.toEqual([]);
  }, 30_000);

  it("rewrites control domains in focused-stream frames for a legacy socket only", async () => {
    const path = `/control-sessions/${fixture.controlSessionId}/stream`;
    const legacySocket = connect(path, legacyApp);
    const currentSocket = connect(path, currentApp);
    try {
      const legacyFrames = collectFrames(legacySocket);
      const currentFrames = collectFrames(currentSocket);
      await Promise.all([opened(legacySocket), opened(currentSocket)]);

      const carriesControl = (frame: Frame): boolean =>
        (frame["session"] as SessionBody | undefined)?.control !== undefined;
      const legacy = await waitForFrame(legacyFrames, carriesControl);
      const current = await waitForFrame(currentFrames, carriesControl);
      expect((legacy["session"] as SessionBody).control).toMatchObject({
        domain: "agents",
        intent: "revise",
      });
      expect((current["session"] as SessionBody).control).toMatchObject({
        domain: "extensions",
        intent: "revise",
      });
    } finally {
      legacySocket.terminate();
      currentSocket.terminate();
    }
  }, 30_000);

  function connect(path: string, headers: Record<string, string>): WebSocket {
    return new WebSocket(`ws://localhost${path}`, {
      headers: { Authorization: `Bearer ${token}`, ...headers },
      createConnection: () => createConnection(server.socketPath),
    });
  }
});

type Frame = Record<string, unknown>;

interface SessionEventSource {
  emit(eventName: "session_event", payload: SessionBroadcastEvent): boolean;
}

function controlDomains(sessions: SessionBody[]): string[] {
  return sessions.flatMap((session) => (session.control ? [session.control.domain] : []));
}

function summaryControl(frame: Frame): unknown {
  return (frame["summary"] as { control?: unknown } | undefined)?.control;
}

function opened(ws: WebSocket): Promise<void> {
  return new Promise((resolve, reject) => {
    ws.once("open", () => resolve());
    ws.once("error", reject);
    ws.once("unexpected-response", (_req, res) =>
      reject(new Error(`upgrade failed with HTTP ${res.statusCode}`)),
    );
  });
}

function collectFrames(ws: WebSocket): Frame[] {
  const frames: Frame[] = [];
  ws.on("message", (data: RawData) => {
    frames.push(JSON.parse(Buffer.from(data as Buffer).toString("utf8")) as Frame);
  });
  return frames;
}

async function waitForFrame(frames: Frame[], match: (frame: Frame) => boolean): Promise<Frame> {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    const found = frames.find(match);
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for frame; saw ${JSON.stringify(frames).slice(0, 600)}`);
}

/**
 * A workspace session whose JSONL sits in the canonical trace directory, and an
 * `extensions` control session (no workspace) whose JSONL is its Pi session file. Both open on
 * a user message with one image.
 */
function seed(storage: Storage, dataDir: string): Fixture {
  const workspace = storage.createWorkspace({ name: "legacy-compat", hostMount: dataDir });
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
  // The focused stream resumes this file as a Pi session, which needs a header.
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
    controlSession,
    durableSession,
  };
}
