import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";

import { generateId } from "./id.js";
import { DEFAULT_ICON_CHOICE, migrateIconChoice, validateIconChoice } from "./icon-choice.js";
import { openDatabase, type SqliteDatabase } from "./sqlite-compat.js";
import { isThinkingLevel } from "./thinking-levels.js";
import type { AgentDefinition } from "./agent-launch-service.js";
import {
  DEFAULT_AGENT_DEFAULT_NAME,
  DEFAULT_AGENT_ID,
  DEFAULT_AGENT_DEFINITION,
  applyDefaultAgentSafetyDefaults,
  assertDefaultAgentCustomizationPatch,
  isDefaultAgentId,
  isDefaultAgentReference,
  isDefaultAgentReservedName,
} from "./default-agent.js";

export type AgentDefinitionStatus = "active" | "archived";

export interface StoredAgentDefinition {
  id: string;
  name: string;
  status: AgentDefinitionStatus;
  version: number;
  definition: AgentDefinition;
  createdAt: number;
  updatedAt: number;
  archivedAt?: number;
}

export interface AgentDefinitionSummary {
  id: string;
  name: string;
  icon: NonNullable<AgentDefinition["icon"]>;
  description?: string;
  launchConstraints?: AgentDefinition["launchConstraints"];
  status: AgentDefinitionStatus;
  version: number;
  createdAt: number;
  updatedAt: number;
  archivedAt?: number;
}

export interface StoredAgentDefinitionVersion {
  id: string;
  version: number;
  definition: AgentDefinition;
  createdAt: number;
}

export const AGENT_VERSION_CONFLICT_CODE = "AGENT_VERSION_CONFLICT";

export class AgentVersionConflictError extends Error {
  readonly code = AGENT_VERSION_CONFLICT_CODE;

  constructor(
    readonly expectedVersion: number | undefined,
    readonly currentVersion: number,
  ) {
    super(
      expectedVersion === undefined
        ? `Agent update conflicted with current version ${currentVersion}`
        : `Agent version conflict: expected ${expectedVersion}, current ${currentVersion}`,
    );
    this.name = "AgentVersionConflictError";
  }
}

interface AgentRow {
  id: string;
  name: string;
  status: AgentDefinitionStatus;
  version: number;
  definition_json: string;
  created_at: number;
  updated_at: number;
  archived_at: number | null;
}

interface AgentVersionRow {
  id: string;
  version: number;
  definition_json: string;
  created_at: number;
}

const INSTRUCTION_MODES = new Set(["append", "replace"]);
const NO_TOOLS_VALUES = new Set(["all", "builtin"]);
const FORBIDDEN_AGENT_DEFINITION_KEYS = new Set([
  "target",
  "workspaceId",
  "worktreeId",
  "cwd",
  "schedule",
  "attachments",
  "images",
]);
const AGENT_DEFINITION_KEYS = new Set([
  "name",
  "icon",
  "description",
  "instructions",
  "resources",
  "sessionDefaults",
  "launchConstraints",
]);
const INSTRUCTION_KEYS = new Set(["mode", "text"]);
const RESOURCE_KEYS = new Set(["agentsFiles", "noContextFiles", "skillPaths", "extensionIds"]);
const AGENTS_FILE_KEYS = new Set(["path", "content"]);
const SESSION_DEFAULT_KEYS = new Set([
  "model",
  "thinkingLevel",
  "tools",
  "excludeTools",
  "noTools",
]);
const LAUNCH_CONSTRAINT_KEYS = new Set(["allowedWorkspaceIds", "requiredRuntime"]);
const MAX_UNVERSIONED_AGENT_UPDATE_ATTEMPTS = 3;
export class AgentDefinitionStore {
  private readonly db: SqliteDatabase;

