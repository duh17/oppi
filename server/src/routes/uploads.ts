import type { IncomingMessage, ServerResponse } from "node:http";

import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";
import {
  createUploadRecord,
  resolveUploadStoreConfig,
  UploadStoreError,
  uploadRecordToAttachmentRef,
  writeUploadContent,
} from "../uploads/local-upload-store.js";
import { isDeclaredControlSession } from "../control-session.js";

async function parseUploadCreateBody(
  req: IncomingMessage,
  helpers: RouteHelpers,
): Promise<{
  name?: string;
  mimeType?: string;
  sizeBytes?: number;
  purpose?: string;
}> {
  return helpers.parseBody(req, { maxBytes: 64 * 1024 });
}

export function createUploadRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  function validateWorkspaceSession(
    workspaceId: string,
    sessionId: string,
    res: ServerResponse,
  ): boolean {
    const workspace = ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return false;
    }

    const session = ctx.storage.getSession(sessionId);
    if (!session || session.workspaceId !== workspaceId) {
      helpers.error(res, 404, "Session not found");
      return false;
    }

    return true;
  }

  async function handleCreateUpload(
    workspaceId: string | undefined,
    sessionId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    if (workspaceId) {
      if (!validateWorkspaceSession(workspaceId, sessionId, res)) return;
    } else {
      const session = ctx.storage.getSession(sessionId);
      if (!session) {
        helpers.error(res, 404, "Session not found");
        return;
      }
      if (!isDeclaredControlSession(session)) {
        helpers.error(res, 400, "Session is not a control session");
        return;
      }
    }

    try {
      const config = resolveUploadStoreConfig(ctx.storage.getConfig());
      const body = await parseUploadCreateBody(req, helpers);
      const record = await createUploadRecord({
        config,
        workspaceId,
        sessionId,
        name: typeof body.name === "string" ? body.name : "",
        mimeType: typeof body.mimeType === "string" ? body.mimeType : "application/octet-stream",
        sizeBytes: typeof body.sizeBytes === "number" ? body.sizeBytes : NaN,
        purpose: typeof body.purpose === "string" ? body.purpose : "",
      });
      helpers.json(
        res,
        {
          uploadId: record.id,
          attachmentId: record.id,
          contentUrl: workspaceId
            ? `/workspaces/${workspaceId}/sessions/${sessionId}/attachments/${record.id}/content`
            : `/control-sessions/${sessionId}/attachments/${record.id}/content`,
          maxFileBytes: config.maxFileBytes,
          expiresAt: record.expiresAt,
        },
        201,
      );
    } catch (error) {
      if (error instanceof UploadStoreError) {
        helpers.error(res, error.status, error.message);
        return;
      }
      if (error instanceof Error && error.message === "Request body too large") {
        helpers.error(res, 413, error.message);
        return;
      }
      if (error instanceof Error && error.message === "Invalid JSON") {
        helpers.error(res, 400, error.message);
        return;
      }
      throw error;
    }
  }

  async function handleUploadContent(
    workspaceId: string | undefined,
    sessionId: string,
    uploadId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    if (workspaceId) {
      if (!validateWorkspaceSession(workspaceId, sessionId, res)) return;
    } else {
      const session = ctx.storage.getSession(sessionId);
      if (!session) {
        helpers.error(res, 404, "Session not found");
        return;
      }
      if (!isDeclaredControlSession(session)) {
        helpers.error(res, 400, "Session is not a control session");
        return;
      }
    }

    try {
      const record = await writeUploadContent({
        config: resolveUploadStoreConfig(ctx.storage.getConfig()),
        workspaceId,
        sessionId,
        uploadId,
        req,
      });
      helpers.json(res, { attachment: uploadRecordToAttachmentRef(record) });
    } catch (error) {
      if (error instanceof UploadStoreError) {
        helpers.error(res, error.status, error.message);
        return;
      }
      throw error;
    }
  }

  return async ({ method, path, req, res }) => {
    const controlCreateMatch = path.match(/^\/control-sessions\/([^/]+)\/attachments$/);
    if (controlCreateMatch && method === "POST") {
      await handleCreateUpload(undefined, controlCreateMatch[1], req, res);
      return true;
    }

    const controlContentMatch = path.match(
      /^\/control-sessions\/([^/]+)\/attachments\/([^/]+)\/content$/,
    );
    if (controlContentMatch && method === "PUT") {
      await handleUploadContent(
        undefined,
        controlContentMatch[1],
        controlContentMatch[2],
        req,
        res,
      );
      return true;
    }

    const sessionCreateMatch = path.match(
      /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/attachments$/,
    );
    if (sessionCreateMatch && method === "POST") {
      await handleCreateUpload(sessionCreateMatch[1], sessionCreateMatch[2], req, res);
      return true;
    }

    const sessionUploadContentMatch = path.match(
      /^\/workspaces\/([^/]+)\/sessions\/([^/]+)\/attachments\/([^/]+)\/content$/,
    );
    if (sessionUploadContentMatch && method === "PUT") {
      await handleUploadContent(
        sessionUploadContentMatch[1],
        sessionUploadContentMatch[2],
        sessionUploadContentMatch[3],
        req,
        res,
      );
      return true;
    }

    return false;
  };
}
