import { describe, expect, it, vi } from "vitest";
import { RouteHandler, type RouteContext } from "../src/routes.js";
import type { PendingDecision } from "../src/gate.js";

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

function makePending(overrides: Partial<PendingDecision> = {}): PendingDecision {
  const now = Date.now();
  return {
    id: "perm-1",
    sessionId: "s1",
    workspaceId: "w1",
    tool: "bash",
    input: { command: "echo hello" },
    displaySummary: "Run: echo hello",
    reason: "bash execution",
    timeoutAt: now + 60_000,
    ...overrides,
  };
}

function makeHarness(options?: {
  pending?: PendingDecision[];
  sessions?: Set<string>;
  workspaces?: Set<string>;
}): { routes: RouteHandler; pending: PendingDecision[] } {
  const pending = options?.pending ?? [];
  const sessions = options?.sessions ?? new Set(["s1", "s2"]);
  const workspaces = options?.workspaces ?? new Set(["w1", "w2"]);

  const ctx = {
    gate: {
      getPendingForUser: vi.fn(() => pending),
    },
    storage: {
      getSession: vi.fn((sessionId: string) => {
        if (!sessions.has(sessionId)) return undefined;
        return { id: sessionId };
      }),
      getWorkspace: vi.fn((workspaceId: string) => {
        if (!workspaces.has(workspaceId)) return undefined;
        return { id: workspaceId };
      }),
    },
  } as unknown as RouteContext;

  const routes = new RouteHandler(ctx);
  return { routes, pending };
}

async function callPendingEndpoint(
  routes: RouteHandler,
  url: URL,
): Promise<{ statusCode: number; body: Record<string, unknown> }> {
  const res = makeResponse();

  await routes.dispatch(
    "GET",
    "/permissions/pending",
    url,
    {} as never,
    res as never,
  );

  return {
    statusCode: res.statusCode,
    body: JSON.parse(res.body) as Record<string, unknown>,
  };
}

describe("GET /permissions/pending", () => {
  it("returns pending snapshot with server time and excludes expired entries", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-02-10T09:00:00.000Z"));

    const now = Date.now();
    const activeA = makePending({ id: "perm-a", sessionId: "s1", workspaceId: "w1" });
    const activeB = makePending({ id: "perm-b", sessionId: "s2", workspaceId: "w2" });
    const expired = makePending({ id: "perm-expired", timeoutAt: now - 1 });

    const { routes } = makeHarness({ pending: [activeA, expired, activeB] });
    const result = await callPendingEndpoint(routes, new URL("http://localhost/permissions/pending"));

    expect(result.statusCode).toBe(200);
    const body = result.body;
    expect(body.serverTime).toBeTypeOf("number");
    expect(body.pending).toHaveLength(2);
    expect((body.pending as { id: string }[])[0].id).toBe("perm-a");
    expect((body.pending as { id: string }[])[1].id).toBe("perm-b");

    vi.useRealTimers();
  });

  it("filters by sessionId query param with 404 on unknown session", async () => {
    const { routes } = makeHarness({
      pending: [
        makePending({ id: "perm-1", sessionId: "s1" }),
        makePending({ id: "perm-2", sessionId: "s2" }),
      ],
    });

    const filtered = await callPendingEndpoint(
      routes,
      new URL("http://localhost/permissions/pending?sessionId=s1"),
    );
    expect(filtered.statusCode).toBe(200);
    expect(filtered.body.pending).toHaveLength(1);
    expect((filtered.body.pending as { id: string }[])[0].id).toBe("perm-1");

    const notFound = await callPendingEndpoint(
      routes,
      new URL("http://localhost/permissions/pending?sessionId=nonexistent"),
    );
    expect(notFound.statusCode).toBe(404);
  });

  it("filters by workspaceId query param", async () => {
    const { routes } = makeHarness({
      pending: [
        makePending({ id: "perm-1", workspaceId: "w1" }),
        makePending({ id: "perm-2", workspaceId: "w2" }),
      ],
    });

    const filtered = await callPendingEndpoint(
      routes,
      new URL("http://localhost/permissions/pending?workspaceId=w2"),
    );
    expect(filtered.statusCode).toBe(200);
    expect(filtered.body.pending).toHaveLength(1);
    expect((filtered.body.pending as { id: string }[])[0].id).toBe("perm-2");
  });

  it("keeps non-expiring pending permissions in snapshot", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-02-10T10:00:00.000Z"));

    const now = Date.now();
    const nonExpiring = makePending({
      id: "perm-indefinite",
      timeoutAt: now - 1,
      expires: false,
    });
    const expiring = makePending({
      id: "perm-expiring",
      timeoutAt: now + 60_000,
      expires: true,
    });

    const { routes } = makeHarness({ pending: [nonExpiring, expiring] });
    const result = await callPendingEndpoint(routes, new URL("http://localhost/permissions/pending"));

    expect(result.statusCode).toBe(200);
    const pending = result.body.pending as { id: string; expires?: boolean }[];
    expect(pending).toHaveLength(2);
    expect(pending[0].id).toBe("perm-indefinite");
    expect(pending[0].expires).toBe(false);

    vi.useRealTimers();
  });

  it("tracks rapid add/expire/cancel cycles deterministically", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-02-10T10:00:00.000Z"));

    const baseTime = Date.now();

    const makeTimedPending = (id: string, timeoutAt: number) =>
      makePending({ id, timeoutAt });

    const allPending = [
      makeTimedPending("cycle-1", baseTime + 500),
      makeTimedPending("cycle-2", baseTime - 100),
      makeTimedPending("cycle-3", baseTime + 10_000),
      makeTimedPending("cycle-4", baseTime - 1),
      makeTimedPending("cycle-5", baseTime + 1),
    ];

    const { routes } = makeHarness({ pending: allPending });

    const result = await callPendingEndpoint(routes, new URL("http://localhost/permissions/pending"));
    expect(result.statusCode).toBe(200);

    const ids = (result.body.pending as { id: string }[]).map((p) => p.id);
    expect(ids).toEqual(["cycle-1", "cycle-3", "cycle-5"]);

    vi.useRealTimers();
  });
});