  constructor(
    dataDir: string,
    dbPath?: string,
    private readonly iconAssetExists?: (assetId: string) => boolean,
  ) {
    if (!existsSync(dataDir)) {
      mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    }
    const resolvedDbPath = resolve(dbPath ?? join(dataDir, "session-state.db"));
    this.db = openDatabase(resolvedDbPath);
    chmodSync(resolvedDbPath, 0o600);
    this.db.exec("PRAGMA journal_mode = WAL");
    this.db.exec("PRAGMA synchronous = NORMAL");
    this.ensureSchema();
    this.migrateStoredIconChoices();
    this.ensureDefaultAgent();
  }

  close(): void {
    this.db.close();
  }

  createAgent(input: unknown, now = Date.now()): StoredAgentDefinition {
    const definition = validateAgentDefinition(input);
    this.assertIconAssetExists(definition);
    if (isDefaultAgentReservedName(definition.name)) {
      throw new Error(`${DEFAULT_AGENT_DEFAULT_NAME} is reserved for the default Agent identity`);
    }
    const agent: StoredAgentDefinition = {
      id: generateId(8),
      name: definition.name,
      status: "active",
      version: 1,
      definition,
      createdAt: now,
      updatedAt: now,
    };
    this.db.transaction(() => {
      this.db
        .prepare(
          `INSERT INTO agent_definitions
           (id, name, status, version, definition_json, created_at, updated_at, archived_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, NULL)`,
        )
        .run(
          agent.id,
          agent.name,
          agent.status,
          agent.version,
          JSON.stringify(agent.definition),
          agent.createdAt,
          agent.updatedAt,
        );
      this.insertAgentVersion(agent.id, agent.version, agent.definition, now);
    })();
    return agent;
  }

  updateAgent(
    agentId: string,
    patch: unknown,
    now = Date.now(),
    expectedVersion?: number,
  ): StoredAgentDefinition | undefined {
    if (!isRecord(patch)) throw new Error("Agent update must be an object");
    if (Object.keys(patch).length === 0) {
      throw new Error("Agent update must include at least one field");
    }

    let current = this.getAgent(agentId);
    if (!current || current.status === "archived") return undefined;
    const maxAttempts = expectedVersion === undefined ? MAX_UNVERSIONED_AGENT_UPDATE_ATTEMPTS : 1;

    for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
      const currentAgent = current;
      if (expectedVersion !== undefined && currentAgent.version !== expectedVersion) {
        throw new AgentVersionConflictError(expectedVersion, currentAgent.version);
      }
      if (!isDefaultAgentId(currentAgent.id) && wouldUseDefaultAgentReservedName(patch)) {
        throw new Error(`${DEFAULT_AGENT_DEFAULT_NAME} is reserved for the default Agent identity`);
      }
      if (isDefaultAgentId(currentAgent.id)) {
        assertDefaultAgentCustomizationPatch(patch);
      }
      const mergedDefinition = validateAgentDefinitionUpdate(currentAgent.definition, patch);
      const nextDefinition = isDefaultAgentId(currentAgent.id)
        ? applyDefaultAgentSafetyDefaults(mergedDefinition)
        : mergedDefinition;
      this.assertIconAssetExists(nextDefinition);
      const nextVersion = currentAgent.version + 1;
      let updated: StoredAgentDefinition | undefined;
      this.db.transaction(() => {
        // Keep the transaction's first database statement as the CAS write. A read
        // transaction that later upgrades to a write can deadlock against another
        // connection holding the same version snapshot.
        const result = this.db
          .prepare(
            `UPDATE agent_definitions
             SET name = ?, version = ?, definition_json = ?, updated_at = ?
             WHERE id = ? AND status <> 'archived' AND version = ?`,
          )
          .run(
            nextDefinition.name,
            nextVersion,
            JSON.stringify(nextDefinition),
            now,
            currentAgent.id,
            currentAgent.version,
          ) as { changes?: number };
        if (result.changes !== 1) return;
        this.insertAgentVersion(currentAgent.id, nextVersion, nextDefinition, now);
        updated = this.getAgent(currentAgent.id);
      })();
      if (updated) return updated;

      const latest = this.getAgent(currentAgent.id);
      if (!latest || latest.status === "archived") return undefined;
      if (expectedVersion !== undefined) {
        throw new AgentVersionConflictError(expectedVersion, latest.version);
      }
      current = latest;
    }

