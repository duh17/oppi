import { randomUUID } from "node:crypto";
import {
  closeSync,
  existsSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join } from "node:path";

import { generateId } from "../id.js";
import { DEFAULT_ICON_CHOICE, migrateIconChoice, validateIconChoice } from "../icon-choice.js";
import { createLogger } from "../logger.js";
import { safeErrorMessage } from "../log-utils.js";
import type {
  CreateWorkspaceRequest,
  UpdateWorkspaceRequest,
  Workspace,
  WorkspaceSandboxConfig,
  WorkspaceSystemPromptMode,
} from "../types.js";
import type { ConfigStore } from "./config-store.js";

const log = createLogger({ base: { component: "workspace_store" } });

export type WorkspaceMigrationFaultPhase =
  | "after_temp_write"
  | "after_temp_fsync"
  | "before_rename"
  | "after_rename";

export interface WorkspaceStoreOptions {
  /** Deterministic fault seam for startup migration recovery tests. */
  faultInjector?: (phase: WorkspaceMigrationFaultPhase) => void;
}

function normalizeNameList(values: string[] | undefined): string[] | undefined {
  if (!values) {
    return undefined;
  }

  const unique = new Set<string>();
  const normalized: string[] = [];

  for (const value of values) {
    const name = value.trim();
    if (name.length === 0 || unique.has(name)) {
      continue;
    }

    unique.add(name);
    normalized.push(name);
  }

  return normalized;
}

function normalizeTools(tools: string[] | undefined): string[] | undefined {
  return normalizeNameList(tools);
}

function normalizeOptionalString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function normalizeHostMount(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }

  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function normalizeSandboxConfig(raw: unknown): WorkspaceSandboxConfig | undefined {
  if (!raw || typeof raw !== "object") {
    return undefined;
  }

  const obj = raw as Record<string, unknown>;
  const result: WorkspaceSandboxConfig = {};

  if (Array.isArray(obj.allowedHosts)) {
    result.allowedHosts = obj.allowedHosts.filter((h): h is string => typeof h === "string");
  }

  if (obj.env && typeof obj.env === "object" && !Array.isArray(obj.env)) {
    const filtered: Record<string, string> = {};
    for (const [key, value] of Object.entries(obj.env as Record<string, unknown>)) {
      if (typeof value === "string") {
        filtered[key] = value;
      }
    }
    if (Object.keys(filtered).length > 0) {
      result.env = filtered;
    }
  }

  return result.allowedHosts || result.env ? result : undefined;
}

function normalizeSystemPromptMode(_value: unknown): WorkspaceSystemPromptMode {
  // Workspace prompts are append-only in Oppi. Older persisted "replace"
  // values are accepted on read/write and normalized back to append.
  return "append";
}

