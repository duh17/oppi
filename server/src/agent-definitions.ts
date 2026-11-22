import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";

import { generateId } from "./id.js";
import {
  DEFAULT_ICON_CHOICE,
  migrateIconChoice,
  validateIconChoice,
  type IconAssetKind,
} from "./icon-choice.js";
import { openDatabase, type SqliteDatabase } from "./sqlite-compat.js";
import { runSessionStateDeadSchemaCleanup } from "./storage/session-state-cleanup-migration.js";
import { isThinkingLevel } from "./thinking-levels.js";
import { isAgentDefinitionV1, type AgentDefinition } from "./agent-definition.js";
import { agentToolSetReadOnly, isAgentDiscoveryTool } from "./agent-capabilities.js";
import {
  migrateAgentDefinitionV1,
  type AgentMigrationCatalogs,
} from "./agent-definition-migration.js";
import { migrateWithBackup } from "./storage/session-state-cleanup-migration.js";
import { isRecord } from "./json-shape.js";

export type AgentDefinitionStatus = "active" | "archived";

export interface StoredAgentDefinition {
  id: string;
  name: string;
  status: AgentDefinitionStatus;
  version: number;
  definition: AgentDefinition;
  /** True when the row is still in the v1 shape: it lists, but it cannot launch. */
  v1?: true;
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
  sessionDefaults?: {
    model?: string;
    thinkingLevel?: NonNullable<AgentDefinition["sessionDefaults"]>["thinkingLevel"];
  };
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

export const AGENT_IDEMPOTENCY_CONFLICT_CODE = "AGENT_IDEMPOTENCY_CONFLICT";

/** A create key that already created an Agent from a different definition. */
export class AgentIdempotencyConflictError extends Error {
  readonly code = AGENT_IDEMPOTENCY_CONFLICT_CODE;

  constructor(readonly agentId: string) {
    super(`Idempotency key already created Agent ${agentId} from a different definition`);
    this.name = "AgentIdempotencyConflictError";
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
  "sessionDefaults",
  "capabilities",
  "context",
  "launchConstraints",
]);
/** Keys the v1 shape had. Naming one is a clear "this is v1" error, not a typo. */
const AGENT_V1_DEFINITION_KEYS = new Set(["resources"]);
const AGENT_V1_SESSION_DEFAULT_KEYS = new Set(["tools", "excludeTools", "noTools"]);
const INSTRUCTION_KEYS = new Set(["mode", "text"]);
const CAPABILITY_KEYS = new Set(["tools", "ask", "notify", "subagent", "plugins", "mcp"]);
const CONTEXT_KEYS = new Set(["skills", "contextFiles", "sessionHistory"]);
const SESSION_DEFAULT_KEYS = new Set(["model", "thinkingLevel"]);
const LAUNCH_CONSTRAINT_KEYS = new Set([
  "allowedWorkspaceIds",
  "requiredRuntime",
  "requiredEngine",
]);
const MAX_UNVERSIONED_AGENT_UPDATE_ATTEMPTS = 3;
export class AgentDefinitionStore {
  private readonly db: SqliteDatabase;
  /** The data directory: the migration writes its pre-migration backup under `backups/`. */
  private readonly dataDir: string;

  constructor(
    dataDir: string,
    dbPath?: string,
    private readonly iconAssetKind?: (assetId: string) => IconAssetKind | undefined,
  ) {
    if (!existsSync(dataDir)) {
      mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    }
    const resolvedDataDir = resolve(dataDir);
    this.dataDir = resolvedDataDir;
    const resolvedDbPath = resolve(dbPath ?? join(dataDir, "session-state.db"));
    this.db = openDatabase(resolvedDbPath);
    chmodSync(resolvedDbPath, 0o600);
    this.db.exec("PRAGMA journal_mode = WAL");
    this.db.exec("PRAGMA synchronous = NORMAL");
    this.ensureSchema();
    runSessionStateDeadSchemaCleanup(this.db, resolvedDataDir);
  }

  close(): void {
    this.db.close();
  }

