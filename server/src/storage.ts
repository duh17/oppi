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
import { isIP } from "node:net";
import { generateId } from "./id.js";
import { defaultPolicy } from "./policy.js";
import type {
  Session,
  SessionMessage,
  ServerConfig,
  Workspace,
  CreateWorkspaceRequest,
  UpdateWorkspaceRequest,
} from "./types.js";

const DEFAULT_DATA_DIR = join(homedir(), ".config", "oppi");
const CONFIG_VERSION = 2;

export interface ConfigValidationResult {
  valid: boolean;
  errors: string[];
  warnings: string[];
  config?: ServerConfig;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isValidCidr(value: string): boolean {
  const parts = value.trim().split("/");
  if (parts.length !== 2) return false;

  const base = parts[0].trim();
  const prefix = Number(parts[1]);
  if (!Number.isInteger(prefix)) return false;

  const family = isIP(base);
  if (family === 4) return prefix >= 0 && prefix <= 32;
  if (family === 6) return prefix >= 0 && prefix <= 128;
  return false;
}

function defaultAllowedCidrs(): string[] {
  // Loopback + RFC1918 + CGNAT (Tailscale IPv4 range) + link-local + ULA.
  return [
    "127.0.0.0/8",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "100.64.0.0/10",
    "169.254.0.0/16",
    "::1/128",
    "fc00::/7",
    "fe80::/10",
  ];
}



function createDefaultConfig(dataDir: string): ServerConfig {
  return {
    configVersion: CONFIG_VERSION,
    port: 7749,
    host: "0.0.0.0",
    dataDir,
    defaultModel: "openai-codex/gpt-5.3-codex",
    sessionIdleTimeoutMs: 10 * 60 * 1000,
    workspaceIdleTimeoutMs: 30 * 60 * 1000,
    maxSessionsPerWorkspace: 3,
    maxSessionsGlobal: 5,
    approvalTimeoutMs: 120 * 1000,

    allowedCidrs: defaultAllowedCidrs(),
    policy: defaultPolicy(),
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
    allowedCidrs: defaultAllowedCidrs(),
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
    "allowedCidrs",
    "policy",

    "security",
    "identity",
    "invite",
    "token",
    "pairingToken",
    "pairingTokenExpiresAt",
    "authDeviceTokens",
    "pushDeviceTokens",
    "deviceTokens", // legacy alias (migrated to pushDeviceTokens)
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

  const allowedCidrsDefaults = defaultAllowedCidrs();
  const parseAllowedCidrs = (value: unknown, path: string): string[] | null => {
    if (!Array.isArray(value)) {
      errors.push(`${path}: expected array of CIDR strings`);
      changed = true;
      return null;
    }

    const parsed: string[] = [];
    for (let i = 0; i < value.length; i++) {
      const item = value[i];
      if (typeof item !== "string" || !isValidCidr(item)) {
        errors.push(`${path}[${i}]: expected CIDR like 192.168.0.0/16`);
        changed = true;
        continue;
      }
      parsed.push(item.trim());
    }

    if (parsed.length === 0) {
      errors.push(`${path}: must contain at least one valid CIDR`);
      changed = true;
      return null;
    }

    return parsed;
  };

  let hasTopLevelAllowedCidrs = false;
  if (!("allowedCidrs" in obj)) {
    changed = true;
    config.allowedCidrs = allowedCidrsDefaults;
  } else {
    hasTopLevelAllowedCidrs = true;
    const parsed = parseAllowedCidrs(obj.allowedCidrs, "config.allowedCidrs");
    if (parsed) config.allowedCidrs = parsed;
  }

  const parsePolicyConfig = (
    value: unknown,
    path: string,
  ): NonNullable<ServerConfig["policy"]> | null => {
    if (!isRecord(value)) {
      errors.push(`${path}: expected object`);
      changed = true;
      return null;
    }

    const allowed = new Set([
      "schemaVersion",
      "mode",
      "description",
      "fallback",
      "guardrails",
      "permissions",
      "heuristics",
    ]);

    if (strictUnknown) {
      for (const key of Object.keys(value)) {
        if (!allowed.has(key)) {
          errors.push(`${path}.${key}: unknown key`);
        }
      }
    }

    const parseDecision = (
      raw: unknown,
      decisionPath: string,
    ): "allow" | "ask" | "block" | null => {
      if (raw === "allow" || raw === "ask" || raw === "block") return raw;
      errors.push(`${decisionPath}: expected one of allow|ask|block`);
      changed = true;
      return null;
    };

    const parseMatch = (
      raw: unknown,
      matchPath: string,
    ): {
      tool?: string;
      executable?: string;
      commandMatches?: string;
      pathMatches?: string;
      pathWithin?: string;
      domain?: string;
    } | null => {
      if (!isRecord(raw)) {
        errors.push(`${matchPath}: expected object`);
        changed = true;
        return null;
      }

      const allowedMatchKeys = new Set([
        "tool",
        "executable",
        "commandMatches",
        "pathMatches",
        "pathWithin",
        "domain",
      ]);

      if (strictUnknown) {
        for (const key of Object.keys(raw)) {
          if (!allowedMatchKeys.has(key)) {
            errors.push(`${matchPath}.${key}: unknown key`);
          }
        }
      }

      const out: {
        tool?: string;
        executable?: string;
        commandMatches?: string;
        pathMatches?: string;
        pathWithin?: string;
        domain?: string;
      } = {};

      const readOptionalString = (k: keyof typeof out): void => {
        if (!(k in raw)) return;
        const v = raw[k];
        if (typeof v !== "string" || v.trim().length === 0) {
          errors.push(`${matchPath}.${k}: expected non-empty string`);
          changed = true;
          return;
        }
        out[k] = v;
      };

      readOptionalString("tool");
      readOptionalString("executable");
      readOptionalString("commandMatches");
      readOptionalString("pathMatches");
      readOptionalString("pathWithin");
      readOptionalString("domain");

      if (Object.keys(out).length === 0) {
        errors.push(`${matchPath}: expected at least one match field`);
        changed = true;
        return null;
      }

      return out;
    };

    const parsePermission = (
      raw: unknown,
      permPath: string,
    ): {
      id: string;
      decision: "allow" | "ask" | "block";
      label?: string;
      reason?: string;
      immutable?: boolean;
      match: {
        tool?: string;
        executable?: string;
        commandMatches?: string;
        pathMatches?: string;
        pathWithin?: string;
        domain?: string;
      };
    } | null => {
      if (!isRecord(raw)) {
        errors.push(`${permPath}: expected object`);
        changed = true;
        return null;
      }

      const allowedPermKeys = new Set([
        "id",
        "decision",
        "risk",
        "label",
        "reason",
        "immutable",
        "match",
      ]);

      if (strictUnknown) {
        for (const key of Object.keys(raw)) {
          if (!allowedPermKeys.has(key)) {
            errors.push(`${permPath}.${key}: unknown key`);
          }
        }
      }

      if (typeof raw.id !== "string" || !/^[a-z0-9][a-z0-9._-]{2,63}$/.test(raw.id)) {
        errors.push(`${permPath}.id: expected slug-like id (3-64 chars)`);
        changed = true;
        return null;
      }

      const decision = parseDecision(raw.decision, `${permPath}.decision`);
      if (!decision) return null;

      // "risk" is accepted for backwards compatibility but ignored
      let label: string | undefined;
      if ("label" in raw) {
        if (typeof raw.label === "string" && raw.label.trim().length > 0) {
          label = raw.label;
        } else {
          errors.push(`${permPath}.label: expected non-empty string`);
          changed = true;
        }
      }

      let reason: string | undefined;
      if ("reason" in raw) {
        if (typeof raw.reason === "string" && raw.reason.trim().length > 0) {
          reason = raw.reason;
        } else {
          errors.push(`${permPath}.reason: expected non-empty string`);
          changed = true;
        }
      }

      let immutable: boolean | undefined;
      if ("immutable" in raw) {
        if (typeof raw.immutable === "boolean") {
          immutable = raw.immutable;
        } else {
          errors.push(`${permPath}.immutable: expected boolean`);
          changed = true;
        }
      }

      const match = parseMatch(raw.match, `${permPath}.match`);
      if (!match) return null;

      return {
        id: raw.id,
        decision,
        label,
        reason,
        immutable,
        match,
      };
    };

    if (value.schemaVersion !== 1) {
      errors.push(`${path}.schemaVersion: expected 1`);
      changed = true;
      return null;
    }

    let mode: string | undefined;
    if ("mode" in value) {
      if (typeof value.mode === "string" && value.mode.trim().length > 0) {
        mode = value.mode;
      } else {
        errors.push(`${path}.mode: expected non-empty string`);
        changed = true;
      }
    }

    let description: string | undefined;
    if ("description" in value) {
      if (typeof value.description === "string") {
        description = value.description;
      } else {
        errors.push(`${path}.description: expected string`);
        changed = true;
      }
    }

    const fallback = parseDecision(value.fallback, `${path}.fallback`);
    if (!fallback) return null;

    if (!Array.isArray(value.guardrails)) {
      errors.push(`${path}.guardrails: expected array`);
      changed = true;
      return null;
    }
    if (!Array.isArray(value.permissions)) {
      errors.push(`${path}.permissions: expected array`);
      changed = true;
      return null;
    }

    const guardrails = value.guardrails
      .map((entry, i) => parsePermission(entry, `${path}.guardrails[${i}]`))
      .filter((entry): entry is NonNullable<typeof entry> => entry !== null);

    const permissions = value.permissions
      .map((entry, i) => parsePermission(entry, `${path}.permissions[${i}]`))
      .filter((entry): entry is NonNullable<typeof entry> => entry !== null);

    // Parse heuristics (optional — omitted means use defaults)
    let heuristics: import("./types.js").PolicyHeuristics | undefined;
    if ("heuristics" in value && value.heuristics != null) {
      if (!isRecord(value.heuristics)) {
        errors.push(`${path}.heuristics: expected object`);
        changed = true;
      } else {
        const h = value.heuristics;
        const validHeuristicKeys = new Set([
          "pipeToShell",
          "dataEgress",
          "secretEnvInUrl",
          "secretFileAccess",
          "browserUnknownDomain",
          "browserEval",
        ]);

        if (strictUnknown) {
          for (const key of Object.keys(h)) {
            if (!validHeuristicKeys.has(key)) {
              errors.push(`${path}.heuristics.${key}: unknown key`);
            }
          }
        }

        const parseHeuristicValue = (
          raw: unknown,
          hPath: string,
        ): "allow" | "ask" | "block" | false | undefined => {
          if (raw === undefined) return undefined;
          if (raw === false) return false;
          if (raw === "allow" || raw === "ask" || raw === "block") return raw;
          errors.push(`${hPath}: expected one of allow|ask|block or false`);
          changed = true;
          return undefined;
        };

        heuristics = {};
        for (const key of validHeuristicKeys) {
          if (key in h) {
            const val = parseHeuristicValue(h[key], `${path}.heuristics.${key}`);
            if (val !== undefined) {
              (heuristics as Record<string, unknown>)[key] = val;
            }
          }
        }
      }
    }

    const result: NonNullable<ServerConfig["policy"]> = {
      schemaVersion: 1,
      mode,
      description,
      fallback,
      guardrails,
      permissions,
    };
    if (heuristics) result.heuristics = heuristics;
    return result;
  };

  if ("policy" in obj) {
    const parsed = parsePolicyConfig(obj.policy, "config.policy");
    if (parsed) config.policy = parsed;
  } else {
    changed = true;
  }

  if ("security" in obj) {
    const rawSecurity = obj.security;
    if (!isRecord(rawSecurity)) {
      errors.push("config.security: expected object");
      changed = true;
    } else {
      const allowed = new Set([
        "profile",
        "requireTlsOutsideTailnet",
        "allowInsecureHttpInTailnet",
        "requirePinnedServerIdentity",
        "allowedCidrs",
      ]);
      if (strictUnknown) {
        for (const key of Object.keys(rawSecurity)) {
          if (!allowed.has(key)) {
            errors.push(`config.security.${key}: unknown key`);
          }
        }
      }

      const deprecatedKeys = [
        "profile",
        "requireTlsOutsideTailnet",
        "allowInsecureHttpInTailnet",
        "requirePinnedServerIdentity",
      ] as const;
      for (const key of deprecatedKeys) {
        if (key in rawSecurity) {
          warnings.push(`config.security.${key} is deprecated and ignored.`);
          changed = true;
        }
      }

      if ("allowedCidrs" in rawSecurity) {
        if (!hasTopLevelAllowedCidrs) {
          const parsedLegacy = parseAllowedCidrs(rawSecurity.allowedCidrs, "config.security.allowedCidrs");
          if (parsedLegacy) {
            config.allowedCidrs = parsedLegacy;
            warnings.push("config.security.allowedCidrs is deprecated; migrated to config.allowedCidrs.");
            changed = true;
          }
        } else {
          warnings.push("config.security.allowedCidrs is deprecated and ignored in favor of config.allowedCidrs.");
          changed = true;
        }
      }
    }
  }

  if ("identity" in obj) {
    warnings.push("config.identity is deprecated and ignored.");
    changed = true;
  }

  if ("invite" in obj) {
    warnings.push("config.invite is deprecated and ignored.");
    changed = true;
  }

  // Pairing/auth/push runtime state — passthrough (no strict schema validation, optional)
  if ("token" in obj && typeof obj.token === "string") {
    config.token = obj.token;
  }

  if ("pairingToken" in obj && typeof obj.pairingToken === "string") {
    config.pairingToken = obj.pairingToken;
  }

  if ("pairingTokenExpiresAt" in obj
    && typeof obj.pairingTokenExpiresAt === "number"
    && Number.isFinite(obj.pairingTokenExpiresAt)
  ) {
    config.pairingTokenExpiresAt = obj.pairingTokenExpiresAt;
  }

  if ("authDeviceTokens" in obj && Array.isArray(obj.authDeviceTokens)) {
    config.authDeviceTokens = (obj.authDeviceTokens as unknown[]).filter(
      (t): t is string => typeof t === "string",
    );
  }

  if ("pushDeviceTokens" in obj && Array.isArray(obj.pushDeviceTokens)) {
    config.pushDeviceTokens = (obj.pushDeviceTokens as unknown[]).filter(
      (t): t is string => typeof t === "string",
    );
  }

  // Legacy migration: `deviceTokens` historically mixed push + auth semantics.
  // Safety-first migration maps legacy values to push storage only.
  if ("deviceTokens" in obj && Array.isArray(obj.deviceTokens)) {
    const legacyTokens = (obj.deviceTokens as unknown[]).filter(
      (t): t is string => typeof t === "string",
    );

    if (legacyTokens.length > 0) {
      warnings.push(
        "config.deviceTokens is deprecated; migrated to config.pushDeviceTokens (not used for API auth).",
      );
      changed = true;

      const mergedPushTokens = [...(config.pushDeviceTokens || [])];
      for (const token of legacyTokens) {
        if (!mergedPushTokens.includes(token)) {
          mergedPushTokens.push(token);
        }
      }
      config.pushDeviceTokens = mergedPushTokens;
    }
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
    };

    const normalized = normalizeConfig(merged, this.dataDir, false);
    this.config = normalized.config;
    this.saveConfig(this.config);
  }

  // ─── Pairing ───

  private static generateOwnerToken(): string {
    return `sk_${generateId(24)}`;
  }

  private static generateAuthDeviceToken(): string {
    return `dt_${generateId(24)}`;
  }

  private static generatePairingToken(): string {
    return `pt_${generateId(24)}`;
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
    const token = Storage.generateOwnerToken();
    this.updateConfig({ token });
    return token;
  }

  /** Rotate the bearer token. Existing clients will need to re-pair. */
  rotateToken(): string {
    const token = Storage.generateOwnerToken();
    this.updateConfig({ token });
    return token;
  }

  /** Issue a one-time short-lived pairing token used by POST /pair. */
  issuePairingToken(ttlMs: number = 90_000): string {
    const pairingToken = Storage.generatePairingToken();
    const expiresAt = Date.now() + Math.max(1_000, ttlMs);
    this.updateConfig({ pairingToken, pairingTokenExpiresAt: expiresAt });
    return pairingToken;
  }

  /** Consume pairing token atomically and issue a long-lived auth device token. */
  consumePairingToken(candidate: string): string | null {
    const pairingToken = this.config.pairingToken;
    const expiresAt = this.config.pairingTokenExpiresAt;

    if (!pairingToken || candidate !== pairingToken) {
      return null;
    }

    if (typeof expiresAt === "number" && Date.now() > expiresAt) {
      this.updateConfig({ pairingToken: undefined, pairingTokenExpiresAt: undefined });
      return null;
    }

    let deviceToken = Storage.generateAuthDeviceToken();
    const existing = new Set(this.config.authDeviceTokens || []);
    while (existing.has(deviceToken)) {
      deviceToken = Storage.generateAuthDeviceToken();
    }

    this.updateConfig({
      authDeviceTokens: [...existing, deviceToken],
      pairingToken: undefined,
      pairingTokenExpiresAt: undefined,
    });

    return deviceToken;
  }

  /** Owner display name derived from hostname. */
  getOwnerName(): string {
    return hostname().split(".")[0] || "owner";
  }

  // ─── Device/Auth Tokens ───

  addAuthDeviceToken(token: string): void {
    const tokens = this.config.authDeviceTokens || [];
    if (!tokens.includes(token)) {
      this.updateConfig({ authDeviceTokens: [...tokens, token] });
    }
  }

  removeAuthDeviceToken(token: string): void {
    const tokens = this.config.authDeviceTokens || [];
    this.updateConfig({ authDeviceTokens: tokens.filter((t) => t !== token) });
  }

  getAuthDeviceTokens(): string[] {
    return this.config.authDeviceTokens || [];
  }

  // ─── Push Tokens ───

  addPushDeviceToken(token: string): void {
    const tokens = this.config.pushDeviceTokens || [];
    if (!tokens.includes(token)) {
      this.updateConfig({ pushDeviceTokens: [...tokens, token] });
    }
  }

  removePushDeviceToken(token: string): void {
    const tokens = this.config.pushDeviceTokens || [];
    this.updateConfig({ pushDeviceTokens: tokens.filter((t) => t !== token) });
  }

  getPushDeviceTokens(): string[] {
    return this.config.pushDeviceTokens || [];
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

    const extensions = normalizeExtensionList(req.extensions);

    const workspace: Workspace = {
      id,
      name: req.name,
      description: req.description,
      icon: req.icon,
      skills: req.skills,
      policy: req.policy,
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
      policy: (() => {
        if (!raw.policy || typeof raw.policy !== "object") {
          return { permissions: [] };
        }

        const policyRaw = raw.policy as Record<string, unknown>;
        const permissions = Array.isArray(policyRaw.permissions)
          ? (policyRaw.permissions as NonNullable<Workspace["policy"]>["permissions"])
          : [];

        const fallbackRaw = policyRaw.fallback;
        const fallback =
          fallbackRaw === "allow" || fallbackRaw === "ask" || fallbackRaw === "block"
            ? fallbackRaw
            : undefined;

        return fallback ? { permissions, fallback } : { permissions };
      })(),
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
    const dir = this.workspacesDir;
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

  updateWorkspace(
    workspaceId: string,
    updates: UpdateWorkspaceRequest,
  ): Workspace | undefined {
    const workspace = this.getWorkspace(workspaceId);
    if (!workspace) return undefined;

    if (updates.name !== undefined) workspace.name = updates.name;
    if (updates.description !== undefined) workspace.description = updates.description;
    if (updates.icon !== undefined) workspace.icon = updates.icon;
    if (updates.skills !== undefined) workspace.skills = updates.skills;
    if (updates.policy !== undefined) workspace.policy = updates.policy;
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

  getWorkspacePolicy(workspaceId: string): Workspace["policy"] | undefined {
    const workspace = this.getWorkspace(workspaceId);
    if (!workspace) return undefined;
    return workspace.policy || { permissions: [] };
  }

  setWorkspacePolicyPermissions(
    workspaceId: string,
    permissions: NonNullable<Workspace["policy"]>["permissions"],
    fallback?: NonNullable<Workspace["policy"]>["fallback"],
  ): Workspace | undefined {
    const workspace = this.getWorkspace(workspaceId);
    if (!workspace) return undefined;

    const nextFallback = fallback ?? workspace.policy?.fallback;
    workspace.policy = nextFallback ? { permissions, fallback: nextFallback } : { permissions };
    workspace.updatedAt = Date.now();
    this.saveWorkspace(workspace);
    return workspace;
  }

  deleteWorkspacePolicyPermission(workspaceId: string, permissionId: string): Workspace | undefined {
    const workspace = this.getWorkspace(workspaceId);
    if (!workspace) return undefined;

    const policy = workspace.policy || { permissions: [] };
    const next = policy.permissions.filter((p) => p.id !== permissionId);
    workspace.policy = policy.fallback ? { permissions: next, fallback: policy.fallback } : { permissions: next };
    workspace.updatedAt = Date.now();
    this.saveWorkspace(workspace);
    return workspace;
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

  // ─── Helpers ───

  getDataDir(): string {
    return this.dataDir;
  }
}
