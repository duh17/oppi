import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  clipListCell,
  compactSessionListRow,
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
      },
      async <T>(path: string): Promise<T> => {
        calls.push(path);
        return { sessions: [{ id: "one" }] } as T;
      },
    );

    expect(calls).toEqual([
      "/sessions?worktreeId=wt+one&status=busy%2Cerror&limit=25&agentId=agent%2Fone",
    ]);
    expect(result.sessions).toEqual([{ id: "one" }]);
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
});
