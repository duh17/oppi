import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { afterEach, describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import { createSessionRoutes } from "../src/routes/sessions.js";
import type { RouteContext } from "../src/routes/types.js";
import type { Session } from "../src/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

let tmpDir: string | undefined;

afterEach(() => {
  if (tmpDir) {
    rmSync(tmpDir, { recursive: true, force: true });
    tmpDir = undefined;
  }
});

function writeCanonicalTraceFiles(dataDir: string, workspaceId: string, sessionId: string): void {
  const traceDir = join(
    dataDir,
    workspaceId,
    "sessions",
    sessionId,
    "agent",
    "sessions",
    "--work--",
  );
  mkdirSync(traceDir, { recursive: true });
  const timestamp = "2026-01-01T00:00:00.000Z";
  const firstFile = [
    {
      type: "message",
      id: "u1",
      parentId: null,
      timestamp,
      message: { role: "user", content: "first prompt" },
    },
  ];
  const secondFile = [
    {
      type: "message",
      id: "a1",
      parentId: "u1",
      timestamp,
      message: {
        role: "assistant",
        content: [
          { type: "text", text: "first answer" },
          { type: "toolCall", id: "tc-1", name: "read", arguments: { path: "server/src/trace.ts" } },
        ],
      },
    },
    {
      type: "message",
      id: "r1",
      parentId: "a1",
      timestamp,
      message: {
        role: "toolResult",
        toolCallId: "tc-1",
        toolName: "read",
        content: "large output".repeat(1000),
      },
    },
  ];

  writeFileSync(
    join(traceDir, "20260101T000000Z-first.jsonl"),
    firstFile.map((line) => JSON.stringify(line)).join("\n"),
  );
  writeFileSync(
    join(traceDir, "20260101T000100Z-second.jsonl"),
    secondFile.map((line) => JSON.stringify(line)).join("\n"),
  );
}

describe("workspace session trace outline route", () => {
  it("returns a lightweight outline from canonical multi-file traces", async () => {
    tmpDir = mkdtempSync(join(tmpdir(), "trace-outline-route-test-"));
    writeCanonicalTraceFiles(tmpDir, "ws-1", "s1");
    const session: Session = {
      id: "s1",
      workspaceId: "ws-1",
      status: "stopped",
      createdAt: 0,
      lastActivity: 10,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    };
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Test" })),
        getSession: vi.fn(() => session),
        getDataDir: vi.fn(() => tmpDir ?? tmpdir()),
        listWorkspaces: vi.fn(() => []),
      },
      sessionRuntimes: {
        refreshSessionState: vi.fn(async () => null),
        getToolFullOutputPath: vi.fn(() => undefined),
      },
      ensureSessionContextWindow: vi.fn((s: Session) => s),
    } as unknown as RouteContext;

    const dispatch = createSessionRoutes(ctx, createRouteHelpers());
    const res = makeResponse();

    const handled = await dispatch({
      method: "GET",
      path: "/workspaces/ws-1/sessions/s1/trace-outline",
      url: new URL("http://localhost/workspaces/ws-1/sessions/s1/trace-outline"),
      req: makeRequest() as never,
      res: res as never,
    });

    expect(handled).toBe(true);
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body) as {
      session: { id: string };
      outline: {
        itemCount: number;
        entries: Array<{ id: string; kind: string; summary: string }>;
      };
      metrics: { jsonBytes: number; gzipBytes: number };
    };
    expect(body.session.id).toBe("s1");
    expect(body.outline.itemCount).toBe(3);
    expect(body.outline.entries.map((entry) => entry.id)).toEqual(["u1", "a1-text-0", "tc-1"]);
    expect(body.outline.entries[2]).toMatchObject({ kind: "tool", summary: "read server/src/trace.ts" });
    expect(JSON.stringify(body.outline)).not.toContain("large output");
    expect(body.metrics.jsonBytes).toBeGreaterThan(0);
    expect(body.metrics.gzipBytes).toBeGreaterThan(0);
  });
});
