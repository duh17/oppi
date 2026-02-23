import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { isIP } from "node:net";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { defaultPolicy } from "../policy.js";
import type { PolicyHeuristics, ServerConfig } from "../types.js";

export const DEFAULT_DATA_DIR = join(homedir(), ".config", "oppi");
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
  // Loopback + RFC1918 + CGNAT (covers Tailscale, carrier-grade NAT) + link-local + ULA.
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
    permissionGate: true,

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
    "permissionGate",
    "allowedCidrs",
    "policy",

    "token",
    "pairingToken",
    "pairingTokenExpiresAt",
    "authDeviceTokens",
    "pushDeviceTokens",
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

  const readNumber = (
    key: string,
    opts?: { min?: number; integer?: boolean },
  ): number | undefined => {
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

  const port = readNumber("port", { min: 0 });
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

  // Accept "sessionTimeout" as an alias for sessionIdleTimeoutMs
  const sessionIdleTimeoutMs =
    readNumber("sessionIdleTimeoutMs", { min: 1 }) ?? readNumber("sessionTimeout", { min: 1 });
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

  if (typeof raw.permissionGate === "boolean") {
    config.permissionGate = raw.permissionGate;
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

  if (!("allowedCidrs" in obj)) {
    changed = true;
    config.allowedCidrs = allowedCidrsDefaults;
  } else {
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
      rawDecision: unknown,
      decisionPath: string,
    ): "allow" | "ask" | "block" | null => {
      if (rawDecision === "allow" || rawDecision === "ask" || rawDecision === "block") {
        return rawDecision;
      }
      errors.push(`${decisionPath}: expected one of allow|ask|block`);
      changed = true;
      return null;
    };

    const parseMatch = (
      rawMatch: unknown,
      matchPath: string,
    ): {
      tool?: string;
      executable?: string;
      commandMatches?: string;
      pathMatches?: string;
      pathWithin?: string;
      domain?: string;
    } | null => {
      if (!isRecord(rawMatch)) {
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
        for (const key of Object.keys(rawMatch)) {
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
        if (!(k in rawMatch)) return;
        const v = rawMatch[k];
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
      rawPermission: unknown,
      permPath: string,
    ): {
      id: string;
      decision: "allow" | "ask" | "block";
      label?: string;
      reason?: string;
      match: {
        tool?: string;
        executable?: string;
        commandMatches?: string;
        pathMatches?: string;
        pathWithin?: string;
        domain?: string;
      };
    } | null => {
      if (!isRecord(rawPermission)) {
        errors.push(`${permPath}: expected object`);
        changed = true;
        return null;
      }

      const allowedPermKeys = new Set(["id", "decision", "risk", "label", "reason", "match"]);

      if (strictUnknown) {
        for (const key of Object.keys(rawPermission)) {
          if (!allowedPermKeys.has(key)) {
            errors.push(`${permPath}.${key}: unknown key`);
          }
        }
      }

      if (
        typeof rawPermission.id !== "string" ||
        !/^[a-z0-9][a-z0-9._-]{2,63}$/.test(rawPermission.id)
      ) {
        errors.push(`${permPath}.id: expected slug-like id (3-64 chars)`);
        changed = true;
        return null;
      }

      const decision = parseDecision(rawPermission.decision, `${permPath}.decision`);
      if (!decision) return null;

      // "risk" is ignored when present.
      let label: string | undefined;
      if ("label" in rawPermission) {
        if (typeof rawPermission.label === "string" && rawPermission.label.trim().length > 0) {
          label = rawPermission.label;
        } else {
          errors.push(`${permPath}.label: expected non-empty string`);
          changed = true;
        }
      }

      let reason: string | undefined;
      if ("reason" in rawPermission) {
        if (typeof rawPermission.reason === "string" && rawPermission.reason.trim().length > 0) {
          reason = rawPermission.reason;
        } else {
          errors.push(`${permPath}.reason: expected non-empty string`);
          changed = true;
        }
      }

      const match = parseMatch(rawPermission.match, `${permPath}.match`);
      if (!match) return null;

      return {
        id: rawPermission.id,
        decision,
        label,
        reason,
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
    let heuristics: PolicyHeuristics | undefined;
    if ("heuristics" in value && value.heuristics !== undefined && value.heuristics !== null) {
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
        ]);

        if (strictUnknown) {
          for (const key of Object.keys(h)) {
            if (!validHeuristicKeys.has(key)) {
              errors.push(`${path}.heuristics.${key}: unknown key`);
            }
          }
        }

        const parseHeuristicValue = (
          rawHeuristic: unknown,
          hPath: string,
        ): "allow" | "ask" | "block" | false | undefined => {
          if (rawHeuristic === undefined) return undefined;
          if (rawHeuristic === false) return false;
          if (rawHeuristic === "allow" || rawHeuristic === "ask" || rawHeuristic === "block") {
            return rawHeuristic;
          }
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

  // Pairing/auth/push runtime state — passthrough (no strict schema validation, optional)
  if ("token" in obj && typeof obj.token === "string") {
    config.token = obj.token;
  }

  if ("pairingToken" in obj && typeof obj.pairingToken === "string") {
    config.pairingToken = obj.pairingToken;
  }

  if (
    "pairingTokenExpiresAt" in obj &&
    typeof obj.pairingTokenExpiresAt === "number" &&
    Number.isFinite(obj.pairingTokenExpiresAt)
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

export class ConfigStore {
  private readonly dataDir: string;
  private readonly configPath: string;
  private readonly sessionsDir: string;
  private readonly workspacesDir: string;
  private config: ServerConfig;

  constructor(dataDir: string = DEFAULT_DATA_DIR) {
    this.dataDir = dataDir;
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

    const result = ConfigStore.validateConfig(raw, dataDir, strictUnknown);
    if (result.errors.length > 0) {
      result.errors = result.errors.map((err) => `${configPath}: ${err}`);
      result.valid = false;
    }
    return result;
  }

  private loadConfig(): ServerConfig {
    const defaults = ConfigStore.getDefaultConfig(this.dataDir);

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

  getDataDir(): string {
    return this.dataDir;
  }

  getSessionsDir(): string {
    return this.sessionsDir;
  }

  getWorkspacesDir(): string {
    return this.workspacesDir;
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
}
