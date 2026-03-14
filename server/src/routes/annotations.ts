import type { ServerResponse } from "node:http";

import {
  listAnnotations,
  createAnnotation,
  updateAnnotation,
  deleteAnnotation,
  AnnotationStoreError,
} from "../annotation-store.js";
import type {
  AnnotationsResponse,
  CreateAnnotationRequest,
  UpdateAnnotationRequest,
} from "../types.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

export function createAnnotationRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  function resolveWorkspaceRoot(workspaceId: string, res: ServerResponse): string | null {
    const workspace = ctx.storage.getWorkspace(workspaceId);
    if (!workspace) {
      helpers.error(res, 404, "Workspace not found");
      return null;
    }
    if (!workspace.hostMount) {
      helpers.error(res, 404, "Workspace has no host mount");
      return null;
    }
    return workspace.hostMount;
  }

  async function handleList(workspaceId: string, url: URL, res: ServerResponse): Promise<void> {
    const root = resolveWorkspaceRoot(workspaceId, res);
    if (!root) return;

    const filterPath = url.searchParams.get("path")?.trim() || undefined;
    const filterSessionId = url.searchParams.get("sessionId")?.trim() || undefined;

    const annotations = await listAnnotations(workspaceId, root, filterPath, filterSessionId);
    const response: AnnotationsResponse = { workspaceId, annotations };
    helpers.json(res, response);
  }

  async function handleCreate(
    workspaceId: string,
    req: Parameters<RouteHelpers["parseBody"]>[0],
    res: ServerResponse,
  ): Promise<void> {
    const root = resolveWorkspaceRoot(workspaceId, res);
    if (!root) return;

    const body = await helpers.parseBody<CreateAnnotationRequest>(req);
    const annotation = await createAnnotation(workspaceId, root, body);
    helpers.json(res, { annotation }, 201);
  }

  async function handleUpdate(
    workspaceId: string,
    annotationId: string,
    req: Parameters<RouteHelpers["parseBody"]>[0],
    res: ServerResponse,
  ): Promise<void> {
    const root = resolveWorkspaceRoot(workspaceId, res);
    if (!root) return;

    const body = await helpers.parseBody<UpdateAnnotationRequest>(req);
    const annotation = await updateAnnotation(root, annotationId, body);
    helpers.json(res, { annotation });
  }

  async function handleDelete(
    workspaceId: string,
    annotationId: string,
    res: ServerResponse,
  ): Promise<void> {
    const root = resolveWorkspaceRoot(workspaceId, res);
    if (!root) return;

    await deleteAnnotation(root, annotationId);
    helpers.json(res, { deleted: true });
  }

  return async ({ method, path, url, req, res }) => {
    // GET/POST /workspaces/:id/annotations
    const listMatch = path.match(/^\/workspaces\/([^/]+)\/annotations$/);
    if (listMatch) {
      const workspaceId = listMatch[1];
      try {
        if (method === "GET") {
          await handleList(workspaceId, url, res);
          return true;
        }
        if (method === "POST") {
          await handleCreate(workspaceId, req, res);
          return true;
        }
      } catch (error) {
        if (error instanceof AnnotationStoreError) {
          helpers.error(res, error.status, error.message);
          return true;
        }
        throw error;
      }
    }

    // PATCH/DELETE /workspaces/:id/annotations/:annotationId
    const itemMatch = path.match(/^\/workspaces\/([^/]+)\/annotations\/([^/]+)$/);
    if (itemMatch) {
      const workspaceId = itemMatch[1];
      const annotationId = itemMatch[2];
      try {
        if (method === "PATCH") {
          await handleUpdate(workspaceId, annotationId, req, res);
          return true;
        }
        if (method === "DELETE") {
          await handleDelete(workspaceId, annotationId, res);
          return true;
        }
      } catch (error) {
        if (error instanceof AnnotationStoreError) {
          helpers.error(res, error.status, error.message);
          return true;
        }
        throw error;
      }
    }

    return false;
  };
}
