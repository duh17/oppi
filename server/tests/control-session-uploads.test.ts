import type { IncomingMessage, ServerResponse } from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";

import { afterEach, describe, expect, it, vi } from "vitest";

import { createUploadRoutes } from "../src/routes/uploads.js";
import type { RouteContext, RouteHelpers } from "../src/routes/types.js";
import type { Session } from "../src/types.js";

const roots: string[] = [];

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "control-1",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function jsonRequest(body: unknown): IncomingMessage {
  const req = new PassThrough();
  req.end(JSON.stringify(body));
  return req as unknown as IncomingMessage;
}

describe("control session uploads", () => {
  it("creates uploads under the control route and returns a control-scoped content URL", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-control-upload-"));
    roots.push(root);
    const session = makeSession({
      workspaceId: undefined,
      control: { domain: "agents", intent: "revise", targetId: "agent-1" },
    });
    const responses: Array<{ data: unknown; status: number }> = [];
    const errors: Array<{ status: number; message: string }> = [];
    const ctx = {
      storage: {
        getSession: vi.fn(() => session),
        getConfig: vi.fn(() => ({ dataDir: root, uploadStore: { path: join(root, "uploads") } })),
      },
    } as unknown as RouteContext;
    const helpers: RouteHelpers = {
      parseBody: async <T>(req: IncomingMessage): Promise<T> => {
        const chunks: Buffer[] = [];
        for await (const chunk of req) chunks.push(Buffer.from(chunk));
        return JSON.parse(Buffer.concat(chunks).toString("utf8")) as T;
      },
      json: (_res, data, status = 200) => responses.push({ data, status }),
      compressedJson: vi.fn(),
      error: (_res, status, message) => errors.push({ status, message }),
    };
    const dispatch = createUploadRoutes(ctx, helpers);

    const handled = await dispatch({
      method: "POST",
      path: "/control-sessions/control-1/attachments",
      url: new URL("https://localhost/control-sessions/control-1/attachments"),
      req: jsonRequest({
        name: "notes.txt",
        mimeType: "text/plain",
        sizeBytes: 5,
        purpose: "chat_attachment",
      }),
      res: {} as ServerResponse,
    });

    expect(handled).toBe(true);
    expect(errors).toEqual([]);
    expect(responses).toEqual([
      {
        status: 201,
        data: expect.objectContaining({
          uploadId: expect.stringMatching(/^upl_/),
          contentUrl: expect.stringMatching(
            /^\/control-sessions\/control-1\/attachments\/upl_[a-f0-9]+\/content$/,
          ),
        }),
      },
    ]);
  });

  it.each([
    makeSession({ workspaceId: "ws-1" }),
    makeSession({ workspaceId: undefined, control: undefined }),
  ])("rejects uploads for sessions outside the declared control scope", async (session) => {
    const ctx = {
      storage: {
        getSession: vi.fn(() => session),
      },
    } as unknown as RouteContext;
    const errors: Array<{ status: number; message: string }> = [];
    const helpers = {
      error: (_res: ServerResponse, status: number, message: string) =>
        errors.push({ status, message }),
    } as RouteHelpers;
    const dispatch = createUploadRoutes(ctx, helpers);

    const handled = await dispatch({
      method: "POST",
      path: `/control-sessions/${session.id}/attachments`,
      url: new URL(`https://localhost/control-sessions/${session.id}/attachments`),
      req: jsonRequest({}),
      res: {} as ServerResponse,
    });

    expect(handled).toBe(true);
    expect(errors).toEqual([{ status: 400, message: "Session is not a control session" }]);
  });
});
