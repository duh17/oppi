import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { generateId } from "../id.js";
import type { CreateWorkspaceRequest, UpdateWorkspaceRequest, Workspace } from "../types.js";
import type { ConfigStore } from "./config-store.js";

function normalizeExtensionList(extensions: string[] | undefined): string[] | undefined {
  if (!extensions) return undefined;

  const unique = new Set<string>();
  const out: string[] = [];

  for (const raw of extensions) {
    const trimmed = raw.trim();
    if (trimmed.length === 0) continue;
    if (unique.has(trimmed)) continue;
    unique.add(trimmed);
    out.push(trimmed);
  }

  return out;
}

export class WorkspaceStore {
  constructor(private readonly configStore: ConfigStore) {}

  private getWorkspacePath(workspaceId: string): string {
    return join(this.configStore.getWorkspacesDir(), `${workspaceId}.json`);
  }

  createWorkspace(req: CreateWorkspaceRequest): Workspace {
    const id = generateId(8);
    const now = Date.now();

    const extensions = normalizeExtensionList(req.extensions);

    const workspace: Workspace = {
      id,
      name: req.name,
      description: req.description,
      icon: req.icon,
      skills: req.skills,
      systemPrompt: req.systemPrompt,
      hostMount: req.hostMount,
      memoryEnabled: req.memoryEnabled,
      memoryNamespace: req.memoryEnabled ? req.memoryNamespace || `ws-${id}` : req.memoryNamespace,
      extensions,
      defaultModel: req.defaultModel,
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

    const payload = JSON.stringify(sanitized, null, 2);
    writeFileSync(path, payload, { mode: 0o600 });
  }

  private sanitizeWorkspace(raw: Workspace | Record<string, unknown>): Workspace {
    const workspaceId = typeof raw.id === "string" ? raw.id : "unknown";

    const workspace: Workspace = {
      id: workspaceId,
      name: typeof raw.name === "string" ? raw.name : "",
      description: typeof raw.description === "string" ? raw.description : undefined,
      icon: typeof raw.icon === "string" ? raw.icon : undefined,
      skills: Array.isArray(raw.skills)
        ? raw.skills.filter((skill): skill is string => typeof skill === "string")
        : [],
      allowedPaths: Array.isArray(raw.allowedPaths)
        ? (raw.allowedPaths as Workspace["allowedPaths"])
        : undefined,
      allowedExecutables: Array.isArray(raw.allowedExecutables)
        ? (raw.allowedExecutables as string[])
        : undefined,
      systemPrompt: typeof raw.systemPrompt === "string" ? raw.systemPrompt : undefined,
      hostMount: typeof raw.hostMount === "string" ? raw.hostMount : undefined,
      memoryEnabled: typeof raw.memoryEnabled === "boolean" ? raw.memoryEnabled : undefined,
      memoryNamespace: typeof raw.memoryNamespace === "string" ? raw.memoryNamespace : undefined,
      extensions: normalizeExtensionList(raw.extensions as string[] | undefined),
      defaultModel: typeof raw.defaultModel === "string" ? raw.defaultModel : undefined,
      lastUsedModel: typeof raw.lastUsedModel === "string" ? raw.lastUsedModel : undefined,
      createdAt: typeof raw.createdAt === "number" ? raw.createdAt : Date.now(),
      updatedAt: typeof raw.updatedAt === "number" ? raw.updatedAt : Date.now(),
    };

    if (
      workspace.memoryEnabled &&
      (!workspace.memoryNamespace || workspace.memoryNamespace.trim().length === 0)
    ) {
      workspace.memoryNamespace = `ws-${workspace.id}`;
    }

    return workspace;
  }

  getWorkspace(workspaceId: string): Workspace | undefined {
    const path = this.getWorkspacePath(workspaceId);
    if (!existsSync(path)) return undefined;

    try {
      const ws = JSON.parse(readFileSync(path, "utf-8")) as Record<string, unknown>;
      return this.sanitizeWorkspace(ws);
    } catch {
      return undefined;
    }
  }

  listWorkspaces(): Workspace[] {
    const dir = this.configStore.getWorkspacesDir();
    if (!existsSync(dir)) return [];

    const workspaces: Workspace[] = [];

    for (const file of readdirSync(dir)) {
      if (!file.endsWith(".json")) continue;
      try {
        const ws = JSON.parse(readFileSync(join(dir, file), "utf-8")) as Record<string, unknown>;
        workspaces.push(this.sanitizeWorkspace(ws));
      } catch (err) {
        console.error(`[storage] Corrupt workspace file ${join(dir, file)}, skipping:`, err);
      }
    }

    return workspaces.sort((a, b) => a.createdAt - b.createdAt);
  }

  updateWorkspace(workspaceId: string, updates: UpdateWorkspaceRequest): Workspace | undefined {
    const workspace = this.getWorkspace(workspaceId);
    if (!workspace) return undefined;

    if (updates.name !== undefined) workspace.name = updates.name;
    if (updates.description !== undefined) workspace.description = updates.description;
    if (updates.icon !== undefined) workspace.icon = updates.icon;
    if (updates.skills !== undefined) workspace.skills = updates.skills;
    if (updates.systemPrompt !== undefined) workspace.systemPrompt = updates.systemPrompt;
    if (updates.hostMount !== undefined) workspace.hostMount = updates.hostMount;
    if (updates.memoryEnabled !== undefined) workspace.memoryEnabled = updates.memoryEnabled;
    if (updates.memoryNamespace !== undefined) workspace.memoryNamespace = updates.memoryNamespace;
    if (updates.extensions !== undefined) {
      workspace.extensions = normalizeExtensionList(updates.extensions);
    }
    if (
      workspace.memoryEnabled &&
      (!workspace.memoryNamespace || workspace.memoryNamespace.trim().length === 0)
    ) {
      workspace.memoryNamespace = `ws-${workspace.id}`;
    }
    if (updates.defaultModel !== undefined) workspace.defaultModel = updates.defaultModel;
    if (updates.gitStatusEnabled !== undefined) {
      workspace.gitStatusEnabled = updates.gitStatusEnabled;
    }
    workspace.updatedAt = Date.now();

    this.saveWorkspace(workspace);
    return workspace;
  }

  deleteWorkspace(workspaceId: string): boolean {
    const path = this.getWorkspacePath(workspaceId);
    if (!existsSync(path)) return false;

    rmSync(path);
    return true;
  }

  /**
   * Ensure a user has at least one workspace. Seeds defaults if empty.
   */
  ensureDefaultWorkspaces(): void {
    const existing = this.listWorkspaces();
    if (existing.length > 0) return;

    this.createWorkspace({
      name: "general",
      description: "General-purpose agent with web search and browsing",
      icon: "terminal",
      skills: ["searxng", "fetch", "web-browser"],
      memoryEnabled: true,
      memoryNamespace: "general",
    });

    this.createWorkspace({
      name: "research",
      description: "Deep research with search, web, and transcription",
      icon: "magnifyingglass",
      skills: ["searxng", "fetch", "web-browser", "deep-research", "youtube-transcript"],
      memoryEnabled: true,
      memoryNamespace: "research",
    });
  }
}
