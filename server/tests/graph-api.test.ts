import { describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { RouteHandler, type RouteContext } from "../src/routes.js";
import type { Session, Workspace } from "../src/types.js";

interface MockResponse {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
  writeHead: (status: number, headers: Record<string, string>) => MockResponse;
  end: (payload?: string) => void;
}

function makeResponse(): MockResponse {
  return {
    statusCode: 0,
    headers: {},
    body: "",
    writeHead(status: number, headers: Record<string, string>): MockResponse {
      this.statusCode = status;
      this.headers = headers;
      return this;
    },
    end(payload?: string): void {
      this.body = payload ?? "";
    },
  };
}

function makeUser(): User {
  return {
    id: "u1",
    name: "Bob",
    token: "tok",
    createdAt: Date.now(),
  };
}

function makeWorkspace(): Workspace {
  const now = Date.now();
  return {
    id: "w1",
    name: "Workspace",
    runtime: "host",
    skills: [],
    policyPreset: "host",
    createdAt: now,
    updatedAt: now,
  };
}

function makeSession(id: string, overrides: Partial<Session> = {}): Session {
  const now = Date.now();
  return {
    id,
    workspaceId: "w1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
    runtime: "host",
    ...overrides,
  };
}

function makeHarness(opts: {
  workspace?: Workspace;
  sessions?: Session[];
  activeSessionIds?: Set<string>;
}): { routes: RouteHandler; } {
  const workspace = opts.workspace;
  const sessions = opts.sessions ?? [];
  const activeSessionIds = opts.activeSessionIds ?? new Set<string>();

  const sessionById = new Map(sessions.map((session) => [session.id, session]));

  const ctx = {
    storage: {
      getWorkspace: (workspaceId: string) => {
        if (!workspace || workspace.id !== workspaceId) {
          return undefined;
        }
        return workspace;
      },
      listSessions: () => sessions,
      getSession: (sessionId: string) => sessionById.get(sessionId),
    },
    sessions: {
      isActive: (sessionId: string) => activeSessionIds.has(sessionId),
    },
  } as unknown as RouteContext;

  return {
    routes: new RouteHandler(ctx),
    };
}

async function callGraphEndpoint(
  routes: RouteHandler,
  pathWithQuery: string,
): Promise<{ statusCode: number; body: Record<string, unknown> }> {
  const url = new URL(`http://localhost${pathWithQuery}`);
  const res = makeResponse();

  await routes.dispatch(
    "GET",
    "/workspaces/w1/graph",
    url,
    {} as never,
    res as never,
  );

  return {
    statusCode: res.statusCode,
    body: res.body ? (JSON.parse(res.body) as Record<string, unknown>) : {},
  };
}

describe("GET /workspaces/:wid/graph", () => {
  it("returns session-level fork graph projected from pi session headers", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-server-graph-api-"));

    try {
      const rootPath = join(dir, "2026-02-11T10-00-00-000Z_root.jsonl");
      const childPath = join(dir, "2026-02-11T10-05-00-000Z_child.jsonl");

      writeFileSync(
        rootPath,
        `${JSON.stringify({
          type: "session",
          id: "11111111-1111-1111-1111-111111111111",
          timestamp: "2026-02-11T10:00:00.000Z",
          cwd: "/work",
        })}\n`,
        "utf8",
      );

      writeFileSync(
        childPath,
        `${JSON.stringify({
          type: "session",
          id: "22222222-2222-2222-2222-222222222222",
          timestamp: "2026-02-11T10:05:00.000Z",
          cwd: "/work",
          parentSession: rootPath,
        })}\n`,
        "utf8",
      );

      const workspace = makeWorkspace();
      const session = makeSession("s1", {
        piSessionFile: childPath,
        piSessionFiles: [rootPath, childPath],
        piSessionId: "22222222-2222-2222-2222-222222222222",
      });

      const { routes } = makeHarness({
        workspace,
        sessions: [session],
        activeSessionIds: new Set(["s1"]),
      });

      const result = await callGraphEndpoint(routes, "/workspaces/w1/graph");

      expect(result.statusCode).toBe(200);

      const sessionGraph = result.body.sessionGraph as {
        nodes: Array<{
          id: string;
          parentId?: string;
          attachedSessionIds: string[];
          activeSessionIds: string[];
          sessionFile?: string;
        }>;
        edges: Array<{ from: string; to: string; type: string }>;
        roots: string[];
      };

      expect(sessionGraph.nodes).toHaveLength(2);
      expect(sessionGraph.edges).toEqual([
        {
          from: "11111111-1111-1111-1111-111111111111",
          to: "22222222-2222-2222-2222-222222222222",
          type: "fork",
        },
      ]);
      expect(sessionGraph.roots).toEqual(["11111111-1111-1111-1111-111111111111"]);

      const child = sessionGraph.nodes.find((node) => node.id === "22222222-2222-2222-2222-222222222222");
      expect(child).toBeDefined();
      expect(child?.parentId).toBe("11111111-1111-1111-1111-111111111111");
      expect(child?.attachedSessionIds).toEqual(["s1"]);
      expect(child?.activeSessionIds).toEqual(["s1"]);
      expect(child?.sessionFile).toBeUndefined();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("returns optional entry graph for current branch when include=entry", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-server-graph-api-"));

    try {
      const rootPath = join(dir, "2026-02-11T10-00-00-000Z_root.jsonl");
      const childPath = join(dir, "2026-02-11T10-05-00-000Z_child.jsonl");

      writeFileSync(
        rootPath,
        `${JSON.stringify({
          type: "session",
          id: "11111111-1111-1111-1111-111111111111",
          timestamp: "2026-02-11T10:00:00.000Z",
          cwd: "/work",
        })}\n`,
        "utf8",
      );

      const childLines = [
        {
          type: "session",
          id: "22222222-2222-2222-2222-222222222222",
          timestamp: "2026-02-11T10:05:00.000Z",
          cwd: "/work",
          parentSession: rootPath,
        },
        {
          type: "model_change",
          id: "m1",
          parentId: null,
          timestamp: "2026-02-11T10:05:00.100Z",
          provider: "anthropic",
          modelId: "claude-opus-4-6",
        },
        {
          type: "message",
          id: "u1",
          parentId: "m1",
          timestamp: "2026-02-11T10:05:01.000Z",
          message: {
            role: "user",
            content: [{ type: "text", text: "Try approach B" }],
          },
        },
      ];

      writeFileSync(
        childPath,
        `${childLines.map((line) => JSON.stringify(line)).join("\n")}\n`,
        "utf8",
      );

      const workspace = makeWorkspace();
      const session = makeSession("s1", {
        piSessionFile: childPath,
        piSessionFiles: [rootPath, childPath],
        piSessionId: "22222222-2222-2222-2222-222222222222",
      });

      const { routes } = makeHarness({ workspace, sessions: [session] });
      const result = await callGraphEndpoint(
        routes,
        "/workspaces/w1/graph?sessionId=s1&include=entry&includePaths=true",
      );

      expect(result.statusCode).toBe(200);

      const current = result.body.current as { sessionId: string; nodeId?: string };
      expect(current.sessionId).toBe("s1");
      expect(current.nodeId).toBe("22222222-2222-2222-2222-222222222222");

      const entryGraph = result.body.entryGraph as {
        piSessionId: string;
        nodes: Array<{ id: string; type: string; role?: string; preview?: string }>;
        edges: Array<{ from: string; to: string; type: string }>;
      };

      expect(entryGraph.piSessionId).toBe("22222222-2222-2222-2222-222222222222");
      expect(entryGraph.nodes.some((node) => node.id === "u1" && node.role === "user")).toBe(true);
      expect(entryGraph.nodes.some((node) => node.id === "u1" && node.preview === "Try approach B")).toBe(true);
      expect(entryGraph.edges.some((edge) => edge.from === "m1" && edge.to === "u1")).toBe(true);

      const sessionGraph = result.body.sessionGraph as {
        nodes: Array<{ id: string; sessionFile?: string; parentSessionFile?: string }>;
      };
      const childNode = sessionGraph.nodes.find((node) => node.id === "22222222-2222-2222-2222-222222222222");
      expect(childNode?.sessionFile).toBe(childPath);
      expect(childNode?.parentSessionFile).toBe(rootPath);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("returns 404 when workspace does not exist", async () => {
    const { routes } = makeHarness({ workspace: undefined, sessions: [] });
    const result = await callGraphEndpoint(routes, "/workspaces/w1/graph");
    expect(result.statusCode).toBe(404);
  });

  it("returns 404 when sessionId query does not belong to workspace", async () => {
    const workspace = makeWorkspace();
    const { routes } = makeHarness({ workspace, sessions: [] });

    const result = await callGraphEndpoint(routes, "/workspaces/w1/graph?sessionId=missing");
    expect(result.statusCode).toBe(404);
  });
});