    const latest = this.getAgent(agentId);
    if (!latest || latest.status === "archived") return undefined;
    throw new AgentVersionConflictError(undefined, latest.version);
  }

  archiveAgent(agentId: string, now = Date.now()): StoredAgentDefinition | undefined {
    const current = this.getAgent(agentId);
    if (!current || isDefaultAgentId(current.id)) return undefined;
    this.db
      .prepare(
        `UPDATE agent_definitions
         SET status = 'archived', updated_at = ?, archived_at = ?
         WHERE id = ?`,
      )
      .run(now, now, current.id);
    return this.getAgent(current.id);
  }

  getAgent(agentId: string): StoredAgentDefinition | undefined {
    const row = this.db.prepare("SELECT * FROM agent_definitions WHERE id = ?").get(agentId) as
      | AgentRow
      | undefined;
    return row ? agentFromRow(row) : undefined;
  }

  resetDefaultAgent(now = Date.now()): StoredAgentDefinition {
    const current = this.getAgent(DEFAULT_AGENT_ID);
    if (!current) {
      this.ensureDefaultAgent(now);
      return this.getAgent(DEFAULT_AGENT_ID) as StoredAgentDefinition;
    }

    const nextVersion = current.version + 1;
    this.db.transaction(() => {
      this.db
        .prepare(
          `UPDATE agent_definitions
           SET name = ?, status = 'active', version = ?, definition_json = ?, updated_at = ?, archived_at = NULL
           WHERE id = ?`,
        )
        .run(
          DEFAULT_AGENT_DEFINITION.name,
          nextVersion,
          JSON.stringify(DEFAULT_AGENT_DEFINITION),
          now,
          DEFAULT_AGENT_ID,
        );
      this.insertAgentVersion(DEFAULT_AGENT_ID, nextVersion, DEFAULT_AGENT_DEFINITION, now);
    })();
    return this.getAgent(DEFAULT_AGENT_ID) as StoredAgentDefinition;
  }

  getAgentVersion(agentId: string, version: number): StoredAgentDefinitionVersion | undefined {
    if (!Number.isInteger(version) || version < 1) return undefined;
    const row = this.db
      .prepare("SELECT * FROM agent_definition_versions WHERE id = ? AND version = ?")
      .get(agentId, version) as AgentVersionRow | undefined;
    return row ? agentVersionFromRow(row) : undefined;
  }

  resolveAgent(reference: string): StoredAgentDefinition | undefined {
    const trimmed = reference.trim();
    if (!trimmed) return undefined;
    if (isDefaultAgentReference(trimmed)) {
      return this.getAgent(DEFAULT_AGENT_ID);
    }
    const direct = this.getAgent(trimmed);
    if (direct) return direct;
    const rows = this.db
      .prepare(
        `SELECT * FROM agent_definitions
         WHERE name = ? AND status <> 'archived'
         ORDER BY updated_at DESC, id ASC`,
      )
      .all(trimmed) as AgentRow[];
    return rows.length === 1 ? agentFromRow(rows[0]) : undefined;
  }

  listAgents(options: { includeArchived?: boolean } = {}): StoredAgentDefinition[] {
    const rows = (
      options.includeArchived
        ? this.db.prepare("SELECT * FROM agent_definitions ORDER BY updated_at DESC, id ASC").all()
        : this.db
            .prepare(
              "SELECT * FROM agent_definitions WHERE status <> 'archived' ORDER BY updated_at DESC, id ASC",
            )
            .all()
    ) as AgentRow[];
    return rows.map(agentFromRow);
  }

  listAgentSummaries(options: { includeArchived?: boolean } = {}): AgentDefinitionSummary[] {
    return this.listAgents(options).map(agentSummary);
  }

  listAgentVersions(): StoredAgentDefinitionVersion[] {
    const rows = this.db
      .prepare("SELECT * FROM agent_definition_versions ORDER BY id ASC, version ASC")
      .all() as AgentVersionRow[];
    return rows.map(agentVersionFromRow);
  }

  private migrateStoredIconChoices(): void {
    const currentRows = this.db.prepare("SELECT * FROM agent_definitions").all() as AgentRow[];
    const versionRows = this.db
      .prepare("SELECT * FROM agent_definition_versions")
      .all() as AgentVersionRow[];
    const updateCurrent = this.db.prepare(
      "UPDATE agent_definitions SET definition_json = ? WHERE id = ?",
    );
    const updateVersion = this.db.prepare(
      "UPDATE agent_definition_versions SET definition_json = ? WHERE id = ? AND version = ?",
    );

    this.db.transaction(() => {
      for (const row of currentRows) {
        const migrated = migrateStoredDefinitionJson(row.definition_json);
        if (migrated !== row.definition_json) updateCurrent.run(migrated, row.id);
      }
      for (const row of versionRows) {
        const migrated = migrateStoredDefinitionJson(row.definition_json);
        if (migrated !== row.definition_json) updateVersion.run(migrated, row.id, row.version);
      }
    })();
  }

  private assertIconAssetExists(definition: AgentDefinition): void {
    if (
      definition.icon?.kind === "genmoji" &&
      this.iconAssetExists &&
      !this.iconAssetExists(definition.icon.assetId)
    ) {
      throw new Error("icon asset not found");
    }
  }

  private ensureSchema(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS agent_definitions (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'active',
        version INTEGER NOT NULL DEFAULT 1,
        definition_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        archived_at INTEGER
      );
      CREATE UNIQUE INDEX IF NOT EXISTS agent_definitions_active_name_idx
        ON agent_definitions (name)
        WHERE archived_at IS NULL;
      CREATE INDEX IF NOT EXISTS agent_definitions_status_updated_idx
        ON agent_definitions (status, updated_at DESC);
      CREATE TABLE IF NOT EXISTS agent_definition_versions (
        id TEXT NOT NULL,
        version INTEGER NOT NULL,
        definition_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (id, version)
      );
      INSERT OR IGNORE INTO agent_definition_versions (id, version, definition_json, created_at)
        SELECT id, version, definition_json, updated_at FROM agent_definitions;
    `);
  }

  private ensureDefaultAgent(now = Date.now()): void {
    const existing = this.getAgent(DEFAULT_AGENT_ID);
    if (!existing) {
      this.db.transaction(() => {
        this.db
          .prepare(
            `INSERT INTO agent_definitions
             (id, name, status, version, definition_json, created_at, updated_at, archived_at)
             VALUES (?, ?, 'active', 1, ?, ?, ?, NULL)`,
          )
          .run(
            DEFAULT_AGENT_ID,
            DEFAULT_AGENT_DEFINITION.name,
            JSON.stringify(DEFAULT_AGENT_DEFINITION),
            now,
            now,
          );
        this.insertAgentVersion(DEFAULT_AGENT_ID, 1, DEFAULT_AGENT_DEFINITION, now);
      })();
      return;
    }

    const safeDefinition = applyDefaultAgentSafetyDefaults(existing.definition);
    const definitionChanged =
      JSON.stringify(safeDefinition) !== JSON.stringify(existing.definition);
    if (definitionChanged) {
      const nextVersion = existing.version + 1;
      this.db.transaction(() => {
        this.db
          .prepare(
            `UPDATE agent_definitions
             SET name = ?, status = 'active', version = ?, definition_json = ?, updated_at = ?, archived_at = NULL
             WHERE id = ?`,
          )
          .run(safeDefinition.name, nextVersion, JSON.stringify(safeDefinition), now, existing.id);
        this.insertAgentVersion(existing.id, nextVersion, safeDefinition, now);
      })();
      return;
    }

    this.db
      .prepare(
        `UPDATE agent_definitions
         SET name = ?, status = 'active', definition_json = ?, archived_at = NULL
         WHERE id = ?`,
      )
      .run(safeDefinition.name, JSON.stringify(safeDefinition), existing.id);
  }

  private insertAgentVersion(
    agentId: string,
    version: number,
    definition: AgentDefinition,
    createdAt: number,
  ): void {
    this.db
      .prepare(
        `INSERT INTO agent_definition_versions (id, version, definition_json, created_at)
         VALUES (?, ?, ?, ?)`,
      )
      .run(agentId, version, JSON.stringify(definition), createdAt);
  }
}

export function agentSummary(agent: StoredAgentDefinition): AgentDefinitionSummary {
  return {
    id: agent.id,
    name: agent.name,
    icon: agent.definition.icon ?? DEFAULT_ICON_CHOICE,
    ...(agent.definition.description ? { description: agent.definition.description } : {}),
    ...(agent.definition.launchConstraints
      ? { launchConstraints: agent.definition.launchConstraints }
      : {}),
    status: agent.status,
    version: agent.version,
    createdAt: agent.createdAt,
    updatedAt: agent.updatedAt,
    ...(agent.archivedAt !== undefined ? { archivedAt: agent.archivedAt } : {}),
  };
}

function agentFromRow(row: AgentRow): StoredAgentDefinition {
  const definition = JSON.parse(row.definition_json) as AgentDefinition;
  return {
    id: row.id,
    name: row.name,
    status: row.status,
    version: row.version,
    definition,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    ...(row.archived_at !== null ? { archivedAt: row.archived_at } : {}),
  };
}

function agentVersionFromRow(row: AgentVersionRow): StoredAgentDefinitionVersion {
  return {
    id: row.id,
    version: row.version,
    definition: JSON.parse(row.definition_json) as AgentDefinition,
    createdAt: row.created_at,
  };
}

export function validateAgentDefinition(input: unknown): AgentDefinition {
  if (!isRecord(input)) {
    throw new Error("Agent definition must be an object");
  }
  for (const key of Object.keys(input)) {
    if (FORBIDDEN_AGENT_DEFINITION_KEYS.has(key)) {
      throw new Error(`Agent definitions cannot include ${key}`);
    }
  }
  assertAllowedKeys(input, AGENT_DEFINITION_KEYS, "Agent definition");

  const name = requireString(input.name, "name");
  const icon = validateAgentIcon(input.icon);
  const description = validateString(input.description, "description");
  const instructions = validateInstructions(input.instructions);
  const resources = validateResources(input.resources);
  const sessionDefaults = validateSessionDefaults(input.sessionDefaults);
  const launchConstraints = validateLaunchConstraints(input.launchConstraints);

  return {
    name,
    icon,
    ...(description !== undefined ? { description } : {}),
    ...(instructions !== undefined ? { instructions } : {}),
    ...(resources !== undefined ? { resources } : {}),
    ...(sessionDefaults !== undefined ? { sessionDefaults } : {}),
    ...(launchConstraints !== undefined ? { launchConstraints } : {}),
  };
}

function validateAgentDefinitionUpdate(
  current: AgentDefinition,
  patch: Record<string, unknown>,
): AgentDefinition {
  return validateAgentDefinition(mergeAgentDefinition(current, patch));
}

function mergeAgentDefinition(current: AgentDefinition, patch: unknown): AgentDefinition {
  if (!isRecord(patch)) {
    throw new Error("Agent update must be an object");
  }

  const merged = {
    ...current,
    ...patch,
    ...(isRecord(patch.resources)
      ? { resources: { ...(current.resources ?? {}), ...patch.resources } }
      : {}),
    ...(isRecord(patch.sessionDefaults)
      ? { sessionDefaults: { ...(current.sessionDefaults ?? {}), ...patch.sessionDefaults } }
      : {}),
    ...(isRecord(patch.launchConstraints)
      ? {
          launchConstraints: {
            ...(current.launchConstraints ?? {}),
            ...patch.launchConstraints,
          },
        }
      : {}),
  } as Record<string, unknown>;

  removeNullValue(merged, "icon");
  removeNullValue(merged, "description");
  removeNullValue(merged, "instructions");
  removeNullValue(merged, "resources");
  removeNullValue(merged, "sessionDefaults");
  removeNullValue(merged, "launchConstraints");
  if (isRecord(merged.resources)) removeNullValues(merged.resources);
  if (isRecord(merged.sessionDefaults)) removeNullValues(merged.sessionDefaults);
  if (isRecord(merged.launchConstraints)) removeNullValues(merged.launchConstraints);

  return merged as unknown as AgentDefinition;
}

function wouldUseDefaultAgentReservedName(patch: unknown): boolean {
  return (
    isRecord(patch) && typeof patch.name === "string" && isDefaultAgentReservedName(patch.name)
  );
}

function removeNullValues(record: Record<string, unknown>): void {
  for (const key of Object.keys(record)) {
    removeNullValue(record, key);
  }
}

function removeNullValue(record: Record<string, unknown>, key: string): void {
  if (record[key] === null) delete record[key];
}

function validateInstructions(value: unknown): AgentDefinition["instructions"] | undefined {
  if (value === undefined) return undefined;
  if (!isRecord(value)) throw new Error("instructions must be an object");
  assertAllowedKeys(value, INSTRUCTION_KEYS, "instructions");
  const mode = value.mode === undefined ? "append" : requireString(value.mode, "instructions.mode");
  if (!INSTRUCTION_MODES.has(mode)) {
    throw new Error("instructions.mode must be append or replace");
  }
  const text = requireString(value.text, "instructions.text");
  return { mode: mode as "append" | "replace", text };
}

function validateResources(value: unknown): AgentDefinition["resources"] | undefined {
  if (value === undefined) return undefined;
  if (!isRecord(value)) throw new Error("resources must be an object");
  assertAllowedKeys(value, RESOURCE_KEYS, "resources");
  return {
    ...(value.agentsFiles !== undefined
      ? { agentsFiles: validateAgentsFiles(value.agentsFiles) }
      : {}),
    ...(value.noContextFiles !== undefined
      ? { noContextFiles: validateBoolean(value.noContextFiles, "resources.noContextFiles") }
      : {}),
    ...(value.skillPaths !== undefined
      ? { skillPaths: validateStringArray(value.skillPaths, "resources.skillPaths") }
      : {}),
    ...(value.extensionIds !== undefined
      ? { extensionIds: validateStringArray(value.extensionIds, "resources.extensionIds") }
      : {}),
  };
}

function validateAgentsFiles(value: unknown): Array<{ path: string; content: string }> {
  if (!Array.isArray(value)) throw new Error("resources.agentsFiles must be an array");
  return value.map((entry, index) => {
    if (!isRecord(entry)) throw new Error(`resources.agentsFiles[${index}] must be an object`);
    assertAllowedKeys(entry, AGENTS_FILE_KEYS, `resources.agentsFiles[${index}]`);
    const path = requireString(entry.path, `resources.agentsFiles[${index}].path`);
    if (path.startsWith("/") || path.includes("..")) {
      throw new Error(`resources.agentsFiles[${index}].path must be a relative virtual path`);
    }
    const content = requireString(entry.content, `resources.agentsFiles[${index}].content`, {
      allowEmpty: true,
    });
    return { path, content };
  });
}

function validateSessionDefaults(value: unknown): AgentDefinition["sessionDefaults"] | undefined {
  if (value === undefined) return undefined;
  if (!isRecord(value)) throw new Error("sessionDefaults must be an object");
  assertAllowedKeys(value, SESSION_DEFAULT_KEYS, "sessionDefaults");
  const thinkingLevel = validateString(value.thinkingLevel, "sessionDefaults.thinkingLevel");
  if (thinkingLevel !== undefined && !isThinkingLevel(thinkingLevel)) {
    throw new Error("sessionDefaults.thinkingLevel is invalid");
  }
  const noTools = validateString(value.noTools, "sessionDefaults.noTools");
  if (noTools !== undefined && !NO_TOOLS_VALUES.has(noTools)) {
    throw new Error("sessionDefaults.noTools must be all or builtin");
  }
  return {
    ...(value.model !== undefined
      ? { model: requireString(value.model, "sessionDefaults.model") }
      : {}),
    ...(thinkingLevel !== undefined ? { thinkingLevel } : {}),
    ...(value.tools !== undefined
      ? { tools: validateStringArray(value.tools, "sessionDefaults.tools") }
      : {}),
    ...(value.excludeTools !== undefined
      ? { excludeTools: validateStringArray(value.excludeTools, "sessionDefaults.excludeTools") }
      : {}),
    ...(noTools !== undefined ? { noTools: noTools as "all" | "builtin" } : {}),
  };
}

function validateLaunchConstraints(
  value: unknown,
): AgentDefinition["launchConstraints"] | undefined {
  if (value === undefined) return undefined;
  if (!isRecord(value)) throw new Error("launchConstraints must be an object");
  assertAllowedKeys(value, LAUNCH_CONSTRAINT_KEYS, "launchConstraints");

  const allowedWorkspaceIds =
    value.allowedWorkspaceIds === undefined
      ? undefined
      : validateStringArray(value.allowedWorkspaceIds, "launchConstraints.allowedWorkspaceIds");
  if (allowedWorkspaceIds?.length === 0) {
    throw new Error("launchConstraints.allowedWorkspaceIds must not be empty");
  }

  const requiredRuntime = validateString(
    value.requiredRuntime,
    "launchConstraints.requiredRuntime",
  );
  if (
    requiredRuntime !== undefined &&
    requiredRuntime !== "host" &&
    requiredRuntime !== "sandbox"
  ) {
    throw new Error("launchConstraints.requiredRuntime must be host or sandbox");
  }

  return {
    ...(allowedWorkspaceIds ? { allowedWorkspaceIds: [...new Set(allowedWorkspaceIds)] } : {}),
    ...(requiredRuntime ? { requiredRuntime: requiredRuntime as "host" | "sandbox" } : {}),
  };
}

function validateAgentIcon(value: unknown): AgentDefinition["icon"] {
  if (value === undefined || value === null) return DEFAULT_ICON_CHOICE;
  return validateIconChoice(value);
}

function migrateStoredDefinitionJson(rawJson: string): string {
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawJson);
  } catch {
    return rawJson;
  }
  if (!isRecord(parsed)) return rawJson;
  const migrated: Record<string, unknown> = {
    ...parsed,
    icon: migrateIconChoice(parsed.icon),
  };
  if (isRecord(migrated.resources) && "promptTemplateIds" in migrated.resources) {
    const { promptTemplateIds: _removed, ...resources } = migrated.resources;
    migrated.resources = resources;
  }
  return JSON.stringify(migrated);
}

function requireString(
  value: unknown,
  label: string,
  options: { allowEmpty?: boolean } = {},
): string {
  return validateString(value, label, { ...options, required: true }) as string;
}

function validateString(
  value: unknown,
  label: string,
  options: { required?: boolean; allowEmpty?: boolean } = {},
): string | undefined {
  if (value === undefined) {
    if (options.required) throw new Error(`${label} required`);
    return undefined;
  }
  if (typeof value !== "string") throw new Error(`${label} must be a string`);
  const trimmed = value.trim();
  if (!options.allowEmpty && !trimmed) throw new Error(`${label} must not be empty`);
  return options.allowEmpty ? value : trimmed;
}

function validateBoolean(value: unknown, label: string): boolean {
  if (typeof value !== "boolean") throw new Error(`${label} must be a boolean`);
  return value;
}

function validateStringArray(value: unknown, label: string): string[] {
  if (!Array.isArray(value)) throw new Error(`${label} must be an array`);
  return value.map((entry, index) => requireString(entry, `${label}[${index}]`));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function assertAllowedKeys(
  value: Record<string, unknown>,
  allowed: ReadonlySet<string>,
  label: string,
): void {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) throw new Error(`${label} has unexpected field: ${key}`);
  }
}
