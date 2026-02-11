/**
 * Persistent storage for pi-remote
 *
 * Data directory structure:
 * ~/.config/pi-remote/
 * ├── config.json       # Server config
 * ├── users.json        # Owner identity & token (single-user)
 * ├── sessions/
 * │   └── <sessionId>.json      # Flat owner layout (single-user mode)
 * └── workspaces/
 *     └── <workspaceId>.json    # Flat owner layout (single-user mode)
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { nanoid } from "nanoid";
import type {
  User,
  Session,
  SessionMessage,
  SecurityProfile,
  ServerConfig,
  ServerSecurityConfig,
  ServerIdentityConfig,
  ServerInviteConfig,
  Workspace,
  CreateWorkspaceRequest,
  UpdateWorkspaceRequest,
} from "./types.js";

const DEFAULT_DATA_DIR = join(homedir(), ".config", "pi-remote");
const CONFIG_VERSION = 2;
const SECURITY_PROFILES: ReadonlySet<SecurityProfile> = new Set([
  "legacy",
  "tailscale-permissive",
  "strict",
]);
const INVITE_FORMATS: ReadonlySet<ServerInviteConfig["format"]> = new Set(["v2-signed"]);

export interface ConfigValidationResult {
  valid: boolean;
  errors: string[];
  warnings: string[];
  config?: ServerConfig;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isUserRecord(value: unknown): value is User {
  if (!isRecord(value)) return false;
  return (
    typeof value.id === "string" &&
    typeof value.name === "string" &&
    typeof value.token === "string" &&
    typeof value.createdAt === "number"
  );
}

function defaultSecurityConfig(): ServerSecurityConfig {
  return {
    profile: "tailscale-permissive",
    requireTlsOutsideTailnet: true,
    allowInsecureHttpInTailnet: true,
    requirePinnedServerIdentity: true,
  };
}

function defaultIdentityConfig(dataDir: string): ServerIdentityConfig {
  return {
    enabled: true,
    algorithm: "ed25519",
    keyId: "srv-default",
    privateKeyPath: join(dataDir, "identity_ed25519"),
    publicKeyPath: join(dataDir, "identity_ed25519.pub"),
    fingerprint: "",
  };
}

function defaultInviteConfig(): ServerInviteConfig {
  return {
    format: "v2-signed",
    maxAgeSeconds: 600,
    singleUse: false,
  };
}

function createDefaultConfig(dataDir: string): ServerConfig {
  return {
    configVersion: CONFIG_VERSION,
    port: 7749,
    host: "0.0.0.0",
    dataDir,
    defaultModel: "anthropic/claude-sonnet-4-0",
    sessionTimeout: 10 * 60 * 1000,
    sessionIdleTimeoutMs: 10 * 60 * 1000,
    workspaceIdleTimeoutMs: 30 * 60 * 1000,
    maxSessionsPerWorkspace: 3,
    maxSessionsGlobal: 5,
    approvalTimeoutMs: 120 * 1000,
    legacyExtensionsEnabled: true,
    security: defaultSecurityConfig(),
    identity: defaultIdentityConfig(dataDir),
    invite: defaultInviteConfig(),
  };
}

function normalizeConfig(
  raw: unknown,
  dataDir: string,
  strictUnknown: boolean,
): ConfigValidationResult & { config: ServerConfig; changed: boolean } {
  const defaults = createDefaultConfig(dataDir);
  const errors: string[] = [];
  const warnings: string[] = [];
  let changed = false;

  const config: ServerConfig = {
    ...defaults,
    security: defaultSecurityConfig(),
    identity: defaultIdentityConfig(defaults.dataDir),
    invite: defaultInviteConfig(),
  };

  if (!isRecord(raw)) {
    errors.push("config: expected top-level JSON object");
    return { valid: false, errors, warnings, config, changed: true };
  }

  const obj = raw;

  const topLevelKeys = new Set([
    "configVersion",
    "port",
    "host",
    "dataDir",
    "defaultModel",
    "sessionTimeout",
    "sessionIdleTimeoutMs",
    "workspaceIdleTimeoutMs",
    "maxSessionsPerWorkspace",
    "maxSessionsGlobal",
    "approvalTimeoutMs",
    "legacyExtensionsEnabled",
    "security",
    "identity",
    "invite",
  ]);

  if (strictUnknown) {
    for (const key of Object.keys(obj)) {
      if (!topLevelKeys.has(key)) {
        errors.push(`config.${key}: unknown key`);
      }
    }
  }

  const readNumber = (key: string, opts?: { min?: number; integer?: boolean }): number | undefined => {
    if (!(key in obj)) {
      changed = true;
      return undefined;
    }
    const value = obj[key];
    const integer = opts?.integer ?? true;
    if (typeof value !== "number" || Number.isNaN(value) || !Number.isFinite(value)) {
      errors.push(`config.${key}: expected number`);
      changed = true;
      return undefined;
    }
    if (integer && !Number.isInteger(value)) {
      errors.push(`config.${key}: expected integer`);
      changed = true;
      return undefined;
    }
    if (opts?.min !== undefined && value < opts.min) {
      errors.push(`config.${key}: expected >= ${opts.min}`);
      changed = true;
      return undefined;
    }
    return value;
  };

  const readString = (key: string): string | undefined => {
    if (!(key in obj)) {
      changed = true;
      return undefined;
    }
    const value = obj[key];
    if (typeof value !== "string" || value.trim().length === 0) {
      errors.push(`config.${key}: expected non-empty string`);
      changed = true;
      return undefined;
    }
    return value;
  };

  const readBoolean = (key: string): boolean | undefined => {
    if (!(key in obj)) {
      changed = true;
      return undefined;
    }
    const value = obj[key];
    if (typeof value !== "boolean") {
      errors.push(`config.${key}: expected boolean`);
      changed = true;
      return undefined;
    }
    return value;
  };

  const configVersion = readNumber("configVersion", { min: 1 });
  if (configVersion !== undefined) {
    config.configVersion = configVersion;
  }

  const port = readNumber("port", { min: 1 });
  if (port !== undefined && port <= 65_535) {
    config.port = port;
  } else if (port !== undefined) {
    errors.push("config.port: expected <= 65535");
    changed = true;
  }

  const host = readString("host");
  if (host !== undefined) {
    config.host = host;
  }

  const configuredDataDir = readString("dataDir");
  if (configuredDataDir !== undefined) {
    config.dataDir = configuredDataDir;
  }

  const model = readString("defaultModel");
  if (model !== undefined) {
    config.defaultModel = model;
  }

  const sessionTimeout = readNumber("sessionTimeout", { min: 1 });
  const sessionIdleTimeoutMs = readNumber("sessionIdleTimeoutMs", { min: 1 });

  if (sessionTimeout !== undefined && sessionIdleTimeoutMs === undefined) {
    config.sessionTimeout = sessionTimeout;
    config.sessionIdleTimeoutMs = sessionTimeout;
    changed = true;
  } else if (sessionTimeout === undefined && sessionIdleTimeoutMs !== undefined) {
    config.sessionIdleTimeoutMs = sessionIdleTimeoutMs;
    config.sessionTimeout = sessionIdleTimeoutMs;
    changed = true;
  } else {
    if (sessionTimeout !== undefined) {
      config.sessionTimeout = sessionTimeout;
    }
    if (sessionIdleTimeoutMs !== undefined) {
      config.sessionIdleTimeoutMs = sessionIdleTimeoutMs;
    }
  }

  const workspaceIdleTimeoutMs = readNumber("workspaceIdleTimeoutMs", { min: 1 });
  if (workspaceIdleTimeoutMs !== undefined) {
    config.workspaceIdleTimeoutMs = workspaceIdleTimeoutMs;
  }

  const maxSessionsPerWorkspace = readNumber("maxSessionsPerWorkspace", { min: 1 });
  if (maxSessionsPerWorkspace !== undefined) {
    config.maxSessionsPerWorkspace = maxSessionsPerWorkspace;
  }

  const maxSessionsGlobal = readNumber("maxSessionsGlobal", { min: 1 });
  if (maxSessionsGlobal !== undefined) {
    config.maxSessionsGlobal = maxSessionsGlobal;
  }

  const approvalTimeoutMs = readNumber("approvalTimeoutMs", { min: 0 });
  if (approvalTimeoutMs !== undefined) {
    config.approvalTimeoutMs = approvalTimeoutMs;
  }

  const legacyExtensionsEnabled = readBoolean("legacyExtensionsEnabled");
  if (legacyExtensionsEnabled !== undefined) {
    config.legacyExtensionsEnabled = legacyExtensionsEnabled;
  }

  const securityDefaults = defaultSecurityConfig();
  if (!("security" in obj)) {
    changed = true;
    config.security = securityDefaults;
  } else {
    const rawSecurity = obj.security;
    if (!isRecord(rawSecurity)) {
      errors.push("config.security: expected object");
      changed = true;
      config.security = securityDefaults;
    } else {
      const allowed = new Set([
        "profile",
        "requireTlsOutsideTailnet",
        "allowInsecureHttpInTailnet",
        "requirePinnedServerIdentity",
      ]);
      if (strictUnknown) {
        for (const key of Object.keys(rawSecurity)) {
          if (!allowed.has(key)) {
            errors.push(`config.security.${key}: unknown key`);
          }
        }
      }

      const security: ServerSecurityConfig = { ...securityDefaults };

      if (!("profile" in rawSecurity)) {
        changed = true;
      } else if (typeof rawSecurity.profile !== "string" || !SECURITY_PROFILES.has(rawSecurity.profile as SecurityProfile)) {
        errors.push(`config.security.profile: expected one of ${Array.from(SECURITY_PROFILES).join(", ")}`);
        changed = true;
      } else {
        security.profile = rawSecurity.profile as SecurityProfile;
      }

      const securityBool = (key: keyof Omit<ServerSecurityConfig, "profile">): void => {
        if (!(key in rawSecurity)) {
          changed = true;
          return;
        }
        const value = rawSecurity[key];
        if (typeof value !== "boolean") {
          errors.push(`config.security.${key}: expected boolean`);
          changed = true;
          return;
        }
        security[key] = value;
      };

      securityBool("requireTlsOutsideTailnet");
      securityBool("allowInsecureHttpInTailnet");
      securityBool("requirePinnedServerIdentity");

      config.security = security;
    }
  }

  const identityDefaults = defaultIdentityConfig(config.dataDir);
  if (!("identity" in obj)) {
    changed = true;
    config.identity = identityDefaults;
  } else {
    const rawIdentity = obj.identity;
    if (!isRecord(rawIdentity)) {
      errors.push("config.identity: expected object");
      changed = true;
      config.identity = identityDefaults;
    } else {
      const allowed = new Set([
        "enabled",
        "algorithm",
        "keyId",
        "privateKeyPath",
        "publicKeyPath",
        "fingerprint",
      ]);
      if (strictUnknown) {
        for (const key of Object.keys(rawIdentity)) {
          if (!allowed.has(key)) {
            errors.push(`config.identity.${key}: unknown key`);
          }
        }
      }

      const identity: ServerIdentityConfig = { ...identityDefaults };

      if (!("enabled" in rawIdentity)) {
        changed = true;
      } else if (typeof rawIdentity.enabled !== "boolean") {
        errors.push("config.identity.enabled: expected boolean");
        changed = true;
      } else {
        identity.enabled = rawIdentity.enabled;
      }

      if (!("algorithm" in rawIdentity)) {
        changed = true;
      } else if (rawIdentity.algorithm !== "ed25519") {
        errors.push("config.identity.algorithm: expected \"ed25519\"");
        changed = true;
      }

      const identityString = (key: keyof Pick<ServerIdentityConfig, "keyId" | "privateKeyPath" | "publicKeyPath" | "fingerprint">): void => {
        if (!(key in rawIdentity)) {
          changed = true;
          return;
        }
        const value = rawIdentity[key];
        if (typeof value !== "string") {
          errors.push(`config.identity.${key}: expected string`);
          changed = true;
          return;
        }
        if (key !== "fingerprint" && value.trim().length === 0) {
          errors.push(`config.identity.${key}: expected non-empty string`);
          changed = true;
          return;
        }
        identity[key] = value;
      };

      identityString("keyId");
      identityString("privateKeyPath");
      identityString("publicKeyPath");
      identityString("fingerprint");

      config.identity = identity;
    }
  }

  const inviteDefaults = defaultInviteConfig();
  if (!("invite" in obj)) {
    changed = true;
    config.invite = inviteDefaults;
  } else {
    const rawInvite = obj.invite;
    if (!isRecord(rawInvite)) {
      errors.push("config.invite: expected object");
      changed = true;
      config.invite = inviteDefaults;
    } else {
      const allowed = new Set(["format", "maxAgeSeconds", "singleUse"]);
      if (strictUnknown) {
        for (const key of Object.keys(rawInvite)) {
          if (!allowed.has(key)) {
            errors.push(`config.invite.${key}: unknown key`);
          }
        }
      }

      const invite: ServerInviteConfig = { ...inviteDefaults };

      if (!("format" in rawInvite)) {
        changed = true;
      } else if (
        typeof rawInvite.format !== "string" ||
        !INVITE_FORMATS.has(rawInvite.format as ServerInviteConfig["format"])
      ) {
        errors.push(`config.invite.format: expected one of ${Array.from(INVITE_FORMATS).join(", ")}`);
        changed = true;
      } else {
        invite.format = rawInvite.format as ServerInviteConfig["format"];
      }

      if (!("maxAgeSeconds" in rawInvite)) {
        changed = true;
      } else if (
        typeof rawInvite.maxAgeSeconds !== "number" ||
        !Number.isInteger(rawInvite.maxAgeSeconds) ||
        rawInvite.maxAgeSeconds < 1
      ) {
        errors.push("config.invite.maxAgeSeconds: expected integer >= 1");
        changed = true;
      } else {
        invite.maxAgeSeconds = rawInvite.maxAgeSeconds;
      }

      if (!("singleUse" in rawInvite)) {
        changed = true;
      } else if (typeof rawInvite.singleUse !== "boolean") {
        errors.push("config.invite.singleUse: expected boolean");
        changed = true;
      } else {
        invite.singleUse = rawInvite.singleUse;
      }

      config.invite = invite;
    }
  }

  return { valid: errors.length === 0, errors, warnings, config, changed };
}

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

function resolveWorkspaceExtensionMode(
  explicitExtensions: string[] | undefined,
  mode: Workspace["extensionMode"] | undefined,
): Workspace["extensionMode"] {
  if (mode === "legacy" || mode === "explicit") return mode;
  return explicitExtensions ? "explicit" : "legacy";
}

export class Storage {
  private dataDir: string;
  private configPath: string;
  private usersPath: string;
  private sessionsDir: string;
  private workspacesDir: string;

  private config: ServerConfig;
  private owner: User | undefined;
  /** Invalid users.json state (malformed owner record) blocks startup in strict single-owner mode. */
  private invalidOwnerData = false;

  constructor(dataDir?: string) {
    this.dataDir = dataDir || DEFAULT_DATA_DIR;
    this.configPath = join(this.dataDir, "config.json");
    this.usersPath = join(this.dataDir, "users.json");
    this.sessionsDir = join(this.dataDir, "sessions");
    this.workspacesDir = join(this.dataDir, "workspaces");

    this.ensureDirectories();
    this.config = this.loadConfig();
    this.loadUsers();
  }

  private ensureDirectories(): void {
    for (const dir of [this.dataDir, this.sessionsDir, this.workspacesDir]) {
      if (!existsSync(dir)) {
        mkdirSync(dir, { recursive: true, mode: 0o700 });
      }
    }
  }

  // ─── Config ───

  static getDefaultConfig(dataDir: string = DEFAULT_DATA_DIR): ServerConfig {
    return createDefaultConfig(dataDir);
  }

  static validateConfig(
    raw: unknown,
    dataDir: string = DEFAULT_DATA_DIR,
    strictUnknown: boolean = true,
  ): ConfigValidationResult {
    const result = normalizeConfig(raw, dataDir, strictUnknown);
    return {
      valid: result.valid,
      errors: result.errors,
      warnings: result.warnings,
      config: result.config,
    };
  }

  static validateConfigFile(
    configPath: string,
    dataDir: string = dirname(configPath),
    strictUnknown: boolean = true,
  ): ConfigValidationResult {
    if (!existsSync(configPath)) {
      return {
        valid: false,
        errors: [`${configPath}: file not found`],
        warnings: [],
      };
    }

    let raw: unknown;
    try {
      raw = JSON.parse(readFileSync(configPath, "utf-8"));
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      return {
        valid: false,
        errors: [`${configPath}: invalid JSON (${message})`],
        warnings: [],
      };
    }

    const result = Storage.validateConfig(raw, dataDir, strictUnknown);
    if (result.errors.length > 0) {
      result.errors = result.errors.map((err) => `${configPath}: ${err}`);
      result.valid = false;
    }
    return result;
  }

  private loadConfig(): ServerConfig {
    const defaults = Storage.getDefaultConfig(this.dataDir);

    if (existsSync(this.configPath)) {
      try {
        const loadedRaw = JSON.parse(readFileSync(this.configPath, "utf-8")) as unknown;
        const normalized = normalizeConfig(loadedRaw, this.dataDir, false);

        for (const err of normalized.errors) {
          console.warn(`[config] ${err} (using default for invalid field)`);
        }
        for (const warning of normalized.warnings) {
          console.warn(`[config] ${warning}`);
        }

        // Safe rewrite only when the normalized config is fully valid.
        // This backfills new defaults (v2 security schema) without
        // accidentally masking invalid user-provided values.
        if (normalized.changed && normalized.errors.length === 0) {
          this.saveConfig(normalized.config);
        }

        return normalized.config;
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        console.warn(`[config] Failed to parse ${this.configPath}: ${message}`);
        console.warn("[config] Falling back to defaults.");
      }
    }

    this.saveConfig(defaults);
    return defaults;
  }

  private saveConfig(config: ServerConfig): void {
    writeFileSync(this.configPath, JSON.stringify(config, null, 2), { mode: 0o600 });
  }

  getConfig(): ServerConfig {
    return this.config;
  }

  getConfigPath(): string {
    return this.configPath;
  }

  updateConfig(updates: Partial<ServerConfig>): void {
    const merged: ServerConfig = {
      ...this.config,
      ...updates,
      security: updates.security ? { ...this.config.security, ...updates.security } : this.config.security,
      identity: updates.identity ? { ...this.config.identity, ...updates.identity } : this.config.identity,
      invite: updates.invite ? { ...this.config.invite, ...updates.invite } : this.config.invite,
    };

    // Keep legacy + new idle timeout fields aligned.
    if (updates.sessionIdleTimeoutMs !== undefined && updates.sessionTimeout === undefined) {
      merged.sessionTimeout = updates.sessionIdleTimeoutMs;
    } else if (updates.sessionTimeout !== undefined && updates.sessionIdleTimeoutMs === undefined) {
      merged.sessionIdleTimeoutMs = updates.sessionTimeout;
    }

    const normalized = normalizeConfig(merged, this.dataDir, false);
    this.config = normalized.config;
    this.saveConfig(this.config);
  }

  // ─── Users ───

  private loadUsers(): void {
    this.owner = undefined;
    this.invalidOwnerData = false;

    if (!existsSync(this.usersPath)) {
      return;
    }

    try {
      const raw = JSON.parse(readFileSync(this.usersPath, "utf-8")) as unknown;
      if (!isUserRecord(raw)) {
        this.invalidOwnerData = true;
        return;
      }

      this.owner = raw;
    } catch {
      this.invalidOwnerData = true;
      this.owner = undefined;
    }
  }

  private saveUsers(): void {
    if (!this.owner) {
      if (existsSync(this.usersPath)) {
        rmSync(this.usersPath);
      }
      return;
    }

    writeFileSync(this.usersPath, JSON.stringify(this.owner, null, 2), { mode: 0o600 });
  }

  createUser(name: string): User {
    const existingOwner = this.getOwnerUser();
    if (existingOwner) {
      throw new Error(
        `Single-user mode: owner already paired (${existingOwner.name}, id=${existingOwner.id})`,
      );
    }

    const id = nanoid(8);
    const token = `sk_${nanoid(24)}`;

    const user: User = {
      id,
      name,
      token,
      createdAt: Date.now(),
    };

    this.owner = user;
    this.invalidOwnerData = false;
    this.saveUsers();

    return user;
  }

  getOwnerUser(): User | undefined {
    return this.owner;
  }

  hasInvalidOwnerData(): boolean {
    return this.invalidOwnerData;
  }

  /**
   * Single-user mode normalizer.
   *
   * - When an owner exists, all user-scoped storage resolves to that owner id.
   * - Before pairing (no owner yet), preserve caller-provided ids for tests/bootstrap.
   */
  private normalizeUserId(userId: string): string {
    const owner = this.getOwnerUser();
    return owner?.id ?? userId;
  }

  updateUserLastSeen(userId: string): void {
    const normalizedUserId = this.normalizeUserId(userId);
    if (!this.owner || this.owner.id !== normalizedUserId) return;

    this.owner.lastSeen = Date.now();
    this.saveUsers();
  }

  // ─── Device Tokens ───

  addDeviceToken(userId: string, token: string): void {
    const normalizedUserId = this.normalizeUserId(userId);
    if (!this.owner || this.owner.id !== normalizedUserId) return;

    if (!this.owner.deviceTokens) this.owner.deviceTokens = [];
    // Deduplicate (same device re-registers)
    if (!this.owner.deviceTokens.includes(token)) {
      this.owner.deviceTokens.push(token);
    }
    this.saveUsers();
  }

  removeDeviceToken(userId: string, token: string): void {
    const normalizedUserId = this.normalizeUserId(userId);
    if (!this.owner || this.owner.id !== normalizedUserId || !this.owner.deviceTokens) return;

    this.owner.deviceTokens = this.owner.deviceTokens.filter((t) => t !== token);
    this.saveUsers();
  }

  /** Remove a token globally (APNs token recycled). */
  removeDeviceTokenGlobal(token: string): void {
    if (!this.owner?.deviceTokens?.includes(token)) return;

    this.owner.deviceTokens = this.owner.deviceTokens.filter((t) => t !== token);
    this.saveUsers();
  }

  getDeviceTokens(userId: string): string[] {
    const normalizedUserId = this.normalizeUserId(userId);
    if (!this.owner || this.owner.id !== normalizedUserId) return [];
    return this.owner.deviceTokens || [];
  }

  setLiveActivityToken(userId: string, token: string | null): void {
    const normalizedUserId = this.normalizeUserId(userId);
    if (!this.owner || this.owner.id !== normalizedUserId) return;

    this.owner.liveActivityToken = token || undefined;
    this.saveUsers();
  }

  getLiveActivityToken(userId: string): string | undefined {
    const normalizedUserId = this.normalizeUserId(userId);
    if (!this.owner || this.owner.id !== normalizedUserId) return undefined;
    return this.owner.liveActivityToken;
  }

  // ─── Sessions ───

  private getSessionPath(_userId: string, sessionId: string): string {
    return join(this.sessionsDir, `${sessionId}.json`);
  }

  createSession(userId: string, name?: string, model?: string): Session {
    const id = nanoid(8);
    const normalizedUserId = this.normalizeUserId(userId);

    const session: Session = {
      id,
      userId: normalizedUserId,
      name,
      status: "starting",
      createdAt: Date.now(),
      lastActivity: Date.now(),
      model: model || this.config.defaultModel,
      messageCount: 0,
      tokens: { input: 0, output: 0 },
      cost: 0,
    };

    this.saveSession(session);
    return session;
  }

  saveSession(session: Session): void {
    const normalizedUserId = this.normalizeUserId(session.userId);
    session.userId = normalizedUserId;

    const path = this.getSessionPath(normalizedUserId, session.id);
    const dir = dirname(path);

    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true, mode: 0o700 });
    }

    // Load existing to preserve messages
    let messages: SessionMessage[] = [];
    if (existsSync(path)) {
      try {
        const existing = JSON.parse(readFileSync(path, "utf-8"));
        messages = existing.messages || [];
      } catch (err) {
        console.error(`[storage] Corrupt session file ${path}, messages will be lost:`, err);
      }
    }

    const payload = JSON.stringify({ session, messages }, null, 2);
    writeFileSync(path, payload, { mode: 0o600 });
  }

  getSession(userId: string, sessionId: string): Session | undefined {
    const normalizedUserId = this.normalizeUserId(userId);
    const path = this.getSessionPath(normalizedUserId, sessionId);
    if (!existsSync(path)) return undefined;

    try {
      const data = JSON.parse(readFileSync(path, "utf-8"));
      if (!data.session) return undefined;
      data.session.userId = normalizedUserId;
      return data.session;
    } catch {
      return undefined;
    }
  }

  listUserSessions(userId: string): Session[] {
    const normalizedUserId = this.normalizeUserId(userId);
    const baseDir = this.sessionsDir;
    if (!existsSync(baseDir)) return [];

    const sessions: Session[] = [];

    for (const file of readdirSync(baseDir)) {
      if (!file.endsWith(".json")) continue;

      try {
        const data = JSON.parse(readFileSync(join(baseDir, file), "utf-8"));
        const session = data.session as Session | undefined;
        if (!session) continue;

        session.userId = normalizedUserId;
        sessions.push(session);
      } catch (err) {
        console.error(`[storage] Corrupt session file ${join(baseDir, file)}, skipping:`, err);
      }
    }

    // Sort by last activity (most recent first)
    return sessions.sort((a, b) => b.lastActivity - a.lastActivity);
  }

  getSessionMessages(userId: string, sessionId: string): SessionMessage[] {
    const normalizedUserId = this.normalizeUserId(userId);
    const path = this.getSessionPath(normalizedUserId, sessionId);
    if (!existsSync(path)) return [];

    try {
      const data = JSON.parse(readFileSync(path, "utf-8"));
      return data.messages || [];
    } catch {
      return [];
    }
  }

  addSessionMessage(
    userId: string,
    sessionId: string,
    message: Omit<SessionMessage, "id" | "sessionId">,
  ): SessionMessage {
    const normalizedUserId = this.normalizeUserId(userId);
    const path = this.getSessionPath(normalizedUserId, sessionId);

    const writeDir = dirname(path);
    if (!existsSync(writeDir)) {
      mkdirSync(writeDir, { recursive: true, mode: 0o700 });
    }

    let data = { session: null as Session | null, messages: [] as SessionMessage[] };
    if (existsSync(path)) {
      try {
        data = JSON.parse(readFileSync(path, "utf-8"));
      } catch (err) {
        console.error(`[storage] Corrupt session file ${path}, data will be reset:`, err);
      }
    }

    const fullMessage: SessionMessage = {
      ...message,
      id: nanoid(8),
      sessionId,
    };

    data.messages.push(fullMessage);

    // Update session stats
    if (data.session) {
      data.session.userId = normalizedUserId;
      data.session.messageCount = data.messages.length;
      data.session.lastActivity = Date.now();
      data.session.lastMessage = message.content.slice(0, 100);

      if (message.tokens) {
        data.session.tokens.input += message.tokens.input;
        data.session.tokens.output += message.tokens.output;
      }
      if (message.cost) {
        data.session.cost += message.cost;
      }
    }

    const payload = JSON.stringify(data, null, 2);
    writeFileSync(path, payload, { mode: 0o600 });

    return fullMessage;
  }

  deleteSession(userId: string, sessionId: string): boolean {
    const normalizedUserId = this.normalizeUserId(userId);
    const path = this.getSessionPath(normalizedUserId, sessionId);
    if (!existsSync(path)) return false;

    rmSync(path);
    return true;
  }

  // ─── Workspaces ───

  private getWorkspacePath(_userId: string, workspaceId: string): string {
    return join(this.workspacesDir, `${workspaceId}.json`);
  }

  createWorkspace(userId: string, req: CreateWorkspaceRequest): Workspace {
    const id = nanoid(8);
    const now = Date.now();
    const normalizedUserId = this.normalizeUserId(userId);

    const policyPreset = req.policyPreset || "container";
    const runtime =
      req.runtime || (!req.hostMount && policyPreset === "container" ? "container" : "host");
    const extensions = normalizeExtensionList(req.extensions);
    const extensionMode = resolveWorkspaceExtensionMode(extensions, req.extensionMode);

    const workspace: Workspace = {
      id,
      userId: normalizedUserId,
      name: req.name,
      description: req.description,
      icon: req.icon,
      runtime,
      skills: req.skills,
      policyPreset,
      systemPrompt: req.systemPrompt,
      hostMount: req.hostMount,
      memoryEnabled: req.memoryEnabled,
      memoryNamespace: req.memoryEnabled ? req.memoryNamespace || `ws-${id}` : req.memoryNamespace,
      extensionMode,
      extensions,
      defaultModel: req.defaultModel,
      createdAt: now,
      updatedAt: now,
    };

    this.saveWorkspace(workspace);
    return workspace;
  }

  saveWorkspace(workspace: Workspace): void {
    const normalizedUserId = this.normalizeUserId(workspace.userId);
    workspace.userId = normalizedUserId;

    const path = this.getWorkspacePath(normalizedUserId, workspace.id);
    const dir = dirname(path);
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true, mode: 0o700 });
    }

    const payload = JSON.stringify(workspace, null, 2);
    writeFileSync(path, payload, { mode: 0o600 });
  }

  private validateWorkspaceRuntime(workspace: Workspace): "host" | "container" {
    if (workspace.runtime === "host" || workspace.runtime === "container") {
      return workspace.runtime;
    }
    throw new Error(`workspace ${workspace.id} missing runtime`);
  }

  getWorkspace(userId: string, workspaceId: string): Workspace | undefined {
    const normalizedUserId = this.normalizeUserId(userId);
    const path = this.getWorkspacePath(normalizedUserId, workspaceId);
    if (!existsSync(path)) return undefined;

    try {
      const ws = JSON.parse(readFileSync(path, "utf-8")) as Workspace;
      ws.userId = normalizedUserId;
      ws.runtime = this.validateWorkspaceRuntime(ws);
      ws.extensions = normalizeExtensionList(ws.extensions);
      ws.extensionMode = resolveWorkspaceExtensionMode(ws.extensions, ws.extensionMode);
      return ws;
    } catch {
      return undefined;
    }
  }

  listWorkspaces(userId: string): Workspace[] {
    const normalizedUserId = this.normalizeUserId(userId);
    const dir = this.workspacesDir;
    if (!existsSync(dir)) return [];

    const workspaces: Workspace[] = [];

    for (const file of readdirSync(dir)) {
      if (!file.endsWith(".json")) continue;
      try {
        const ws = JSON.parse(readFileSync(join(dir, file), "utf-8")) as Workspace;
        ws.userId = normalizedUserId;
        ws.runtime = this.validateWorkspaceRuntime(ws);
        ws.extensions = normalizeExtensionList(ws.extensions);
        ws.extensionMode = resolveWorkspaceExtensionMode(ws.extensions, ws.extensionMode);
        workspaces.push(ws);
      } catch (err) {
        console.error(`[storage] Corrupt workspace file ${join(dir, file)}, skipping:`, err);
      }
    }

    return workspaces.sort((a, b) => a.createdAt - b.createdAt);
  }

  updateWorkspace(
    userId: string,
    workspaceId: string,
    updates: UpdateWorkspaceRequest,
  ): Workspace | undefined {
    const workspace = this.getWorkspace(userId, workspaceId);
    if (!workspace) return undefined;

    if (updates.name !== undefined) workspace.name = updates.name;
    if (updates.description !== undefined) workspace.description = updates.description;
    if (updates.icon !== undefined) workspace.icon = updates.icon;
    if (updates.runtime !== undefined) workspace.runtime = updates.runtime;
    if (updates.skills !== undefined) workspace.skills = updates.skills;
    if (updates.policyPreset !== undefined) workspace.policyPreset = updates.policyPreset;
    if (updates.systemPrompt !== undefined) workspace.systemPrompt = updates.systemPrompt;
    if (updates.hostMount !== undefined) workspace.hostMount = updates.hostMount;
    if (updates.memoryEnabled !== undefined) workspace.memoryEnabled = updates.memoryEnabled;
    if (updates.memoryNamespace !== undefined) workspace.memoryNamespace = updates.memoryNamespace;
    if (updates.extensionMode !== undefined) workspace.extensionMode = updates.extensionMode;
    if (updates.extensions !== undefined) {
      workspace.extensions = normalizeExtensionList(updates.extensions);
    }
    if (
      workspace.memoryEnabled &&
      (!workspace.memoryNamespace || workspace.memoryNamespace.trim().length === 0)
    ) {
      workspace.memoryNamespace = `ws-${workspace.id}`;
    }
    workspace.extensionMode = resolveWorkspaceExtensionMode(
      workspace.extensions,
      workspace.extensionMode,
    );
    if (updates.defaultModel !== undefined) workspace.defaultModel = updates.defaultModel;
    workspace.updatedAt = Date.now();

    this.saveWorkspace(workspace);
    return workspace;
  }

  deleteWorkspace(userId: string, workspaceId: string): boolean {
    const normalizedUserId = this.normalizeUserId(userId);
    const path = this.getWorkspacePath(normalizedUserId, workspaceId);
    if (!existsSync(path)) return false;

    rmSync(path);
    return true;
  }

  /**
   * Ensure a user has at least one workspace. Seeds defaults if empty.
   */
  ensureDefaultWorkspaces(userId: string): void {
    const existing = this.listWorkspaces(userId);
    if (existing.length > 0) return;

    this.createWorkspace(userId, {
      name: "general",
      description: "General-purpose agent with web search and browsing",
      icon: "terminal",
      skills: ["searxng", "fetch", "web-browser"],
      policyPreset: "container",
      memoryEnabled: true,
      memoryNamespace: "general",
    });

    this.createWorkspace(userId, {
      name: "research",
      description: "Deep research with search, web, and transcription",
      icon: "magnifyingglass",
      skills: ["searxng", "fetch", "web-browser", "deep-research", "youtube-transcript"],
      policyPreset: "container",
      memoryEnabled: true,
      memoryNamespace: "research",
    });
  }

  // ─── Helpers ───

  getDataDir(): string {
    return this.dataDir;
  }
}
