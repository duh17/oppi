/**
 * Persistent storage for oppi-server
 *
 * Data directory structure:
 * ~/.config/oppi/
 * ├── config.json       # Server config
 * ├── users.json        # Owner identity & token (single-user)
 * ├── sessions/
 * │   └── <sessionId>.json      # Flat owner layout (single-user mode)
 * └── workspaces/
 *     └── <workspaceId>.json    # Flat owner layout (single-user mode)
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir, hostname } from "node:os";
import { generateId } from "./id.js";
import type {
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

const DEFAULT_DATA_DIR = join(homedir(), ".config", "oppi");
const CONFIG_VERSION = 2;
const SECURITY_PROFILES: ReadonlySet<SecurityProfile> = new Set([
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
    sessionIdleTimeoutMs: 10 * 60 * 1000,
    workspaceIdleTimeoutMs: 30 * 60 * 1000,
    maxSessionsPerWorkspace: 3,
    maxSessionsGlobal: 5,
    approvalTimeoutMs: 120 * 1000,

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
    "sessionIdleTimeoutMs",
    "workspaceIdleTimeoutMs",
    "maxSessionsPerWorkspace",
    "maxSessionsGlobal",
    "approvalTimeoutMs",

    "security",
    "identity",
    "invite",
    "token",
    "deviceTokens",
    "liveActivityToken",
    "thinkingLevelByModel",
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

  // Accept legacy "sessionTimeout" as alias for sessionIdleTimeoutMs
  const sessionIdleTimeoutMs = readNumber("sessionIdleTimeoutMs", { min: 1 })
    ?? readNumber("sessionTimeout", { min: 1 });
  if (sessionIdleTimeoutMs !== undefined) {
    config.sessionIdleTimeoutMs = sessionIdleTimeoutMs;
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

      // Migrate removed "legacy" profile to default
      if (rawSecurity.profile === "legacy") {
        rawSecurity.profile = "tailscale-permissive";
        changed = true;
      }

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

  // Pairing token + runtime state — passthrough (no validation, optional)
  if ("token" in obj && typeof obj.token === "string") {
    config.token = obj.token;
  }
  if ("deviceTokens" in obj && Array.isArray(obj.deviceTokens)) {
    config.deviceTokens = (obj.deviceTokens as unknown[]).filter((t): t is string => typeof t === "string");
  }
  if ("liveActivityToken" in obj && typeof obj.liveActivityToken === "string") {
    config.liveActivityToken = obj.liveActivityToken;
  }
  if ("thinkingLevelByModel" in obj && isRecord(obj.thinkingLevelByModel)) {
    const map: Record<string, string> = {};
    for (const [k, v] of Object.entries(obj.thinkingLevelByModel as Record<string, unknown>)) {
      if (typeof v === "string") map[k] = v;
    }
    config.thinkingLevelByModel = map;
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

export class Storage {
  private dataDir: string;
  private configPath: string;
  private sessionsDir: string;
  private workspacesDir: string;

  private config: ServerConfig;

  constructor(dataDir?: string) {
    this.dataDir = dataDir || DEFAULT_DATA_DIR;
    this.configPath = join(this.dataDir, "config.json");
    this.sessionsDir = join(this.dataDir, "sessions");
    this.workspacesDir = join(this.dataDir, "workspaces");

    this.ensureDirectories();
    this.config = this.loadConfig();
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

    const normalized = normalizeConfig(merged, this.dataDir, false);
    this.config = normalized.config;
    this.saveConfig(this.config);
  }

  // ─── Pairing ───

  private static generateToken(): string {
    return `sk_${generateId(24)}`;
  }

  /** Whether the server has been paired (has a bearer token). */
  isPaired(): boolean {
    return !!this.config.token;
  }

  /** Get the bearer token (undefined if not paired). */
  getToken(): string | undefined {
    return this.config.token;
  }

  /** Generate a new token and save to config. Returns the token. */
  ensurePaired(): string {
    if (this.config.token) return this.config.token;
    const token = Storage.generateToken();
    this.updateConfig({ token });
    return token;
  }

  /** Rotate the bearer token. Existing clients will need to re-pair. */
  rotateToken(): string {
    const token = Storage.generateToken();
    this.updateConfig({ token });
    return token;
  }

  /** Owner display name derived from hostname. */
  getOwnerName(): string {
    return hostname().split(".")[0] || "owner";
  }

  // ─── Device Tokens ───

  addDeviceToken(token: string): void {
    const tokens = this.config.deviceTokens || [];
    if (!tokens.includes(token)) {
      this.updateConfig({ deviceTokens: [...tokens, token] });
    }
  }

  removeDeviceToken(token: string): void {
    const tokens = this.config.deviceTokens || [];
    this.updateConfig({ deviceTokens: tokens.filter((t) => t !== token) });
  }

  getDeviceTokens(): string[] {
    return this.config.deviceTokens || [];
  }

  setLiveActivityToken(token: string | null): void {
    this.updateConfig({ liveActivityToken: token || undefined });
  }

  getLiveActivityToken(): string | undefined {
    return this.config.liveActivityToken;
  }

  // ─── Thinking Preferences ───

  getModelThinkingLevelPreference(modelId: string): string | undefined {
    const normalized = modelId.trim();
    if (!normalized) return undefined;
    return this.config.thinkingLevelByModel?.[normalized];
  }

  setModelThinkingLevelPreference(modelId: string, level: string): void {
    const normalizedModel = modelId.trim();
    const normalizedLevel = level.trim();
    if (!normalizedModel || !normalizedLevel) return;

    const current = this.config.thinkingLevelByModel || {};
    if (current[normalizedModel] === normalizedLevel) return;

    this.updateConfig({
      thinkingLevelByModel: { ...current, [normalizedModel]: normalizedLevel },
    });
  }

  // ─── Sessions ───

  private getSessionPath(sessionId: string): string {
    return join(this.sessionsDir, `${sessionId}.json`);
  }

  createSession(name?: string, model?: string): Session {
    const id = generateId(8);

    const session: Session = {
      id,
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

    const path = this.getSessionPath(session.id);
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

  getSession(sessionId: string): Session | undefined {
    const path = this.getSessionPath(sessionId);
    if (!existsSync(path)) return undefined;

    try {
      const data = JSON.parse(readFileSync(path, "utf-8"));
      if (!data.session) return undefined;
      return data.session;
    } catch {
      return undefined;
    }
  }

  listSessions(): Session[] {
    const baseDir = this.sessionsDir;
    if (!existsSync(baseDir)) return [];

    const sessions: Session[] = [];

    for (const file of readdirSync(baseDir)) {
      if (!file.endsWith(".json")) continue;

      try {
        const data = JSON.parse(readFileSync(join(baseDir, file), "utf-8"));
        const session = data.session as Session | undefined;
        if (!session) continue;
        sessions.push(session);
      } catch (err) {
        console.error(`[storage] Corrupt session file ${join(baseDir, file)}, skipping:`, err);
      }
    }

    // Sort by last activity (most recent first)
    return sessions.sort((a, b) => b.lastActivity - a.lastActivity);
  }

  getSessionMessages(sessionId: string): SessionMessage[] {
    const path = this.getSessionPath(sessionId);
    if (!existsSync(path)) return [];

    try {
      const data = JSON.parse(readFileSync(path, "utf-8"));
      return data.messages || [];
    } catch {
      return [];
    }
  }

  addSessionMessage(
    sessionId: string,
    message: Omit<SessionMessage, "id" | "sessionId">,
  ): SessionMessage {
    const path = this.getSessionPath(sessionId);

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
      id: generateId(8),
      sessionId,
    };

    data.messages.push(fullMessage);

    // Update session stats
    if (data.session) {
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

  deleteSession(sessionId: string): boolean {
    const path = this.getSessionPath(sessionId);
    if (!existsSync(path)) return false;

    rmSync(path);
    return true;
  }

  // ─── Workspaces ───

  private getWorkspacePath(workspaceId: string): string {
    return join(this.workspacesDir, `${workspaceId}.json`);
  }

  createWorkspace(req: CreateWorkspaceRequest): Workspace {
    const id = generateId(8);
    const now = Date.now();

    const policyPreset = req.policyPreset || "container";
    const runtime =
      req.runtime || (!req.hostMount && policyPreset === "container" ? "container" : "host");
    const extensions = normalizeExtensionList(req.extensions);

    const workspace: Workspace = {
      id,
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
      extensions,
      defaultModel: req.defaultModel,
      createdAt: now,
      updatedAt: now,
    };

    this.saveWorkspace(workspace);
    return workspace;
  }

  saveWorkspace(workspace: Workspace): void {

    const path = this.getWorkspacePath(workspace.id);
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

  getWorkspace(workspaceId: string): Workspace | undefined {
    const path = this.getWorkspacePath(workspaceId);
    if (!existsSync(path)) return undefined;

    try {
      const ws = JSON.parse(readFileSync(path, "utf-8")) as Workspace;
      ws.runtime = this.validateWorkspaceRuntime(ws);
      ws.extensions = normalizeExtensionList(ws.extensions);
      return ws;
    } catch {
      return undefined;
    }
  }

  listWorkspaces(): Workspace[] {
    const dir = this.workspacesDir;
    if (!existsSync(dir)) return [];

    const workspaces: Workspace[] = [];

    for (const file of readdirSync(dir)) {
      if (!file.endsWith(".json")) continue;
      try {
        const ws = JSON.parse(readFileSync(join(dir, file), "utf-8")) as Workspace;
        ws.runtime = this.validateWorkspaceRuntime(ws);
        ws.extensions = normalizeExtensionList(ws.extensions);
        workspaces.push(ws);
      } catch (err) {
        console.error(`[storage] Corrupt workspace file ${join(dir, file)}, skipping:`, err);
      }
    }

    return workspaces.sort((a, b) => a.createdAt - b.createdAt);
  }

  updateWorkspace(
    workspaceId: string,
    updates: UpdateWorkspaceRequest,
  ): Workspace | undefined {
    const workspace = this.getWorkspace(workspaceId);
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
      policyPreset: "container",
      memoryEnabled: true,
      memoryNamespace: "general",
    });

    this.createWorkspace({
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
