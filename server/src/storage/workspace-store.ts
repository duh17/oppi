import { randomUUID } from "node:crypto";
import {
  closeSync,
  existsSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  rmdirSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join } from "node:path";

import { generateId } from "../id.js";
import { DEFAULT_ICON_CHOICE, migrateIconChoice, validateIconChoice } from "../icon-choice.js";
import { createLogger } from "../logger.js";
import { safeErrorMessage } from "../log-utils.js";
import { hostFolderClaimsHome, resolveHostPath } from "../host.js";
import { ensureOwnerOnlyRealDirectory } from "../owner-directory.js";
import type {
  CreateWorkspaceRequest,
  UpdateWorkspaceRequest,
  Workspace,
  WorkspaceSandboxConfig,
  WorkspaceSystemPromptMode,
} from "../types.js";
import { defaultHostWorkspaceFolder, defaultSandboxHostMount } from "../workspace-folder.js";
import type { ConfigStore } from "./config-store.js";

const log = createLogger({ base: { component: "workspace_store" } });

export type WorkspaceMigrationFaultPhase =
  "after_temp_write" | "after_temp_fsync" | "before_rename" | "after_rename";

export interface WorkspaceStoreOptions {
  /** Deterministic fault seam for startup migration recovery tests. */
  faultInjector?: (phase: WorkspaceMigrationFaultPhase) => void;
  /** Test seam: runs after a default folder was found free and before it is created. */
  beforeFolderCreate?: (path: string) => void;
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

  if (Array.isArray(obj.mcpServers)) {
    // Pi server names: letters, digits, `_` and `-`.
    const names = obj.mcpServers.filter(
      (name): name is string => typeof name === "string" && /^[A-Za-z0-9_-]+$/.test(name),
    );
    if (names.length > 0) result.mcpServers = [...new Set(names)];
  }

  return result.allowedHosts || result.env || result.mcpServers ? result : undefined;
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
    const runtime = req.runtime === "sandbox" ? "sandbox" : "host";
    assertHostFolderDoesNotClaimHome(normalizeHostMount(req.hostMount), runtime);
    const folder = this.chooseHostMount(req.hostMount, { id, name: req.name, runtime });

    const workspace: Workspace = {
      id,
      name: req.name,
      description: normalizeOptionalString(req.description),
      icon: this.validateWorkspaceIcon(req.icon),
      systemPrompt: normalizeOptionalString(req.systemPrompt),
      systemPromptMode: normalizeSystemPromptMode(req.systemPromptMode),
      hostMount: folder.hostMount,
      tools: normalizeTools(req.tools),
      gitStatusEnabled: req.gitStatusEnabled,
      runtime,
      sandboxConfig: normalizeSandboxConfig(req.sandboxConfig),
      createdAt: now,
      updatedAt: now,
    };