  /**
   * Create once per key. The key row commits with the Agent, so a replay (a retry after a
   * crash or a lost response) returns the Agent the key already created, as it is now, and
   * creates nothing. The same key with another definition is a conflict, not a second Agent.
   */
  createAgentOnce(
    input: unknown,
    idempotencyKey: string,
    now = Date.now(),
  ): { agent: StoredAgentDefinition; replayed: boolean } {
    const definition = validateAgentDefinition(input);
    const fingerprint = createHash("sha256").update(JSON.stringify(definition)).digest("hex");
    const existing = this.db
      .prepare("SELECT agent_id, fingerprint FROM agent_create_requests WHERE idempotency_key = ?")
      .get(idempotencyKey) as { agent_id: string; fingerprint: string } | undefined;
    if (existing) {
      const agent = this.getAgent(existing.agent_id);
      if (!agent) throw new Error(`Agent ${existing.agent_id} for this idempotency key is missing`);
      if (existing.fingerprint !== fingerprint) throw new AgentIdempotencyConflictError(agent.id);
      return { agent, replayed: true };
    }
    const agent = this.createAgent(input, now, (id) => {
      this.db
        .prepare(
          `INSERT INTO agent_create_requests (idempotency_key, agent_id, fingerprint)
           VALUES (?, ?, ?)`,
        )
        .run(idempotencyKey, id, fingerprint);
    });
    return { agent, replayed: false };
  }

