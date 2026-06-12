import type { IncomingMessage, ServerResponse } from "node:http";

import {
  completeHostPath,
  createHostWorkspaceDirectory,
  discoverProjects,
  getHostPathStatus,
  HostPathCreateError,
  scanDirectories,
} from "../host.js";
import { listConfiguredHostExtensions } from "../extension-loader.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const DEPRECATED_EXTENSION_NAMES = new Set(["review"]);

export function createSkillRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  function handleListSkills(res: ServerResponse): void {
    helpers.json(res, { skills: ctx.skillRegistry.list() });
  }

  function handleRescanSkills(res: ServerResponse): void {
    const event = ctx.skillRegistry.scan();
    helpers.json(res, { skills: ctx.skillRegistry.list(), changed: event });
  }

  async function handleListExtensions(url: URL, res: ServerResponse): Promise<void> {
    const cwd = url.searchParams.get("cwd") ?? undefined;
    const piExtensions = (await listConfiguredHostExtensions({ cwd }))
      .filter((ext) => !DEPRECATED_EXTENSION_NAMES.has(ext.name))
      .map((ext) => ({
        ...ext,
        source: "pi" as const,
      }));
    const byName = new Map<string, (typeof piExtensions)[number]>();
    for (const ext of piExtensions) {
      if (!byName.has(ext.name)) {
        byName.set(ext.name, ext);
      }
    }

    helpers.json(res, { extensions: Array.from(byName.values()) });
  }

  function handleGetSkillDetail(name: string, res: ServerResponse): void {
    const detail = ctx.skillRegistry.getDetail(name);
    if (!detail) {
      helpers.error(res, 404, "Skill not found");
      return;
    }
    helpers.json(res, detail);
  }

  function handleGetSkillFile(name: string, url: URL, res: ServerResponse): void {
    const filePath = url.searchParams.get("path");
    if (!filePath) {
      helpers.error(res, 400, "path parameter required");
      return;
    }

    const content = ctx.skillRegistry.getFileContent(name, filePath);
    if (content === undefined) {
      helpers.error(res, 404, "File not found");
      return;
    }
    helpers.json(res, { content });
  }

  function handleListDirectories(url: URL, res: ServerResponse): void {
    const root = url.searchParams.get("root");
    const dirs = root ? scanDirectories(root) : discoverProjects();
    helpers.json(res, { directories: dirs });
  }

  function handleGetHostPathStatus(url: URL, res: ServerResponse): void {
    const path = url.searchParams.get("path")?.trim();
    if (!path) {
      helpers.json(res, {
        status: {
          path: "",
          resolvedPath: "",
          exists: false,
          isDirectory: false,
          isFile: false,
          issue: "missing",
          message: "Path required",
        },
      });
      return;
    }

    helpers.json(res, { status: getHostPathStatus(path) });
  }

  function handleListHostPathCompletions(url: URL, res: ServerResponse): void {
    const prefix = url.searchParams.get("prefix") ?? "";
    const limit = Number.parseInt(url.searchParams.get("limit") ?? "20", 10) || 20;
    helpers.json(res, { completions: completeHostPath(prefix, limit) });
  }

  async function handleCreateHostPath(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const body = await helpers.parseBody<{ path?: unknown; confirmed?: unknown }>(req);
    if (body.confirmed !== true) {
      helpers.error(res, 400, "Directory creation requires explicit confirmation");
      return;
    }
    if (typeof body.path !== "string" || body.path.trim().length === 0) {
      helpers.error(res, 400, "path required");
      return;
    }

    try {
      const result = createHostWorkspaceDirectory(body.path);
      helpers.json(res, result, result.created ? 201 : 200);
    } catch (err: unknown) {
      if (err instanceof HostPathCreateError) {
        helpers.error(res, err.status, err.message);
        return;
      }
      const message = err instanceof Error ? err.message : "Failed to create directory";
      helpers.error(res, 500, message);
    }
  }

  return async ({ method, path, url, req, res }) => {
    if (path === "/skills" && method === "GET") {
      handleListSkills(res);
      return true;
    }

    if (path === "/skills/rescan" && method === "POST") {
      handleRescanSkills(res);
      return true;
    }

    if (path === "/extensions" && method === "GET") {
      await handleListExtensions(url, res);
      return true;
    }

    // Skill detail + file access
    const skillFileMatch = path.match(/^\/skills\/([^/]+)\/file$/);
    if (skillFileMatch && method === "GET") {
      handleGetSkillFile(skillFileMatch[1], url, res);
      return true;
    }

    const skillDetailMatch = path.match(/^\/skills\/([^/]+)$/);
    if (skillDetailMatch && method === "GET") {
      handleGetSkillDetail(skillDetailMatch[1], res);
      return true;
    }

    // Host discovery
    if (path === "/host/directories" && method === "GET") {
      handleListDirectories(url, res);
      return true;
    }

    if (path === "/host/path/status" && method === "GET") {
      handleGetHostPathStatus(url, res);
      return true;
    }

    if (path === "/host/path/completions" && method === "GET") {
      handleListHostPathCompletions(url, res);
      return true;
    }

    if (path === "/host/path/create" && method === "POST") {
      await handleCreateHostPath(req, res);
      return true;
    }

    return false;
  };
}
