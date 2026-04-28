import type { IncomingMessage, ServerResponse } from "node:http";

import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";
import {
  createUploadRecord,
  getUploadRecord,
  resolveUploadStoreConfig,
  UploadStoreError,
  uploadRecordToAttachmentRef,
  writeUploadContent,
} from "../uploads/local-upload-store.js";

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
  async function handleCreateUpload(
    workspaceId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    try {
      const body = await parseUploadCreateBody(req, helpers);
      const record = await createUploadRecord({
        config: resolveUploadStoreConfig(ctx.storage.getConfig()),
        workspaceId,
        name: typeof body.name === "string" ? body.name : "",
        mimeType: typeof body.mimeType === "string" ? body.mimeType : "application/octet-stream",
        sizeBytes: typeof body.sizeBytes === "number" ? body.sizeBytes : NaN,
        purpose: typeof body.purpose === "string" ? body.purpose : "",
      });
      helpers.json(
        res,
        {
          uploadId: record.id,
          contentUrl: `/workspaces/${workspaceId}/uploads/${record.id}/content`,
          maxFileBytes: resolveUploadStoreConfig(ctx.storage.getConfig()).maxFileBytes,
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
    workspaceId: string,
    uploadId: string,
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }

    try {
      const record = await writeUploadContent({
        config: resolveUploadStoreConfig(ctx.storage.getConfig()),
        workspaceId,
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

  async function handleGetUpload(
    workspaceId: string,
    uploadId: string,
    res: ServerResponse,
  ): Promise<void> {
    const workspace = ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return;
    }
    const record = await getUploadRecord(
      resolveUploadStoreConfig(ctx.storage.getConfig()),
      uploadId,
    );
    if (!record || record.workspaceId !== workspaceId) {
      helpers.error(res, 404, "Upload not found");
      return;
    }
    helpers.json(res, {
      upload: {
        id: record.id,
        status: record.status,
        name: record.safeName,
        mimeType: record.mimeType,
        detectedMimeType: record.detectedMimeType,
        sizeBytes: record.sizeBytes,
        sha256: record.sha256,
        kind: record.kind,
        createdAt: record.createdAt,
        expiresAt: record.expiresAt,
      },
    });
  }

  return async ({ method, path, req, res }) => {
    const createMatch = path.match(/^\/workspaces\/([^/]+)\/uploads$/);
    if (createMatch && method === "POST") {
      await handleCreateUpload(createMatch[1], req, res);
      return true;
    }

    const uploadContentMatch = path.match(/^\/workspaces\/([^/]+)\/uploads\/([^/]+)\/content$/);
    if (uploadContentMatch && method === "PUT") {
      await handleUploadContent(uploadContentMatch[1], uploadContentMatch[2], req, res);
      return true;
    }

    const uploadMatch = path.match(/^\/workspaces\/([^/]+)\/uploads\/([^/]+)$/);
    if (uploadMatch && method === "GET") {
      await handleGetUpload(uploadMatch[1], uploadMatch[2], res);
      return true;
    }

    return false;
  };
}
