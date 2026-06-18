import { lstatSync, readFileSync, realpathSync, statSync, readdirSync } from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

import {
  DefaultPackageManager,
  SettingsManager,
  getAgentDir,
  loadSkills,
  type PackageSource,
  type ResolvedResource,
  type Skill,
} from "@earendil-works/pi-coding-agent";

import {
  completeHostPath,
  createHostWorkspaceDirectory,
  discoverProjects,
  getHostPathStatus,
  HostPathCreateError,
  scanDirectories,
} from "../host.js";
import { listConfiguredHostExtensionResources } from "../extension-loader.js";
import type { RouteContext, RouteDispatcher, RouteHelpers } from "./types.js";

const DEPRECATED_EXTENSION_NAMES = new Set(["review"]);
const MAX_SKILL_FILE_BYTES = 1024 * 1024;
const MAX_SKILL_LISTED_FILES = 500;

interface SkillRouteInfo {
  name: string;
  description: string;
  path: string;
  builtIn: boolean;
  enabled: boolean;
}

type PiResourceType = "skills" | "extensions";

function resolveResourceCwd(cwd: string | undefined): string {
  const raw = cwd?.trim();
  if (!raw) return homedir();
  const expanded = raw === "~" || raw.startsWith("~/") ? raw.replace(/^~(?=\/|$)/, homedir()) : raw;
  return resolve(expanded);
}

function sdkSkillToInfo(skill: Skill, resource?: ResolvedResource): SkillRouteInfo {
  return {
    name: skill.name,
    description: skill.description,
    path: skill.baseDir,
    builtIn: false,
    enabled: resource?.enabled ?? true,
  };
}

function skillMatchesResource(skill: Skill, resource: ResolvedResource): boolean {
  return (
    resource.path === skill.filePath ||
    resource.path === skill.baseDir ||
    skill.filePath.startsWith(`${resource.path}/`) ||
    (resource.path.endsWith("/SKILL.md") && dirname(resource.path) === skill.baseDir)
  );
}

async function resolvePiResources(cwd: string): Promise<{
  agentDir: string;
  settingsManager: SettingsManager;
  resolved: Awaited<ReturnType<DefaultPackageManager["resolve"]>>;
}> {
  const agentDir = getAgentDir();
  const settingsManager = SettingsManager.create(cwd, agentDir);
  const packageManager = new DefaultPackageManager({ cwd, agentDir, settingsManager });
  const resolved = await packageManager.resolve(async () => "skip");
  return { agentDir, settingsManager, resolved };
}

async function listConfiguredHostSkills(cwd: string): Promise<SkillRouteInfo[]> {
  const { agentDir, resolved } = await resolvePiResources(cwd);
  const skillPaths = resolved.skills.map((resource) => resource.path);
  const result = loadSkills({
    cwd,
    agentDir,
    skillPaths,
    includeDefaults: false,
  });

  return result.skills.map((skill) =>
    sdkSkillToInfo(
      skill,
      resolved.skills.find((resource) => skillMatchesResource(skill, resource)),
    ),
  );
}

