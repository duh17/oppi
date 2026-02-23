import type { ServerResponse } from "node:http";

import { discoverProjects, scanDirectories } from "../host.js";
import { listHostExtensions } from "../extension-loader.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

export function createSkillRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  function handleListSkills(res: ServerResponse): void {
    helpers.json(res, { skills: ctx.skillRegistry.list() });
  }

  function handleRescanSkills(res: ServerResponse): void {
    const event = ctx.skillRegistry.scan();
    helpers.json(res, { skills: ctx.skillRegistry.list(), changed: event });
  }

  function handleListExtensions(res: ServerResponse): void {
    helpers.json(res, { extensions: listHostExtensions() });
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

  // ─── User Skills (read-only; mutation disabled) ───

  function handleListUserSkills(res: ServerResponse): void {
    // Build enabledIn map: skill name → workspace IDs
    const workspaces = ctx.storage.listWorkspaces();
    const enabledIn = new Map<string, string[]>();
    for (const ws of workspaces) {
      for (const skill of ws.skills) {
        const list = enabledIn.get(skill) || [];
        list.push(ws.id);
        enabledIn.set(skill, list);
      }
    }

    const builtIn = ctx.skillRegistry.list().map((s) => ({
      ...s,
      builtIn: true as const,
      enabledIn: enabledIn.get(s.name) || [],
    }));
    const userSkills = ctx.userSkillStore.listSkills().map((s) => ({
      ...s,
      enabledIn: enabledIn.get(s.name) || [],
    }));
    helpers.json(res, { skills: [...builtIn, ...userSkills] });
  }

  function handleGetUserSkill(name: string, res: ServerResponse): void {
    const userSkill = ctx.userSkillStore.getSkill(name);
    if (userSkill) {
      const files = ctx.userSkillStore.listFiles(name);
      helpers.json(res, { skill: userSkill, files });
      return;
    }

    const builtIn = ctx.skillRegistry.getDetail(name);
    if (builtIn) {
      helpers.json(res, {
        skill: { ...builtIn.skill, builtIn: true },
        files: builtIn.files,
        content: builtIn.content,
      });
      return;
    }

    helpers.error(res, 404, "Skill not found");
  }

  async function handleSaveUserSkill(res: ServerResponse): Promise<void> {
    helpers.error(res, 403, "Skill editing is disabled on remote clients");
  }

  /**
   * PUT /me/skills/:name
   *
   * Skill mutation is intentionally disabled for remote clients.
   */
  async function handlePutUserSkill(res: ServerResponse): Promise<void> {
    helpers.error(res, 403, "Skill editing is disabled on remote clients");
  }

  function handleDeleteUserSkill(res: ServerResponse): void {
    helpers.error(res, 403, "Skill editing is disabled on remote clients");
  }

  function handleGetUserSkillFile(name: string, url: URL, res: ServerResponse): void {
    const filePath = url.searchParams.get("path");
    if (!filePath) {
      helpers.error(res, 400, "path parameter required");
      return;
    }

    const content =
      ctx.userSkillStore.readFile(name, filePath) ??
      ctx.skillRegistry.getFileContent(name, filePath);

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

  return async ({ method, path, url, res }) => {
    if (path === "/skills" && method === "GET") {
      handleListSkills(res);
      return true;
    }

    if (path === "/skills/rescan" && method === "POST") {
      handleRescanSkills(res);
      return true;
    }

    if (path === "/extensions" && method === "GET") {
      handleListExtensions(res);
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

    // User skills CRUD
    if (path === "/me/skills" && method === "GET") {
      handleListUserSkills(res);
      return true;
    }

    if (path === "/me/skills" && method === "POST") {
      await handleSaveUserSkill(res);
      return true;
    }

    const userSkillFileMatch = path.match(/^\/me\/skills\/([^/]+)\/files$/);
    if (userSkillFileMatch && method === "GET") {
      handleGetUserSkillFile(userSkillFileMatch[1], url, res);
      return true;
    }

    const userSkillMatch = path.match(/^\/me\/skills\/([^/]+)$/);
    if (userSkillMatch) {
      if (method === "GET") {
        handleGetUserSkill(userSkillMatch[1], res);
        return true;
      }
      if (method === "PUT") {
        await handlePutUserSkill(res);
        return true;
      }
      if (method === "DELETE") {
        handleDeleteUserSkill(res);
        return true;
      }
    }

    return false;
  };
}