export class WorkspaceStore {
  constructor(
    private readonly configStore: ConfigStore,
    private readonly iconAssetExists?: (assetId: string) => boolean,
    private readonly options: WorkspaceStoreOptions = {},
  ) {
    this.migrateStoredIconChoices();
  }

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
      icon: this.validateWorkspaceIcon(req.icon),
      systemPrompt: normalizeOptionalString(req.systemPrompt),
      systemPromptMode: normalizeSystemPromptMode(req.systemPromptMode),
      hostMount: normalizeHostMount(req.hostMount),
      defaultModel: normalizeOptionalString(req.defaultModel),
      tools: normalizeTools(req.tools),
      gitStatusEnabled: req.gitStatusEnabled,
      runtime: req.runtime,
      sandboxConfig: normalizeSandboxConfig(req.sandboxConfig),
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
      icon: migrateIconChoice(raw.icon),
      systemPrompt: normalizeOptionalString(raw.systemPrompt),
      systemPromptMode: normalizeSystemPromptMode(raw.systemPromptMode),
      hostMount: normalizeHostMount(raw.hostMount),
      defaultModel: normalizeOptionalString(raw.defaultModel),
      tools: normalizeTools(raw.tools as string[] | undefined),
      gitStatusEnabled:
        typeof raw.gitStatusEnabled === "boolean" ? raw.gitStatusEnabled : undefined,
      runtime: raw.runtime === "host" || raw.runtime === "sandbox" ? raw.runtime : undefined,
      sandboxConfig: normalizeSandboxConfig(raw.sandboxConfig),
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
      } catch (err: unknown) {
        log.error("workspace_store.workspace_file_parse.failed", {
          workspaceFilePath: path,
          error: safeErrorMessage(err),
        });
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
    if (updates.icon !== undefined) workspace.icon = this.validateWorkspaceIcon(updates.icon);
    if (updates.systemPrompt !== undefined)
      workspace.systemPrompt = normalizeOptionalString(updates.systemPrompt);
    if (updates.systemPromptMode !== undefined)
      workspace.systemPromptMode = normalizeSystemPromptMode(updates.systemPromptMode);
    if (updates.hostMount !== undefined)
      workspace.hostMount = normalizeHostMount(updates.hostMount);
    if (updates.defaultModel !== undefined)
      workspace.defaultModel = normalizeOptionalString(updates.defaultModel);
    if (updates.tools !== undefined) workspace.tools = normalizeTools(updates.tools);
    if (updates.gitStatusEnabled !== undefined)
      workspace.gitStatusEnabled = updates.gitStatusEnabled;
    if (updates.runtime !== undefined) workspace.runtime = updates.runtime;
    if (updates.sandboxConfig !== undefined)
      workspace.sandboxConfig =
        updates.sandboxConfig === null ? undefined : normalizeSandboxConfig(updates.sandboxConfig);

    workspace.updatedAt = Date.now();

    this.saveWorkspace(workspace);
    return workspace;
  }

  private validateWorkspaceIcon(value: unknown): Workspace["icon"] {
    if (value === undefined) return DEFAULT_ICON_CHOICE;
    return validateIconChoice(value, { assetExists: this.iconAssetExists });
  }

  private migrateStoredIconChoices(): void {
    const dir = this.configStore.getWorkspacesDir();
    if (!existsSync(dir)) return;
    for (const file of readdirSync(dir)) {
      if (!file.endsWith(".json")) continue;
      const path = join(dir, file);
      try {
        const raw = JSON.parse(readFileSync(path, "utf8")) as unknown;
        if (!isWorkspaceRecord(raw)) {
          log.error("workspace_store.icon_migration.invalid_workspace_shape", {
            workspaceFilePath: path,
            topLevelType: workspaceTopLevelType(raw),
          });
          continue;
        }
        const migratedIcon = migrateIconChoice(raw.icon);
        if (JSON.stringify(raw.icon) === JSON.stringify(migratedIcon)) continue;
        replaceWorkspaceMigrationFile(
          path,
          Buffer.from(JSON.stringify({ ...raw, icon: migratedIcon }, null, 2)),
          this.options.faultInjector,
        );
      } catch (err: unknown) {
        log.error("workspace_store.icon_migration.failed", {
          workspaceFilePath: path,
          error: safeErrorMessage(err),
        });
      }
    }
  }

  deleteWorkspace(workspaceId: string): boolean {
    const path = this.getWorkspacePath(workspaceId);
    if (!existsSync(path)) {
      return false;
    }

    rmSync(path);
    return true;
  }
}

function isWorkspaceRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function workspaceTopLevelType(value: unknown): string {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  return typeof value;
}

function replaceWorkspaceMigrationFile(
  path: string,
  bytes: Buffer,
  faultInjector?: (phase: WorkspaceMigrationFaultPhase) => void,
): void {
  const directory = dirname(path);
  const original = readFileSync(path);
  const temporaryPath = join(directory, `.${basename(path)}.${process.pid}.${randomUUID()}.tmp`);
  let descriptor: number | undefined;
  let renamed = false;

  try {
    descriptor = openSync(temporaryPath, "wx", 0o600);
    writeFileSync(descriptor, bytes);
    faultInjector?.("after_temp_write");
    fsyncSync(descriptor);
    faultInjector?.("after_temp_fsync");
    closeSync(descriptor);
    descriptor = undefined;

    faultInjector?.("before_rename");
    renameSync(temporaryPath, path);
    renamed = true;
    faultInjector?.("after_rename");
    syncWorkspaceDirectory(directory);
  } catch (error) {
    if (renamed) {
      try {
        restoreWorkspaceMigrationFile(path, original);
      } catch (rollbackError) {
        throw new AggregateError(
          [error, rollbackError],
          "Workspace icon migration failed and its original could not be restored",
        );
      }
    }
    throw error;
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
    // This exact random path is owned by this migration attempt. Never scan or
    // remove another process's temporary files here.
    rmSync(temporaryPath, { force: true });
  }
}

function restoreWorkspaceMigrationFile(path: string, bytes: Buffer): void {
  const directory = dirname(path);
  const temporaryPath = join(directory, `.${basename(path)}.${process.pid}.${randomUUID()}.tmp`);
  let descriptor: number | undefined;
  try {
    descriptor = openSync(temporaryPath, "wx", 0o600);
    writeFileSync(descriptor, bytes);
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    renameSync(temporaryPath, path);
    syncWorkspaceDirectory(directory);
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
    rmSync(temporaryPath, { force: true });
  }
}

function syncWorkspaceDirectory(directory: string): void {
  const descriptor = openSync(directory, "r");
  try {
    fsyncSync(descriptor);
  } finally {
    closeSync(descriptor);
  }
}