function isWithinDirectory(path: string, baseDir: string): boolean {
  const rel = relative(baseDir, path);
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

function safeRealSkillBase(skillPath: string): string | undefined {
  try {
    if (!lstatSync(skillPath).isDirectory()) {
      return undefined;
    }
    return realpathSync(skillPath);
  } catch {
    return undefined;
  }
}

function listFilesRecursive(
  baseDir: string,
  prefix = "",
  realBase = safeRealSkillBase(baseDir),
  count = { value: 0 },
): string[] {
  if (!realBase || count.value >= MAX_SKILL_LISTED_FILES) return [];

  const skipDirs = new Set([
    "__pycache__",
    "node_modules",
    ".git",
    ".venv",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    "__pypackages__",
  ]);
  const skipExts = new Set([".pyc", ".pyo", ".o", ".so", ".dylib"]);
  const dir = prefix ? join(baseDir, prefix) : baseDir;
  let entries: string[];
  try {
    entries = readdirSync(dir);
  } catch {
    return [];
  }

  const results: string[] = [];
  for (const entry of entries.sort()) {
    if (count.value >= MAX_SKILL_LISTED_FILES) break;

    const rel = prefix ? `${prefix}/${entry}` : entry;
    const full = join(dir, entry);
    try {
      const stat = lstatSync(full);
      if (stat.isSymbolicLink()) {
        continue;
      }

      const real = realpathSync(full);
      if (!isWithinDirectory(real, realBase)) {
        continue;
      }

      if (stat.isDirectory()) {
        if (!skipDirs.has(entry)) {
          results.push(...listFilesRecursive(baseDir, rel, realBase, count));
        }
      } else if (stat.isFile()) {
        const ext = entry.includes(".") ? entry.substring(entry.lastIndexOf(".")) : "";
        if (!skipExts.has(ext)) {
          results.push(rel);
          count.value += 1;
        }
      }
    } catch {
      // Ignore unreadable entries.
    }
  }
  return results;
}

function resolveSkillFilePath(skillPath: string, relPath: string): string | undefined {
  const realBase = safeRealSkillBase(skillPath);
  if (!realBase) return undefined;

  const requested = resolve(skillPath, relPath);
  try {
    if (lstatSync(requested).isSymbolicLink()) {
      return undefined;
    }
    const resolved = realpathSync(requested);
    if (!isWithinDirectory(resolved, realBase)) {
      return undefined;
    }

    const stat = statSync(resolved);
    if (!stat.isFile() || stat.size > MAX_SKILL_FILE_BYTES) {
      return undefined;
    }
    return resolved;
  } catch {
    return undefined;
  }
}

function readSkillFileContent(skillPath: string, relPath: string): string | undefined {
  const target = resolveSkillFilePath(skillPath, relPath);
  if (!target) return undefined;

  try {
    return readFileSync(target, "utf-8");
  } catch {
    return undefined;
  }
}

function toPosixPath(path: string): string {
  return path.split(sep).join("/");
}

function stripPatternPrefix(pattern: string): string {
  return pattern.startsWith("!") || pattern.startsWith("+") || pattern.startsWith("-")
    ? pattern.slice(1)
    : pattern;
}

function topLevelBaseDir(resource: ResolvedResource, cwd: string, agentDir: string): string {
  if (resource.metadata.baseDir) return resource.metadata.baseDir;
  return resource.metadata.scope === "project" ? join(cwd, ".pi") : agentDir;
}

function resourcePattern(resource: ResolvedResource, cwd: string, agentDir: string): string {
  const baseDir =
    resource.metadata.origin === "package"
      ? (resource.metadata.baseDir ?? dirname(resource.path))
      : topLevelBaseDir(resource, cwd, agentDir);
  return toPosixPath(relative(baseDir, resource.path));
}

function writeResourceSettings(
  settingsManager: SettingsManager,
  resource: ResolvedResource,
  resourceType: PiResourceType,
  cwd: string,
  agentDir: string,
  enabled: boolean,
): void {
  const scope = resource.metadata.scope;
  if (scope !== "user" && scope !== "project") {
    throw new Error("Temporary resources cannot be edited from Oppi");
  }

  const settings =
    scope === "project"
      ? settingsManager.getProjectSettings()
      : settingsManager.getGlobalSettings();
  const pattern = resourcePattern(resource, cwd, agentDir);
  const updated = ([...(settings[resourceType] ?? [])] as string[]).filter(
    (entry) => stripPatternPrefix(entry) !== pattern,
  );
  updated.push(`${enabled ? "+" : "-"}${pattern}`);

  if (scope === "project") {
    if (resourceType === "extensions") {
      settingsManager.setProjectExtensionPaths(updated);
    } else {
      settingsManager.setProjectSkillPaths(updated);
    }
  } else if (resourceType === "extensions") {
    settingsManager.setExtensionPaths(updated);
  } else {
    settingsManager.setSkillPaths(updated);
  }
}

function writePackageResourceSettings(
  settingsManager: SettingsManager,
  resource: ResolvedResource,
  resourceType: PiResourceType,
  cwd: string,
  agentDir: string,
  enabled: boolean,
): void {
  const scope = resource.metadata.scope;
  if (scope !== "user" && scope !== "project") {
    throw new Error("Temporary resources cannot be edited from Oppi");
  }

  const settings =
    scope === "project"
      ? settingsManager.getProjectSettings()
      : settingsManager.getGlobalSettings();
  const packages = [...(settings.packages ?? [])] as PackageSource[];
  const packageIndex = packages.findIndex((pkg) => {
    const source = typeof pkg === "string" ? pkg : pkg.source;
    return source === resource.metadata.source;
  });

  if (packageIndex < 0) {
    throw new Error(`Package source not found in ${scope} settings`);
  }

  let pkg = packages[packageIndex];
  if (typeof pkg === "string") {
    pkg = { source: pkg };
    packages[packageIndex] = pkg;
  }

  const current = [...(pkg[resourceType] ?? [])];
  const pattern = resourcePattern(resource, cwd, agentDir);
  const updated = current.filter((entry) => stripPatternPrefix(entry) !== pattern);
  updated.push(`${enabled ? "+" : "-"}${pattern}`);
  pkg[resourceType] = updated;

  const hasFilters = ["extensions", "skills", "prompts", "themes"].some(
    (key) => (pkg as Record<string, unknown>)[key] !== undefined,
  );
  if (!hasFilters) {
    packages[packageIndex] = pkg.source;
  }

  if (scope === "project") {
    settingsManager.setProjectPackages(packages);
  } else {
    settingsManager.setPackages(packages);
  }
}

function normalizeClientResourcePath(path: string): string {
  const trimmed = path.trim().replace(/\/+$/, "");
  const expanded =
    trimmed === "~" || trimmed.startsWith("~/")
      ? trimmed.replace(/^~(?=\/|$)/, homedir())
      : trimmed;
  return resolve(expanded);
}

function resourceMatchesClientPath(
  type: PiResourceType,
  resource: ResolvedResource,
  requestedPath: string,
): boolean {
  const resourcePath = resolve(resource.path).replace(/\/+$/, "");
  if (resourcePath === requestedPath) {
    return true;
  }

  if (type === "skills") {
    return basename(resourcePath) === "SKILL.md" && dirname(resourcePath) === requestedPath;
  }

  return (
    (basename(resourcePath) === "index.ts" || basename(resourcePath) === "index.js") &&
    dirname(resourcePath) === requestedPath
  );
}

async function setPiResourceEnabled(options: {
  cwd: string;
  type: PiResourceType;
  path: string;
  enabled: boolean;
}): Promise<void> {
  const { agentDir, settingsManager, resolved } = await resolvePiResources(options.cwd);
  const resources = resolved[options.type];
  const requestedPath = normalizeClientResourcePath(options.path);
  const resource = resources.find((item) =>
    resourceMatchesClientPath(options.type, item, requestedPath),
  );
  if (!resource) {
    throw new Error("Pi resource not found for cwd");
  }

  if (resource.metadata.origin === "package") {
    writePackageResourceSettings(
      settingsManager,
      resource,
      options.type,
      options.cwd,
      agentDir,
      options.enabled,
    );
    return;
  }

  writeResourceSettings(
    settingsManager,
    resource,
    options.type,
    options.cwd,
    agentDir,
    options.enabled,
  );
}

export function createSkillRoutes(ctx: RouteContext, helpers: RouteHelpers): RouteDispatcher {
  async function handleListSkills(url: URL, res: ServerResponse): Promise<void> {
    const cwd = url.searchParams.get("cwd") ?? undefined;
    if (cwd) {
      helpers.json(res, { skills: await listConfiguredHostSkills(cwd) });
      return;
    }
    helpers.json(res, { skills: ctx.skillRegistry.list() });
  }

  function handleRescanSkills(res: ServerResponse): void {
    const event = ctx.skillRegistry.scan();
    helpers.json(res, { skills: ctx.skillRegistry.list(), changed: event });
  }

  async function handleListExtensions(url: URL, res: ServerResponse): Promise<void> {
    const cwd = url.searchParams.get("cwd") ?? undefined;
    const piExtensions = (await listConfiguredHostExtensionResources({ cwd }))
      .filter((ext) => !DEPRECATED_EXTENSION_NAMES.has(ext.name))
      .map((ext) => ({
        ...ext,
        enabled: ext.enabled ?? true,
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

  async function handleGetSkillDetail(name: string, url: URL, res: ServerResponse): Promise<void> {
    const cwd = url.searchParams.get("cwd") ?? undefined;
    if (cwd) {
      const skill = (await listConfiguredHostSkills(cwd)).find((item) => item.name === name);
      if (!skill) {
        helpers.error(res, 404, "Skill not found");
        return;
      }
      const content = readSkillFileContent(skill.path, "SKILL.md") ?? "";
      helpers.json(res, { skill, content, files: listFilesRecursive(skill.path) });
      return;
    }

    const detail = ctx.skillRegistry.getDetail(name);
    if (!detail) {
      helpers.error(res, 404, "Skill not found");
      return;
    }
    helpers.json(res, detail);
  }

  async function handleGetSkillFile(name: string, url: URL, res: ServerResponse): Promise<void> {
    const filePath = url.searchParams.get("path");
    if (!filePath) {
      helpers.error(res, 400, "path parameter required");
      return;
    }

    const cwd = url.searchParams.get("cwd") ?? undefined;
    if (cwd) {
      const skill = (await listConfiguredHostSkills(cwd)).find((item) => item.name === name);
      const content = skill ? readSkillFileContent(skill.path, filePath) : undefined;
      if (content === undefined) {
        helpers.error(res, 404, "File not found");
        return;
      }
      helpers.json(res, { content });
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

  async function handleSetPiResourceEnabled(
    req: IncomingMessage,
    res: ServerResponse,
  ): Promise<void> {
    const body = await helpers.parseBody<{
      cwd?: unknown;
      type?: unknown;
      path?: unknown;
      enabled?: unknown;
    }>(req);

    const type = body.type;
    if (type !== "skills" && type !== "extensions") {
      helpers.error(res, 400, "type must be skills or extensions");
      return;
    }
    if (typeof body.path !== "string" || body.path.trim().length === 0) {
      helpers.error(res, 400, "path required");
      return;
    }
    if (typeof body.enabled !== "boolean") {
      helpers.error(res, 400, "enabled boolean required");
      return;
    }

    try {
      await setPiResourceEnabled({
        cwd: resolveResourceCwd(typeof body.cwd === "string" ? body.cwd : undefined),
        type,
        path: body.path,
        enabled: body.enabled,
      });
      helpers.json(res, { ok: true });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Failed to update Pi resource settings";
      helpers.error(res, message.includes("not found") ? 404 : 400, message);
    }
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
      await handleListSkills(url, res);
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

    if (path === "/pi/resources/enabled" && method === "POST") {
      await handleSetPiResourceEnabled(req, res);
      return true;
    }

    // Skill detail + file access
    const skillFileMatch = path.match(/^\/skills\/([^/]+)\/file$/);
    if (skillFileMatch && method === "GET") {
      await handleGetSkillFile(skillFileMatch[1], url, res);
      return true;
    }

    const skillDetailMatch = path.match(/^\/skills\/([^/]+)$/);
    if (skillDetailMatch && method === "GET") {
      await handleGetSkillDetail(skillDetailMatch[1], url, res);
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
