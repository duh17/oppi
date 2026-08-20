import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  clipListCell,
  compactSessionListRow,
  formatSessionListRelativeTime,
  listSessions,
  sessionWorkspaceMeta,
} from "../src/cli/commands/session-list.js";
import { localApiRequest, type LocalApiConnection } from "../src/cli/local-api-client.js";

vi.mock("../src/cli/local-api-client.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/local-api-client.js")>();
  return { ...actual, localApiRequest: vi.fn() };
});

const storage = {} as LocalApiConnection;
const resolveRequest = vi.mocked(localApiRequest);

describe("session list command contract", () => {
  beforeEach(() => {
    resolveRequest.mockReset();
    vi.useRealTimers();
  });

  it("lists recent sessions and applies status, worktree, and limit filters client-side", async () => {
    const calls: string[] = [];
    const result = await listSessions(
      storage,
      { status: "active", worktree: "feature", limit: "1" },
      async <T>(path: string): Promise<T> => {
        calls.push(path);
        return {
          serverNow: 42,
          sessions: [
            { id: "busy", status: "busy", worktreeId: "feature" },
            { id: "ready", status: "ready", worktreeId: "feature" },
            { id: "stopped", status: "stopped", worktreeId: "feature" },
            { id: "main", status: "busy" },
          ],
        } as T;
      },
    );

    expect(calls).toEqual(["/sessions/recent?recentDays=3"]);
    expect(result).toMatchObject({ serverNow: 42, sessions: [{ id: "busy" }] });
  });

  it("uses the generic route for agent filtering and preserves query boundaries", async () => {
    const calls: string[] = [];
    const result = await listSessions(
      storage,
      {
        agent: "agent/one",
        status: "busy,error",
        worktree: "wt one",
        limit: "25",
        since: "2026-07-01",
        until: "2026-07-31T12:30:00Z",
      },
      async <T>(path: string): Promise<T> => {
        calls.push(path);
        return {
          sessions: [
            {
              id: "one",
              status: "busy",
              worktreeId: "wt one",
              lastActivity: Date.parse("2026-07-10T00:00:00Z"),
            },
          ],
        } as T;
      },
    );

    expect(calls).toEqual([
      "/sessions?worktreeId=wt+one&status=busy%2Cerror&limit=25&agentId=agent%2Fone&since=2026-07-01&until=2026-07-31T12%3A30%3A00Z",
    ]);
    expect(result.sessions?.map((row) => row.id)).toEqual(["one"]);
  });

  it("uses explicit bounds instead of the default recent window and limits after activity filtering", async () => {
    const calls: string[] = [];
    const result = await listSessions(
      storage,
      { since: "2026-07-01", until: "2026-07-02", limit: "1" },
      async <T>(path: string): Promise<T> => {
        calls.push(path);
        return {
          serverNow: Date.parse("2026-07-03T00:00:00Z"),
          sessions: [
            { id: "too-old", lastActivity: Date.parse("2026-06-30T23:59:59Z") },
            { id: "fallback", lastModified: Date.parse("2026-07-02T12:00:00Z") },
            { id: "inside", lastActivity: Date.parse("2026-07-01T12:00:00Z") },
          ],
        } as T;
      },
    );

    expect(calls).toEqual(["/sessions/recent?since=2026-07-01&until=2026-07-02"]);
    expect(result.sessions?.map((row) => row.id)).toEqual(["fallback"]);
  });

  it("uses the app workspace collection, time window, and stable active/stopped split", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-13T12:00:00.000Z"));
    resolveRequest.mockResolvedValue({ workspace: { id: "ws/resolved" } });
    const calls: string[] = [];

    const result = await listSessions(
      storage,
      { workspace: "Oppi", status: "active,stopped", worktree: "main", limit: "2" },
      async <T>(path: string): Promise<T> => {
        calls.push(path);
        return {
          workspaceId: "ws/resolved",
          active: [
            { id: "active", status: "busy", worktreeId: "main" },
            { id: "other", status: "ready", worktreeId: "other" },
          ],
          stopped: [
            { id: "stopped", status: "stopped", worktreeId: "main" },
            { id: "older", status: "stopped", worktreeId: "main" },
          ],
        } as T;
      },
    );

    expect(resolveRequest).toHaveBeenCalledWith(storage, "/workspaces/Oppi");
    const url = new URL(calls[0] ?? "", "http://local");
    expect(url.pathname).toBe("/workspaces/ws%2Fresolved/sessions");
    expect(url.searchParams.get("status")).toBe("active,stopped");
    expect(url.searchParams.get("worktreeId")).toBe("main");
    expect(Number(url.searchParams.get("untilMs"))).toBe(Date.now() + 1);
    expect(Number(url.searchParams.get("sinceMs"))).toBe(Date.now() - 3 * 86_400_000);
    expect(result.sessions?.map((row) => row.id)).toEqual(["active", "stopped"]);
    expect(result.active?.map((row) => row.id)).toEqual(["active"]);
    expect(result.stopped?.map((row) => row.id)).toEqual(["stopped"]);
  });

  it("passes one-sided explicit bounds to workspace listing without the implicit window", async () => {
    resolveRequest.mockResolvedValue({ workspace: { id: "ws-1" } });
    const calls: string[] = [];

    const result = await listSessions(
      storage,
      { workspace: "ws-1", until: "2026-07-02", limit: "1" },
      async <T>(path: string): Promise<T> => {
        calls.push(path);
        return {
          active: [
            {
              id: "future",
              status: "busy",
              lastActivity: new Date(2026, 6, 3, 1, 0, 0, 0).getTime(),
            },
          ],
          stopped: [
            {
              id: "inside",
              status: "stopped",
              lastActivity: new Date(2026, 6, 2, 23, 59, 59, 999).getTime(),
            },
            { id: "older", status: "stopped", lastActivity: new Date(2026, 6, 1).getTime() },
          ],
        } as T;
      },
    );

    expect(calls).toEqual(["/workspaces/ws-1/sessions?status=active%2Cstopped&until=2026-07-02"]);
    expect(result.sessions?.map((row) => row.id)).toEqual(["inside"]);
  });

  it("falls back from a workspace id lookup and uses generic listing for custom statuses", async () => {
    const notFound = Object.assign(new Error("missing"), { status: 404 });
    resolveRequest
      .mockRejectedValueOnce(notFound)
      .mockResolvedValueOnce({ workspaces: [{ id: "ws-1", name: "Oppi" }] });
    const calls: string[] = [];

    await listSessions(
      storage,
      { workspace: "Oppi", status: "error", agent: "agent-1" },
      async <T>(path: string): Promise<T> => {
        calls.push(path);
        return { sessions: [] } as T;
      },
    );

    expect(calls).toEqual(["/sessions?workspaceId=ws-1&status=error&agentId=agent-1"]);
  });

  it.each(["0", "-1", "nope"])("rejects invalid limit %s before returning rows", async (limit) => {
    await expect(
      listSessions(storage, { limit }, async <T>(): Promise<T> => ({ sessions: [] }) as T),
    ).rejects.toThrow("--limit must be a positive integer");
  });

  it.each([
    [{ since: "not-a-date" }, "invalid session list timestamp: not-a-date"],
    [
      { since: "2026-07-03", until: "2026-07-02" },
      "session list since must be before or equal to until",
    ],
  ])("rejects invalid date bounds before calling the API", async (flags, message) => {
    const call = vi.fn(async <T>(): Promise<T> => ({ sessions: [] }) as T);
    await expect(listSessions(storage, flags, call)).rejects.toThrow(message);
    expect(call).not.toHaveBeenCalled();
  });

  it("treats malformed or empty recent-session collections as empty", async () => {
    const result = await listSessions(
      storage,
      {},
      async <T>(): Promise<T> => ({ sessions: "invalid" }) as T,
    );
    expect(result.sessions).toEqual([]);
  });

  it("keeps compact JSON rows and human metadata bounded", () => {
    expect(
      compactSessionListRow({
        id: "s",
        status: "ready",
        workspaceId: "ws",
        workspaceName: "Oppi",
        lastModified: 10,
        pendingAskCount: 2,
      }),
    ).toEqual({
      id: "s",
      status: "ready",
      name: null,
      workspace_id: "ws",
      workspace_name: "Oppi",
      worktree_id: null,
      model: null,
      runtime: null,
      last_activity: 10,
      message_count: null,
      pending_asks: 2,
    });
    expect(sessionWorkspaceMeta({ workspaceName: "Oppi", workspaceId: "ws" })).toBe(
      "workspace Oppi",
    );
    expect(clipListCell("  abcdef  ", 4)).toBe("abc…");
    expect(clipListCell(null, 4)).toBe("");
  });

  it.each([
    [Date.parse("2026-07-03T11:59:45Z"), "just now"],
    [Date.parse("2026-07-03T11:48:00Z"), "12m ago"],
    [Date.parse("2026-07-03T09:00:00Z"), "3h ago"],
    [Date.parse("2026-06-30T12:00:00Z"), "3d ago"],
    [Number.NaN, ""],
  ])("formats deterministic compact relative activity for %s", (activity, expected) => {
    expect(formatSessionListRelativeTime(activity, Date.parse("2026-07-03T12:00:00Z"))).toBe(
      expected,
    );
  });
});