  createAgent(
    input: unknown,
    now = Date.now(),
    /** Runs inside the creating transaction. */
    onCreated?: (agentId: string) => void,
  ): StoredAgentDefinition {
    const definition = validateAgentDefinition(input);
    this.assertIconAssetExists(definition);
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
      onCreated?.(agent.id);
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
      const nextDefinition = validateAgentDefinitionUpdate(currentAgent.definition, patch);
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
    if (!current) return undefined;
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
      AgentRow | undefined;
    return row ? agentFromRow(row) : undefined;
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

  /** True while any stored row or version still names `capabilities.core`, the coding tier. */
  hasCodingTierDefinitions(): boolean {
    const namesCore = (definitionJson: string): boolean => {
      try {
        const parsed: unknown = JSON.parse(definitionJson);
        return isRecord(parsed) && isRecord(parsed.capabilities) && "core" in parsed.capabilities;
      } catch {
        return false;
      }
    };
    const rows = this.db
      .prepare(
        "SELECT definition_json FROM agent_definitions UNION ALL SELECT definition_json FROM agent_definition_versions",
      )
      .all() as Array<{ definition_json: string }>;
    return rows.some((row) => namesCore(row.definition_json));
  }

  /**
   * The rewrite of `capabilities.core` into `capabilities.tools`, once per data directory, over the
   * rows and version history stored at that moment: the same effective tools each Agent has now.
   *
   * - A normal Agent (`full`) stated no tools and followed the Pi Tools setting; it keeps doing
   *   that, so its `core` is dropped and no `tools` is written.
   * - An Agent that cannot change files had read/bash/… from the setting, and the two write tools
   *   and the MCP transport tools out of it. Its own set is the setting minus `write`, `edit` and
   *   the two discovery names: `codemode` and `tool_search` come back only from an MCP server that
   *   needs them, exactly as they do today, so dropping that server still takes them away.
   *
   * A row the rewrite cannot make valid is left alone and reported; it then refuses to launch by
   * name. Idempotent: a row with no `core` is not touched, so a second pass writes nothing.
   */
  migrateStoredAgentTools(piToolNames: readonly string[]): {
    migrated: number;
    notes: Array<{ id: string; notes: string[] }>;
    backupPath: string;
  } {
    const kept = piToolNames.filter(
      (name) => name !== "write" && name !== "edit" && !isAgentDiscoveryTool(name),
    );
    const { backupPath, result } = migrateWithBackup(
      this.db,
      this.dataDir,
      "agent-definitions-pi-tools",
      () => this.rewriteCodingTiers(kept),
    );
    return { ...result, backupPath };
  }

  private rewriteCodingTiers(keptForReadOnly: readonly string[]): {
    migrated: number;
    notes: Array<{ id: string; notes: string[] }>;
  } {
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
    let migrated = 0;
    const notes: Array<{ id: string; notes: string[] }> = [];

    const rewrite = (rawJson: string): string => {
      let parsed: unknown;
      try {
        parsed = JSON.parse(rawJson);
      } catch {
        return rawJson;
      }
      if (!isRecord(parsed) || !isRecord(parsed.capabilities)) return rawJson;
      const capabilities = { ...parsed.capabilities };
      const core = capabilities.core;
      if (!("core" in capabilities)) return rawJson;
      delete capabilities.core;
      const note =
        core === "readonly"
          ? `a read-only Agent's coding tier became its own Pi tools (${keptForReadOnly.join(", ")}); codemode and tool search come from an MCP server that needs them`
          : "dropped the full coding tier: this Agent follows the Pi Tools setting, as it did";
      if (core === "readonly") capabilities.tools = [...keptForReadOnly];
      const rewritten = JSON.stringify({ ...parsed, capabilities });
      try {
        validateAgentDefinition(JSON.parse(rewritten));
      } catch (error) {
        notes.push({
          id: "",
          notes: [
            `could not rewrite this Agent's coding tier, so it is untouched and cannot start: ${error instanceof Error ? error.message : String(error)}`,
          ],
        });
        return rawJson;
      }
      migrated += 1;
      notes.push({ id: "", notes: [note] });
      return rewritten;
    };

    this.db.transaction(() => {
      for (const row of currentRows) {
        const before = notes.length;
        const rewritten = rewrite(row.definition_json);
        const last = notes[notes.length - 1];
        if (notes.length > before && last) last.id = row.id;
        if (rewritten !== row.definition_json) updateCurrent.run(rewritten, row.id);
      }
      for (const row of versionRows) {
        const before = notes.length;
        const rewritten = rewrite(row.definition_json);
        const last = notes[notes.length - 1];
        if (notes.length > before && last) last.id = `${row.id}@v${row.version}`;
        if (rewritten !== row.definition_json) updateVersion.run(rewritten, row.id, row.version);
      }
    })();
    return { migrated, notes };
  }

  /** True while any stored row or version still holds the v1 shape. */
  hasV1Definitions(): boolean {
    const rows = this.db.prepare("SELECT definition_json FROM agent_definitions").all() as Array<{
      definition_json: string;
    }>;
    if (rows.some((row) => isV1Json(row.definition_json))) return true;
    const versions = this.db
      .prepare("SELECT definition_json FROM agent_definition_versions")
      .all() as Array<{ definition_json: string }>;
    return versions.some((row) => isV1Json(row.definition_json));
  }

  /**
   * The one-time rewrite of stored definitions into the v2 shape, plus the historical icon values
   * it also carries. Runs once per data directory, over the rows and version history stored at
   * that moment, inside one transaction: a resumed session reads the version it pinned, so history
   * has to be readable too. A row that cannot be migrated is left alone and reports why; it then
   * fails launch with `agent_definition_v2_required` instead of running v1 wiring.
   */
  migrateStoredDefinitions(catalogs: AgentMigrationCatalogs): {
    migrated: number;
    notes: Array<{ id: string; notes: string[] }>;
    backupPath: string;
  } {
    // The rewrite runs under the same pre-migration backup as every other destructive session
    // state migration: putting the old server back finds rows it can read, and an old server
    // casts rows without validating them, so a v2 row without `resources` would read as "no
    // restrictions". A throw below rolls the transaction back and the backup is dropped.
    const { backupPath, result } = migrateWithBackup(
      this.db,
      this.dataDir,
      "agent-definitions-v2",
      () => this.rewriteStoredDefinitions(catalogs),
    );
    return { ...result, backupPath };
  }

  private rewriteStoredDefinitions(catalogs: AgentMigrationCatalogs): {
    migrated: number;
    notes: Array<{ id: string; notes: string[] }>;
  } {
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
    let migrated = 0;
    const notes: Array<{ id: string; notes: string[] }> = [];

    const rewrite = (rawJson: string): string => {
      let parsed: unknown;
      try {
        parsed = JSON.parse(rawJson);
      } catch {
        return rawJson;
      }
      if (!isRecord(parsed)) return rawJson;
      const result = migrateAgentDefinitionV1(parsed, catalogs);
      if (result.notes.length > 0) notes.push({ id: "", notes: [...result.notes] });
      if (result.definition === undefined) {
        // Already v2: only its historical icon may still need rewriting.
        const withIcon = { ...parsed, icon: migrateIconChoice(parsed.icon) };
        return JSON.stringify(withIcon);
      }
      const withIcon: Record<string, unknown> = {
        ...(result.definition as unknown as Record<string, unknown>),
        icon: migrateIconChoice(result.definition.icon),
      };
      // Every migrated row must be something the store would accept from a client. One that is
      // not stays in its old shape (and refuses to launch by name) instead of being written.
      try {
        validateAgentDefinition(withIcon);
      } catch (error) {
        notes.push({
          id: "",
          notes: [
            `could not migrate this Agent, so it is untouched and cannot start: ${error instanceof Error ? error.message : String(error)}`,
          ],
        });
        return rawJson;
      }
      migrated += 1;
      return JSON.stringify(withIcon);
    };

    this.db.transaction(() => {
      for (const row of currentRows) {
        const before = notes.length;
        const rewritten = rewrite(row.definition_json);
        const last = notes[notes.length - 1];
        if (notes.length > before && last) last.id = row.id;
        if (rewritten !== row.definition_json) updateCurrent.run(rewritten, row.id);
      }
      for (const row of versionRows) {
        const before = notes.length;
        const rewritten = rewrite(row.definition_json);
        const last = notes[notes.length - 1];
        if (notes.length > before && last) last.id = `${row.id}@v${row.version}`;
        if (rewritten !== row.definition_json) updateVersion.run(rewritten, row.id, row.version);
      }
    })();
    return { migrated, notes };
  }

  /** A Genmoji or image icon must name a stored asset of its own kind. */
  private assertIconAssetExists(definition: AgentDefinition): void {
    if (definition.icon && this.iconAssetKind) {
      validateIconChoice(definition.icon, { assetKind: this.iconAssetKind });
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
      CREATE TABLE IF NOT EXISTS agent_definition_versions (
        id TEXT NOT NULL,
        version INTEGER NOT NULL,
        definition_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (id, version)
      );
      CREATE TABLE IF NOT EXISTS agent_create_requests (
        idempotency_key TEXT PRIMARY KEY,
        agent_id TEXT NOT NULL,
        fingerprint TEXT NOT NULL
      );
      INSERT OR IGNORE INTO agent_definition_versions (id, version, definition_json, created_at)
        SELECT id, version, definition_json, updated_at FROM agent_definitions;
    `);
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
  const sessionDefaults = summarySessionDefaults(agent.definition.sessionDefaults);
  return {
    id: agent.id,
    name: agent.name,
    icon: agent.definition.icon ?? DEFAULT_ICON_CHOICE,
    ...(agent.definition.description ? { description: agent.definition.description } : {}),
    ...(agent.definition.launchConstraints
      ? { launchConstraints: agent.definition.launchConstraints }
      : {}),
    ...(sessionDefaults ? { sessionDefaults } : {}),
    status: agent.status,
    version: agent.version,
    createdAt: agent.createdAt,
    updatedAt: agent.updatedAt,
    ...(agent.archivedAt !== undefined ? { archivedAt: agent.archivedAt } : {}),
  };
}

function summarySessionDefaults(
  defaults: AgentDefinition["sessionDefaults"],
): AgentDefinitionSummary["sessionDefaults"] {
  const model = typeof defaults?.model === "string" ? defaults.model.trim() : "";
  const thinkingLevel = defaults?.thinkingLevel;
  if (!model && !thinkingLevel) return undefined;
  return {
    ...(model ? { model } : {}),
    ...(thinkingLevel ? { thinkingLevel } : {}),
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
    // A row the startup migration could not rewrite still lists and reads, but launching it would
    // run v1 wiring the engines no longer have, so the launch route refuses it by name.
    ...(isAgentDefinitionV1(definition) ? { v1: true as const } : {}),
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
  const capabilities = validateCapabilities(input.capabilities);
  const context = validateContext(input.context);
  const sessionDefaults = validateSessionDefaults(input.sessionDefaults);
  const launchConstraints = validateLaunchConstraints(input.launchConstraints);

  return {
    name,
    icon,
    ...(description !== undefined ? { description } : {}),
    ...(instructions !== undefined ? { instructions } : {}),
    ...(capabilities !== undefined ? { capabilities } : {}),
    ...(context !== undefined ? { context } : {}),
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
    ...(isRecord(patch.capabilities)
      ? { capabilities: { ...(current.capabilities ?? {}), ...patch.capabilities } }
      : {}),
    ...(isRecord(patch.context)
      ? { context: { ...(current.context ?? {}), ...patch.context } }
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
  removeNullValue(merged, "capabilities");
  removeNullValue(merged, "context");
  removeNullValue(merged, "sessionDefaults");
  removeNullValue(merged, "launchConstraints");
  if (isRecord(merged.capabilities)) removeNullValues(merged.capabilities);
  if (isRecord(merged.context)) removeNullValues(merged.context);
  if (isRecord(merged.sessionDefaults)) removeNullValues(merged.sessionDefaults);
  if (isRecord(merged.launchConstraints)) removeNullValues(merged.launchConstraints);

  return merged as unknown as AgentDefinition;
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

function validateCapabilities(value: unknown): AgentDefinition["capabilities"] | undefined {
  if (value === undefined) return undefined;
  if (!isRecord(value)) throw new Error("capabilities must be an object");
  assertAllowedKeys(value, CAPABILITY_KEYS, "capabilities");

  const tools =
    value.tools === undefined ? undefined : validateStringArray(value.tools, "capabilities.tools");
  const ask = optionalBoolean(value.ask, "capabilities.ask");
  const notify = optionalBoolean(value.notify, "capabilities.notify");
  const subagent = optionalBoolean(value.subagent, "capabilities.subagent");
  const plugins =
    value.plugins === undefined
      ? undefined
      : validateStringArray(value.plugins, "capabilities.plugins");
  const mcp = validateMcpSelection(value.mcp);
  if (tools !== undefined && new Set(tools).size !== tools.length) {
    throw new Error("capabilities.tools names a tool twice");
  }

  // An Agent that cannot edit files states what it may reach: "everything" is never implied by
  // omission, which is the one property that made the old allow lists widen access by accident.
  if (tools !== undefined && agentToolSetReadOnly(tools)) {
    if (plugins === undefined) {
      throw new Error(
        "capabilities.plugins is required when capabilities.tools cannot write files",
      );
    }
    if (mcp === undefined) {
      throw new Error("capabilities.mcp is required when capabilities.tools cannot write files");
    }
  }

  return {
    ...(tools !== undefined ? { tools } : {}),
    ...(ask !== undefined ? { ask } : {}),
    ...(notify !== undefined ? { notify } : {}),
    ...(subagent !== undefined ? { subagent } : {}),
    ...(plugins !== undefined ? { plugins } : {}),
    ...(mcp !== undefined ? { mcp } : {}),
  };
}

function validateMcpSelection(value: unknown): Record<string, "all" | string[]> | undefined {
  if (value === undefined) return undefined;
  if (!isRecord(value)) throw new Error("capabilities.mcp must be an object of server names");
  const selection: Record<string, "all" | string[]> = {};
  for (const [name, tools] of Object.entries(value)) {
    if (name.startsWith("mcp__")) {
      throw new Error(
        `capabilities.mcp names a tool pattern (${name}); name the server (${name.slice("mcp__".length).split("__")[0]}), not a tool pattern`,
      );
    }
    if (!name.trim()) throw new Error("capabilities.mcp server names must not be empty");
    if (tools === "all") {
      selection[name] = "all";
      continue;
    }
    if (!Array.isArray(tools)) {
      throw new Error(`capabilities.mcp.${name} must be "all" or a list of tool names`);
    }
    const names = validateStringArray(tools, `capabilities.mcp.${name}`);
    if (names.length === 0) {
      throw new Error(`capabilities.mcp.${name} must be "all" or name at least one tool`);
    }
    selection[name] = names;
  }
  return selection;
}

function validateContext(value: unknown): AgentDefinition["context"] | undefined {
  if (value === undefined) return undefined;
  if (!isRecord(value)) throw new Error("context must be an object");
  assertAllowedKeys(value, CONTEXT_KEYS, "context");
  const skills =
    value.skills === undefined ? undefined : validateStringArray(value.skills, "context.skills");
  const contextFiles = optionalBoolean(value.contextFiles, "context.contextFiles");
  const sessionHistory = optionalBoolean(value.sessionHistory, "context.sessionHistory");
  return {
    ...(skills !== undefined ? { skills } : {}),
    ...(contextFiles !== undefined ? { contextFiles } : {}),
    ...(sessionHistory !== undefined ? { sessionHistory } : {}),
  };
}

function validateSessionDefaults(value: unknown): AgentDefinition["sessionDefaults"] | undefined {
  if (value === undefined) return undefined;
  if (!isRecord(value)) throw new Error("sessionDefaults must be an object");
  assertAllowedKeys(value, SESSION_DEFAULT_KEYS, "sessionDefaults");
  const thinkingLevel = validateString(value.thinkingLevel, "sessionDefaults.thinkingLevel");
  if (thinkingLevel !== undefined && !isThinkingLevel(thinkingLevel)) {
    throw new Error("sessionDefaults.thinkingLevel is invalid");
  }
  return {
    ...(value.model !== undefined
      ? { model: requireString(value.model, "sessionDefaults.model") }
      : {}),
    ...(thinkingLevel !== undefined ? { thinkingLevel } : {}),
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

  const requiredEngine = validateString(value.requiredEngine, "launchConstraints.requiredEngine");
  if (requiredEngine !== undefined && requiredEngine !== "durable") {
    throw new Error("launchConstraints.requiredEngine must be durable");
  }

  return {
    ...(allowedWorkspaceIds ? { allowedWorkspaceIds: [...new Set(allowedWorkspaceIds)] } : {}),
    ...(requiredRuntime ? { requiredRuntime: requiredRuntime as "host" | "sandbox" } : {}),
    ...(requiredEngine ? { requiredEngine: "durable" as const } : {}),
  };
}

function validateAgentIcon(value: unknown): AgentDefinition["icon"] {
  if (value === undefined || value === null) return DEFAULT_ICON_CHOICE;
  return validateIconChoice(value);
}

function isV1Json(rawJson: string): boolean {
  try {
    return isAgentDefinitionV1(JSON.parse(rawJson));
  } catch {
    return false;
  }
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

function assertAllowedKeys(
  value: Record<string, unknown>,
  allowed: ReadonlySet<string>,
  label: string,
): void {
  for (const key of Object.keys(value)) {
    if (allowed.has(key)) continue;
    if (label === "Agent definition" && AGENT_V1_DEFINITION_KEYS.has(key)) {
      throw new Error(
        `Agent definitions are v2: resources was replaced by capabilities and context; rewrite this Agent`,
      );
    }
    if (label === "sessionDefaults" && AGENT_V1_SESSION_DEFAULT_KEYS.has(key)) {
      throw new Error(
        `Agent definitions are v2: sessionDefaults.${key} was replaced by capabilities; rewrite this Agent`,
      );
    }
    throw new Error(`${label} has unexpected field: ${key}`);
  }
}

function optionalBoolean(value: unknown, label: string): boolean | undefined {
  if (value === undefined) return undefined;
  return validateBoolean(value, label);
}