    try {
      return this.saveWorkspace(workspace);
    } catch (error) {
      folder.undo?.();
      throw error;
    }
  }

  saveWorkspace(workspace: Workspace): Workspace {
    const sanitized = this.sanitizeWorkspace(workspace);
    this.writeWorkspaceFile(sanitized);
    return sanitized;
  }

  private writeWorkspaceFile(workspace: Workspace): void {
    const path = this.getWorkspacePath(workspace.id);
    const dir = dirname(path);

    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true, mode: 0o700 });
    }

    writeFileSync(path, JSON.stringify(workspace, null, 2), { mode: 0o600 });
  }

  /** Normalizes a stored record. Every stored record has its folder and runtime by now. */
  private sanitizeWorkspace(raw: Workspace | Record<string, unknown>): Workspace {
    const id = typeof raw.id === "string" ? raw.id : "unknown";
    const hostMount = normalizeHostMount(raw.hostMount);
    if (!hostMount) {
      throw new Error(
        `Workspace ${id} has no folder yet: start the Oppi server once to migrate it`,
      );
    }

    return {
      id,
      name: typeof raw.name === "string" ? raw.name : "",
      description: normalizeOptionalString(raw.description),
      icon: migrateIconChoice(raw.icon),
      systemPrompt: normalizeOptionalString(raw.systemPrompt),
      systemPromptMode: normalizeSystemPromptMode(raw.systemPromptMode),
      hostMount,
      tools: normalizeTools(raw.tools as string[] | undefined),
      gitStatusEnabled:
        typeof raw.gitStatusEnabled === "boolean" ? raw.gitStatusEnabled : undefined,
      runtime: raw.runtime === "sandbox" ? "sandbox" : "host",
      sandboxConfig: normalizeSandboxConfig(raw.sandboxConfig),
      createdAt: typeof raw.createdAt === "number" ? raw.createdAt : Date.now(),
      updatedAt: typeof raw.updatedAt === "number" ? raw.updatedAt : Date.now(),
    };
  }

  /**
   * The folder to store for a create or update: the owner's choice, else Oppi's default
   * (`~/sandbox/<slug>` for a sandbox, which appears at session start; `<dataDir>/workspaces/<slug>`
   * for host, created here). Never `~` itself: longest-prefix cwd matching would let such a
   * workspace claim every session under home.
   *
   * A host default is only ever a folder this call created: the mkdir is exclusive, and a path
   * that exists (a leftover, a planted symlink or directory, a race) is taken, never adopted.
   * The one exception is the folder `current` already stores for this workspace, which is reused
   * after an `lstat` that refuses a symlink. So a deleted workspace's leftover folder is never
   * handed to the next same-named workspace and two records never share a directory. `undo`
   * removes a folder this call created if the write that stores it fails.
   */
  private chooseHostMount(
    requested: unknown,
    workspace: Pick<Workspace, "id" | "name" | "runtime">,
    current?: string,
  ): { hostMount: string; undo?: () => void } {
    const chosen = normalizeHostMount(requested);
    if (chosen) {
      return { hostMount: chosen };
    }
    if (workspace.runtime === "sandbox") {
      return { hostMount: defaultSandboxHostMount(workspace) };
    }

    const workspacesDir = this.configStore.getWorkspacesDir();
    mkdirSync(workspacesDir, { recursive: true, mode: 0o700 });
    const owned = this.ownedHostFolders(workspace.id);
    const own = current ? resolveHostPath(current) : undefined;
    let created = false;
    const hostMount = defaultHostWorkspaceFolder(workspacesDir, workspace, (path) => {
      if (owned.has(path)) return false;
      if (path === own && pathEntryExists(path)) {
        ensureOwnerOnlyRealDirectory(path, `Workspace folder is not a real directory: ${path}`);
        return true;
      }
      if (path !== own && pathEntryExists(path)) return false;
      this.options.beforeFolderCreate?.(path);
      try {
        mkdirSync(path, { mode: 0o700 });
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "EEXIST") return false;
        throw error;
      }
      created = true;
      return true;
    });
    return {
      hostMount,
      undo: created
        ? () => {
            try {
              rmdirSync(hostMount);
            } catch {
              // Not empty or already gone: nothing of ours to remove.
            }
          }
        : undefined,
    };
  }

  /** Resolved folders other workspaces already store. */
  private ownedHostFolders(exceptWorkspaceId: string): Set<string> {
    const owned = new Set<string>();
    for (const { raw } of this.readWorkspaceRecords()) {
      const hostMount = normalizeHostMount(raw.hostMount);
      if (hostMount && raw.id !== exceptWorkspaceId) {
        owned.add(resolveHostPath(hostMount));
      }
    }
    return owned;
  }

  /**
   * Readable workspace records. A record is a JSON object whose non-empty string `id` matches
   * its `<id>.json` filename (the name `getWorkspacePath` gives it); anything else is never read
   * as a workspace and never written. Unreadable or malformed files are passed to `onSkipped`.
   */
  private readWorkspaceRecords(
    onSkipped?: (path: string, reason: string, error?: unknown) => void,
  ): Array<{ path: string; raw: Record<string, unknown> }> {
    const dir = this.configStore.getWorkspacesDir();
    if (!existsSync(dir)) {
      return [];
    }
    const records: Array<{ path: string; raw: Record<string, unknown> }> = [];
    for (const file of readdirSync(dir)) {
      if (!file.endsWith(".json")) {
        continue;
      }
      const path = join(dir, file);
      let parsed: unknown;
      try {
        parsed = JSON.parse(readFileSync(path, "utf-8"));
      } catch (error) {
        onSkipped?.(path, "parse_failed", error);
        continue;
      }
      if (!isStoredWorkspaceRecord(parsed, file)) {
        onSkipped?.(path, "invalid_workspace_shape");
        continue;
      }
      records.push({ path, raw: parsed });
    }
    return records;
  }

  private readWorkspaceRecord(workspaceId: string): Record<string, unknown> | undefined {
    const path = this.getWorkspacePath(workspaceId);
    try {
      const parsed: unknown = JSON.parse(readFileSync(path, "utf-8"));
      return isStoredWorkspaceRecord(parsed, basename(path)) ? parsed : undefined;
    } catch {
      return undefined;
    }
  }

  /**
   * Gives older records a folder (and `runtime`, "host" when missing). Only the server process
   * calls this, once at startup before it serves, so nothing else is writing these records.
   * Oldest record first (createdAt, then id), so same-named workspaces always split the same way;
   * each record is re-read as it is written; the first failure stops the routine, so no sibling
   * is assigned after a failed one and the plain slug can never go to a younger workspace.
   * `getWorkspace` and `listWorkspaces` never migrate: a record still lacking a folder makes
   * them throw, so an out-of-server reader cannot silently drop or rewrite it.
   */
  migrateMissingHostMounts(): void {
    const pending = this.readWorkspaceRecords()
      .filter(({ raw }) => needsHostMountFill(raw))
      .sort(
        (a, b) =>
          Number(a.raw.createdAt ?? 0) - Number(b.raw.createdAt ?? 0) ||
          String(a.raw.id).localeCompare(String(b.raw.id)),
      );
    for (const { path } of pending) {
      try {
        this.fillMissingFields(path);
      } catch (error) {
        throw new Error(
          `Workspace host-folder migration failed for ${path}: ${safeErrorMessage(error)}`,
          { cause: error },
        );
      }
    }
  }

  private fillMissingFields(path: string): void {
    let undo: (() => void) | undefined;
    try {
      replaceWorkspaceMigrationFile(
        path,
        (original) => {
          // Decided from the bytes about to be replaced, not from an earlier read.
          const parsed: unknown = JSON.parse(original.toString("utf-8"));
          if (!isStoredWorkspaceRecord(parsed, basename(path)) || !needsHostMountFill(parsed)) {
            return undefined;
          }
          const runtime = isRuntimeMode(parsed.runtime) ? parsed.runtime : "host";
          const filled: Record<string, unknown> = { runtime };
          if (!normalizeHostMount(parsed.hostMount)) {
            const folder = this.chooseHostMount(undefined, {
              id: String(parsed.id),
              name: typeof parsed.name === "string" ? parsed.name : "",
              runtime,
            });
            undo = folder.undo;
            filled.hostMount = folder.hostMount;
          }
          return Buffer.from(JSON.stringify({ ...parsed, ...filled }, null, 2));
        },
        this.options.faultInjector,
        "host-folder",
      );
    } catch (error) {
      undo?.();
      throw error;
    }
  }

  getWorkspace(workspaceId: string): Workspace | undefined {
    const raw = this.readWorkspaceRecord(workspaceId);
    return raw ? this.sanitizeWorkspace(raw) : undefined;
  }

  listWorkspaces(): Workspace[] {
    const records = this.readWorkspaceRecords((path, reason, error) => {
      log.error("workspace_store.workspace_file_parse.failed", {
        workspaceFilePath: path,
        reason,
        ...(error === undefined ? {} : { error: safeErrorMessage(error) }),
      });
    });
    return records
      .map(({ raw }) => this.sanitizeWorkspace(raw))
      .sort((a, b) => a.createdAt - b.createdAt);
  }

  updateWorkspace(workspaceId: string, updates: UpdateWorkspaceRequest): Workspace | undefined {
    const workspace = this.getWorkspace(workspaceId);
    if (!workspace) {
      return undefined;
    }
    const previousRuntime = workspace.runtime;

    if (updates.name !== undefined) workspace.name = updates.name;
    if (updates.description !== undefined)
      workspace.description = normalizeOptionalString(updates.description);
    if (updates.icon !== undefined) workspace.icon = this.validateWorkspaceIcon(updates.icon);
    if (updates.systemPrompt !== undefined)
      workspace.systemPrompt = normalizeOptionalString(updates.systemPrompt);
    if (updates.systemPromptMode !== undefined)
      workspace.systemPromptMode = normalizeSystemPromptMode(updates.systemPromptMode);
    if (updates.tools !== undefined) workspace.tools = normalizeTools(updates.tools);
    if (updates.gitStatusEnabled !== undefined)
      workspace.gitStatusEnabled = updates.gitStatusEnabled;
    if (updates.runtime !== undefined) workspace.runtime = updates.runtime;
    // Last, so clearing the folder picks the default for the runtime and name just applied.
    let undo: (() => void) | undefined;
    if (updates.hostMount !== undefined) {
      const folder = this.chooseHostMount(updates.hostMount, workspace, workspace.hostMount);
      workspace.hostMount = folder.hostMount;
      undo = folder.undo;
    }
    if (updates.sandboxConfig !== undefined)
      workspace.sandboxConfig =
        updates.sandboxConfig === null ? undefined : normalizeSandboxConfig(updates.sandboxConfig);

    workspace.updatedAt = Date.now();

    try {
      // Judge the folder that will be saved, when this update sets it or makes the workspace a
      // host workspace. An unrelated edit of a record an older Oppi stored at home is not blocked.
      if (
        updates.hostMount !== undefined ||
        (workspace.runtime === "host" && previousRuntime !== "host")
      ) {
        assertHostFolderDoesNotClaimHome(workspace.hostMount, workspace.runtime);
      }
      return this.saveWorkspace(workspace);
    } catch (error) {
      undo?.();
      throw error;
    }
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
        if (!isStoredWorkspaceRecord(raw, file)) {
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
          () => Buffer.from(JSON.stringify({ ...raw, icon: migratedIcon }, null, 2)),
          this.options.faultInjector,
          "icon",
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

function isRuntimeMode(value: unknown): value is Workspace["runtime"] {
  return value === "host" || value === "sandbox";
}

/**
 * A host workspace rooted at home, or above it, would claim every terminal and imported session
 * under home through longest-prefix cwd matching. Sandbox folders are never matched that way.
 */
function assertHostFolderDoesNotClaimHome(
  hostMount: string | undefined,
  runtime: Workspace["runtime"],
): void {
  if (runtime === "host" && hostMount && hostFolderClaimsHome(hostMount)) {
    throw new Error(
      `Host working directory cannot be your home folder or a folder above it (${resolveHostPath(hostMount)}): it would claim every session under home. Choose a project folder, or clear Host Working Directory to let Oppi create one.`,
    );
  }
}

function needsHostMountFill(raw: Record<string, unknown>): boolean {
  return !normalizeHostMount(raw.hostMount) || !isRuntimeMode(raw.runtime);
}

/** A stored record is a JSON object whose non-empty string id matches its `<id>.json` name. */
function isStoredWorkspaceRecord(
  value: unknown,
  file: string,
): value is Record<string, unknown> & { id: string } {
  return (
    isWorkspaceRecord(value) &&
    typeof value.id === "string" &&
    value.id.length > 0 &&
    file === `${value.id}.json`
  );
}

/** True for anything at the path, including a symlink (dangling or not). */
function pathEntryExists(path: string): boolean {
  try {
    lstatSync(path);
    return true;
  } catch {
    return false;
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

/**
 * Atomically replaces a record with the bytes `build` makes from what is on disk right now;
 * `build` returning undefined leaves the record untouched. `label` names the migration in a
 * failed-rollback error.
 */
function replaceWorkspaceMigrationFile(
  path: string,
  build: (original: Buffer) => Buffer | undefined,
  faultInjector: ((phase: WorkspaceMigrationFaultPhase) => void) | undefined,
  label: string,
): void {
  const directory = dirname(path);
  const original = readFileSync(path);
  const bytes = build(original);
  if (!bytes) return;
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
          `Workspace ${label} migration failed and its original could not be restored`,
          { cause: rollbackError },
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
