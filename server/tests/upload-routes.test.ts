import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import { createRouteHelpers } from "../src/routes/http.js";
import type { RouteContext } from "../src/routes/types.js";
import { createUploadRoutes } from "../src/routes/uploads.js";
import { makeRawRequest, makeRequest, makeResponse } from "./harness/route-test-helpers.js";

describe("uploads module", () => {
  it("creates session-scoped attachment uploads and rejects wrong sessions", async () => {
    const root = mkdtempSync(join(tmpdir(), "oppi-session-upload-routes-test-"));
    const ctx = {
      storage: {
        getWorkspace: vi.fn(() => ({ id: "ws-1", name: "Workspace" })),
        getSession: vi.fn((sessionId: string) =>
          sessionId === "sess-1" || sessionId === "sess-2"
            ? { id: sessionId, workspaceId: "ws-1" }
            : undefined,
        ),
        getConfig: vi.fn(() => ({
          dataDir: root,
          uploadStore: {
            path: join(root, "uploads"),
            maxFileBytes: 1024 * 1024,
            maxTurnBytes: 2 * 1024 * 1024,
            unusedTtlMs: 60_000,
          },
        })),
      },
    } as unknown as RouteContext;

    const dispatch = createUploadRoutes(ctx, createRouteHelpers());

    const createRes = makeResponse();
    const created = await dispatch({
      method: "POST",
      path: "/workspaces/ws-1/sessions/sess-1/attachments",
      url: new URL("http://localhost/workspaces/ws-1/sessions/sess-1/attachments"),
      req: makeRequest({
        name: "note.txt",
        mimeType: "text/plain",
        sizeBytes: 5,
        purpose: "chat_attachment",
      }) as never,
      res: createRes as never,
    });

    expect(created).toBe(true);
    expect(createRes.statusCode).toBe(201);
    const createBody = JSON.parse(createRes.body) as { uploadId: string; contentUrl: string };
    expect(createBody.contentUrl).toBe(
      `/workspaces/ws-1/sessions/sess-1/attachments/${createBody.uploadId}/content`,
    );

    const wrongSessionRes = makeResponse();
    const wrongSession = await dispatch({
      method: "PUT",
      path: `/workspaces/ws-1/sessions/sess-2/attachments/${createBody.uploadId}/content`,
      url: new URL(
        `http://localhost/workspaces/ws-1/sessions/sess-2/attachments/${createBody.uploadId}/content`,
      ),
      req: makeRawRequest("hello") as never,
      res: wrongSessionRes as never,
    });

    expect(wrongSession).toBe(true);
    expect(wrongSessionRes.statusCode).toBe(404);
    expect(JSON.parse(wrongSessionRes.body)).toEqual({ error: "Upload not found" });

    const contentRes = makeResponse();
    const uploaded = await dispatch({
      method: "PUT",
      path: `/workspaces/ws-1/sessions/sess-1/attachments/${createBody.uploadId}/content`,
      url: new URL(
        `http://localhost/workspaces/ws-1/sessions/sess-1/attachments/${createBody.uploadId}/content`,
      ),
      req: makeRawRequest("hello") as never,
      res: contentRes as never,
    });

    expect(uploaded).toBe(true);
    expect(contentRes.statusCode).toBe(200);
    const contentBody = JSON.parse(contentRes.body) as {
      attachment: { id: string; source: string; sizeBytes: number; sha256?: string };
    };
    expect(contentBody.attachment.id).toBe(createBody.uploadId);
    expect(contentBody.attachment.source).toBe("upload");
    expect(contentBody.attachment.sizeBytes).toBe(5);
    expect(contentBody.attachment.sha256).toBeTruthy();

    rmSync(root, { recursive: true, force: true });
  });
});
