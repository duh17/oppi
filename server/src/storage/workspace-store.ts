import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { generateId } from "../id.js";
import type {
  CreateWorkspaceRequest,
  UpdateWorkspaceRequest,
  Workspace,
  WorkspaceSystemPromptMode,
} from "../types.js";
import type { ConfigStore } from "./config-store.js";

function normalizeExtensions(extensions: string[] | undefined): string[] | undefined {
  if (!extensions) {
    return undefined;
  }

  const unique = new Set<string>();
  const normalized: string[] = [];

  for (const value of extensions) {
    const name = value.trim();
    if (name.length === 0 || unique.has(name)) {
      continue;
    }

    unique.add(name);
    normalized.push(name);
  }

  return normalized;
}

function normalizeOptionalString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function normalizeSystemPromptMode(value: unknown): WorkspaceSystemPromptMode {
  return value === "replace" ? "replace" : "append";
}

export class WorkspaceStore {
  constructor(private readonly configStore: ConfigStore) {}

  private getWorkspacePath(workspaceId: string): string {
    return join(this.configStore.getWorkspacesDir(), `${workspaceId}.json`);
  }

  createWorkspace(req: CreateWorkspaceRequest): Workspace {
    const id = generateId(8);
    const now = Date.now();

    const workspace: Workspace = {
      id,
      name: req.name,
      description: normalizeOptionalString(req.description),
      icon: normalizeOptionalString(req.icon),
      skills: req.skills,
      allowedPaths: req.allowedPaths,
      allowedExecutables: req.allowedExecutables,
      systemPrompt: normalizeOptionalString(req.systemPrompt),
      systemPromptMode: normalizeSystemPromptMode(req.systemPromptMode),
      hostMount: normalizeOptionalString(req.hostMount),
      extensions: normalizeExtensions(req.extensions),
      defaultModel: normalizeOptionalString(req.defaultModel),
      gitStatusEnabled: req.gitStatusEnabled,
      runtime: req.runtime,
      sandboxConfig: req.sandboxConfig,
      createdAt: now,
      updatedAt: now,
    };

    this.saveWorkspace(workspace);
    return workspace;
  }

  saveWorkspace(workspace: Workspace): void {
    const sanitized = this.sanitizeWorkspace(workspace);
    const path = this.getWorkspacePath(sanitized.id);
    const dir = dirname(path);

    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true, mode: 0o700 });
    }

    writeFileSync(path, JSON.stringify(sanitized, null, 2), { mode: 0o600 });
  }

  private sanitizeWorkspace(raw: Workspace | Record<string, unknown>): Workspace {
    const workspace: Workspace = {
      id: typeof raw.id === "string" ? raw.id : "unknown",
      name: typeof raw.name === "string" ? raw.name : "",
      description: normalizeOptionalString(raw.description),
      icon: normalizeOptionalString(raw.icon),
      skills: Array.isArray(raw.skills)
        ? raw.skills.filter((skill): skill is string => typeof skill === "string")
        : [],
      allowedPaths: Array.isArray(raw.allowedPaths)
        ? (raw.allowedPaths as Workspace["allowedPaths"])
        : undefined,
      allowedExecutables: Array.isArray(raw.allowedExecutables)
        ? (raw.allowedExecutables as string[])
        : undefined,
      systemPrompt: normalizeOptionalString(raw.systemPrompt),
      systemPromptMode: normalizeSystemPromptMode(raw.systemPromptMode),
      hostMount: normalizeOptionalString(raw.hostMount),
      extensions: normalizeExtensions(raw.extensions as string[] | undefined),
      defaultModel: normalizeOptionalString(raw.defaultModel),
      lastUsedModel: typeof raw.lastUsedModel === "string" ? raw.lastUsedModel : undefined,
      gitStatusEnabled:
        typeof raw.gitStatusEnabled === "boolean" ? raw.gitStatusEnabled : undefined,
      runtime: raw.runtime === "host" || raw.runtime === "sandbox" ? raw.runtime : undefined,
      sandboxConfig:
        raw.sandboxConfig && typeof raw.sandboxConfig === "object"
          ? (raw.sandboxConfig as Workspace["sandboxConfig"])
          : undefined,
      createdAt: typeof raw.createdAt === "number" ? raw.createdAt : Date.now(),
      updatedAt: typeof raw.updatedAt === "number" ? raw.updatedAt : Date.now(),
    };

    return workspace;
  }

  getWorkspace(workspaceId: string): Workspace | undefined {
    const path = this.getWorkspacePath(workspaceId);
    if (!existsSync(path)) {
      return undefined;
    }

    try {
      const workspace = JSON.parse(readFileSync(path, "utf-8")) as Record<string, unknown>;
      return this.sanitizeWorkspace(workspace);
    } catch {
      return undefined;
    }
  }

  listWorkspaces(): Workspace[] {
    const dir = this.configStore.getWorkspacesDir();
    if (!existsSync(dir)) {
      return [];
    }

    const workspaces: Workspace[] = [];

    for (const file of readdirSync(dir)) {
      if (!file.endsWith(".json")) {
        continue;
      }

      const path = join(dir, file);
      try {
        const workspace = JSON.parse(readFileSync(path, "utf-8")) as Record<string, unknown>;
        workspaces.push(this.sanitizeWorkspace(workspace));
      } catch (err) {
        console.error(`[storage] Corrupt workspace file ${path}, skipping:`, err);
      }
    }

    return workspaces.sort((a, b) => a.createdAt - b.createdAt);
  }

  updateWorkspace(workspaceId: string, updates: UpdateWorkspaceRequest): Workspace | undefined {
    const workspace = this.getWorkspace(workspaceId);
    if (!workspace) {
      return undefined;
    }

    if (updates.name !== undefined) workspace.name = updates.name;
    if (updates.description !== undefined)
      workspace.description = normalizeOptionalString(updates.description);
    if (updates.icon !== undefined) workspace.icon = normalizeOptionalString(updates.icon);
    if (updates.skills !== undefined) workspace.skills = updates.skills;
    if (updates.allowedPaths !== undefined) workspace.allowedPaths = updates.allowedPaths;
    if (updates.allowedExecutables !== undefined)
      workspace.allowedExecutables = updates.allowedExecutables;
    if (updates.systemPrompt !== undefined)
      workspace.systemPrompt = normalizeOptionalString(updates.systemPrompt);
    if (updates.systemPromptMode !== undefined)
      workspace.systemPromptMode = normalizeSystemPromptMode(updates.systemPromptMode);
    if (updates.hostMount !== undefined)
      workspace.hostMount = normalizeOptionalString(updates.hostMount);
    if (updates.extensions !== undefined)
      workspace.extensions = normalizeExtensions(updates.extensions);
    if (updates.defaultModel !== undefined)
      workspace.defaultModel = normalizeOptionalString(updates.defaultModel);
    if (updates.gitStatusEnabled !== undefined)
      workspace.gitStatusEnabled = updates.gitStatusEnabled;
    if (updates.runtime !== undefined) workspace.runtime = updates.runtime;
    if (updates.sandboxConfig !== undefined)
      workspace.sandboxConfig = updates.sandboxConfig ?? undefined;

    workspace.updatedAt = Date.now();

    this.saveWorkspace(workspace);
    return workspace;
  }

  deleteWorkspace(workspaceId: string): boolean {
    const path = this.getWorkspacePath(workspaceId);
    if (!existsSync(path)) {
      return false;
    }

    rmSync(path);
    return true;
  }

  ensureDefaultWorkspaces(): void {
    if (this.listWorkspaces().length > 0) {
      return;
    }

    this.createWorkspace({
      name: "general",
      description: "General-purpose agent with web search and browsing",
      icon: "terminal",
      skills: ["search", "web-fetch", "web-browser"],
    });

    this.createWorkspace({
      name: "research",
      description: "Deep research with search, web, and transcription",
      icon: "magnifyingglass",
      skills: ["search", "web-fetch", "web-browser", "deep-research", "youtube-transcript"],
    });
  }
}
