import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { createLogger } from "../logger.js";
import { defaultPolicy } from "../policy-presets.js";
import type {
  PolicyHeuristics,
  ServerConfig,
  SubagentConfig,
  SubagentModelPolicyConfig,
  SubagentModelProfileConfig,
} from "../types.js";

export const DEFAULT_DATA_DIR = join(homedir(), ".config", "oppi");
const CONFIG_VERSION = 2;

const log = createLogger({ base: { component: "config_store" } });

export interface ConfigValidationResult {
  valid: boolean;
  errors: string[];
  warnings: string[];
  config?: ServerConfig;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function defaultRuntimePathEntries(): string[] {
  const home = homedir();
  return [
    join(home, ".local", "bin"),
    join(home, ".cargo", "bin"),
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
  ];
}

export function defaultSubagentConfig(): SubagentConfig {
  return {
    maxDepth: 1,
    autoStopWhenDone: false,
    childIdleTimeoutMs: 5 * 60_000,
    startupGraceMs: 60_000,
    defaultWaitTimeoutMs: 30 * 60_000,
  };
}

function createDefaultConfig(dataDir: string): ServerConfig {
  return {
    configVersion: CONFIG_VERSION,
    port: 7749,
    host: "0.0.0.0",
    dataDir,
    sessionIdleTimeoutMs: 10 * 60 * 1000,
    workspaceIdleTimeoutMs: 30 * 60 * 1000,
    maxSessionsPerWorkspace: 20,
    maxSessionsGlobal: 40,
    approvalTimeoutMs: 120 * 1000,
    permissionGate: true,

    runtimePathEntries: defaultRuntimePathEntries(),
    runtimeEnv: {},
    tls: { mode: "self-signed" },
    policy: defaultPolicy(),
    uploadStore: {
      mode: "local",
      path: join(dataDir, "uploads"),
      maxFileBytes: 50 * 1024 * 1024,
      maxTurnBytes: 100 * 1024 * 1024,
      unusedTtlMs: 24 * 60 * 60 * 1000,
    },
    extensions: {
      subagents: defaultSubagentConfig(),
    },
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
    "sessionIdleTimeoutMs",
    "workspaceIdleTimeoutMs",
    "maxSessionsPerWorkspace",
    "maxSessionsGlobal",
    "approvalTimeoutMs",
    "permissionGate",
    "runtimePathEntries",
    "runtimeEnv",
    "tls",
    "policy",

    "token",
    "pairingToken",
    "pairingTokenExpiresAt",
    "authDeviceTokens",
    "pushDeviceTokens",
    "liveActivityToken",
    "autoTitle",
    "autoPermission",
    "asr",
    "uploadStore",
    "extensions",
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

  const sessionIdleTimeoutMs = readNumber("sessionIdleTimeoutMs", { min: 1 });
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

  if (!("runtimePathEntries" in obj)) {
    changed = true;
  } else if (Array.isArray(obj.runtimePathEntries)) {
    const entries: string[] = [];
    for (let i = 0; i < obj.runtimePathEntries.length; i++) {
      const value = obj.runtimePathEntries[i];
      if (typeof value !== "string" || value.trim().length === 0) {
        errors.push(`config.runtimePathEntries[${i}]: expected non-empty string`);
        changed = true;
        continue;
      }
      entries.push(value.trim());
    }
    config.runtimePathEntries = entries;
  } else {
    errors.push("config.runtimePathEntries: expected array of strings");
    changed = true;
  }

  if (!("runtimeEnv" in obj)) {
    changed = true;
  } else if (isRecord(obj.runtimeEnv)) {
    const runtimeEnv: Record<string, string> = {};
    for (const [key, value] of Object.entries(obj.runtimeEnv)) {
      if (typeof value !== "string") {
        errors.push(`config.runtimeEnv.${key}: expected string`);
        changed = true;
        continue;
      }
      runtimeEnv[key] = value;
    }
    config.runtimeEnv = runtimeEnv;
  } else {
    errors.push("config.runtimeEnv: expected object with string values");
    changed = true;
  }

  const parseTlsConfig = (
    value: unknown,
    path: string,
  ): NonNullable<ServerConfig["tls"]> | null => {
    if (!isRecord(value)) {
      errors.push(`${path}: expected object`);
      changed = true;
      return null;
    }

    const allowed = new Set(["mode", "certPath", "keyPath", "caPath"]);
    if (strictUnknown) {
      for (const key of Object.keys(value)) {
        if (!allowed.has(key)) {
          errors.push(`${path}.${key}: unknown key`);
        }
      }
    }

    const validModes = new Set([
      "auto",
      "tailscale",
      "cloudflare",
      "self-signed",
      "manual",
      "disabled",
    ]);

    if (typeof value.mode !== "string" || !validModes.has(value.mode)) {
      errors.push(
        `${path}.mode: expected one of auto|tailscale|cloudflare|self-signed|manual|disabled`,
      );
      changed = true;
      return null;
    }

    const tls: NonNullable<ServerConfig["tls"]> = {
      mode: value.mode as NonNullable<ServerConfig["tls"]>["mode"],
    };

    const readOptionalString = (key: "certPath" | "keyPath" | "caPath"): void => {
      if (!(key in value)) return;
      const rawValue = value[key];
      if (typeof rawValue !== "string" || rawValue.trim().length === 0) {
        errors.push(`${path}.${key}: expected non-empty string`);
        changed = true;
        return;
      }
      tls[key] = rawValue;
    };

    readOptionalString("certPath");
    readOptionalString("keyPath");
    readOptionalString("caPath");

    if (tls.mode === "manual") {
      if (!tls.certPath) {
        errors.push(`${path}.certPath: required when mode=manual`);
        changed = true;
      }
      if (!tls.keyPath) {
        errors.push(`${path}.keyPath: required when mode=manual`);
        changed = true;
      }
    }

    return tls;
  };

  if ("tls" in obj) {
    const parsed = parseTlsConfig(obj.tls, "config.tls");
    if (parsed) {
      config.tls = parsed;
    }
  } else {
    changed = true;
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
    ): "allow" | "auto" | "ask" | "block" | null => {
      if (
        rawDecision === "allow" ||
        rawDecision === "auto" ||
        rawDecision === "ask" ||
        rawDecision === "block"
      ) {
        return rawDecision;
      }
      errors.push(`${decisionPath}: expected one of allow|auto|ask|block`);
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
      decision: "allow" | "auto" | "ask" | "block";
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
        ): "allow" | "auto" | "ask" | "block" | false | undefined => {
          if (rawHeuristic === undefined) return undefined;
          if (rawHeuristic === false) return false;
          if (
            rawHeuristic === "allow" ||
            rawHeuristic === "auto" ||
            rawHeuristic === "ask" ||
            rawHeuristic === "block"
          ) {
            return rawHeuristic;
          }
          errors.push(`${hPath}: expected one of allow|auto|ask|block or false`);
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
  // Auto-title configuration
  if ("autoTitle" in obj && isRecord(obj.autoTitle)) {
    const at = obj.autoTitle;
    const autoTitle: NonNullable<ServerConfig["autoTitle"]> = {
      enabled: typeof at.enabled === "boolean" ? at.enabled : false,
    };
    if (typeof at.model === "string" && at.model.trim().length > 0) {
      autoTitle.model = at.model.trim();
    }
    config.autoTitle = autoTitle;
  }

  // Auto-permission reviewer configuration
  if ("autoPermission" in obj && isRecord(obj.autoPermission)) {
    const ap = obj.autoPermission;
    const allowedAutoPermissionKeys = new Set([
      "enabled",
      "model",
      "prompt",
      "timeoutMs",
      "maxTokens",
    ]);

    if (strictUnknown) {
      for (const key of Object.keys(ap)) {
        if (!allowedAutoPermissionKeys.has(key)) {
          errors.push(`config.autoPermission.${key}: unknown key`);
        }
      }
    }

    const autoPermission: NonNullable<ServerConfig["autoPermission"]> = {
      enabled: typeof ap.enabled === "boolean" ? ap.enabled : false,
    };
    if (typeof ap.model === "string" && ap.model.trim().length > 0) {
      autoPermission.model = ap.model.trim();
    }
    if (typeof ap.prompt === "string" && ap.prompt.trim().length > 0) {
      autoPermission.prompt = ap.prompt.trim();
    }
    if (typeof ap.timeoutMs === "number" && Number.isFinite(ap.timeoutMs) && ap.timeoutMs > 0) {
      autoPermission.timeoutMs = Math.floor(ap.timeoutMs);
    }
    if (typeof ap.maxTokens === "number" && Number.isFinite(ap.maxTokens) && ap.maxTokens > 0) {
      autoPermission.maxTokens = Math.floor(ap.maxTokens);
    }
    config.autoPermission = autoPermission;
  }

  // ASR / dictation pipeline config
  if ("asr" in obj && isRecord(obj.asr)) {
    const asr = obj.asr;
    const allowedAsrKeys = new Set(["sttEndpoint"]);

    if (strictUnknown) {
      for (const key of Object.keys(asr)) {
        if (!allowedAsrKeys.has(key)) {
          errors.push(`config.asr.${key}: unknown key`);
        }
      }
    }

    const asrConfig: NonNullable<ServerConfig["asr"]> = {};

    if (typeof asr.sttEndpoint === "string" && asr.sttEndpoint.trim().length > 0) {
      asrConfig.sttEndpoint = asr.sttEndpoint.trim();
    }

    if (Object.keys(asrConfig).length > 0) {
      config.asr = asrConfig;
    }
  }

  if ("uploadStore" in obj) {
    if (!isRecord(obj.uploadStore)) {
      errors.push("config.uploadStore: expected object");
      changed = true;
    } else {
      const upload = obj.uploadStore;
      const allowedUploadKeys = new Set([
        "mode",
        "path",
        "maxFileBytes",
        "maxTurnBytes",
        "unusedTtlMs",
        "retainedTtlMs",
        "allowedMimeTypes",
      ]);

      if (strictUnknown) {
        for (const key of Object.keys(upload)) {
          if (!allowedUploadKeys.has(key)) {
            errors.push(`config.uploadStore.${key}: unknown key`);
          }
        }
      }

      const uploadConfig: NonNullable<ServerConfig["uploadStore"]> = {};
      if ("mode" in upload) {
        if (upload.mode === "local") {
          uploadConfig.mode = "local";
        } else {
          errors.push("config.uploadStore.mode: expected local");
          changed = true;
        }
      }

      const readOptionalUploadString = (key: "path"): void => {
        if (!(key in upload)) {
          return;
        }
        if (typeof upload[key] === "string" && upload[key].trim().length > 0) {
          uploadConfig[key] = upload[key].trim();
          return;
        }
        errors.push(`config.uploadStore.${key}: expected non-empty string`);
        changed = true;
      };

      const readOptionalUploadInt = (
        key: "maxFileBytes" | "maxTurnBytes" | "unusedTtlMs" | "retainedTtlMs",
      ): void => {
        if (!(key in upload) || upload[key] === undefined) {
          return;
        }
        if (typeof upload[key] === "number" && Number.isInteger(upload[key]) && upload[key] >= 1) {
          uploadConfig[key] = upload[key];
          return;
        }
        errors.push(`config.uploadStore.${key}: expected positive integer`);
        changed = true;
      };

      readOptionalUploadString("path");
      readOptionalUploadInt("maxFileBytes");
      readOptionalUploadInt("maxTurnBytes");
      readOptionalUploadInt("unusedTtlMs");
      readOptionalUploadInt("retainedTtlMs");

      if ("allowedMimeTypes" in upload) {
        if (
          Array.isArray(upload.allowedMimeTypes) &&
          upload.allowedMimeTypes.every(
            (value) => typeof value === "string" && value.trim().length > 0,
          )
        ) {
          uploadConfig.allowedMimeTypes = upload.allowedMimeTypes.map((value) => value.trim());
        } else {
          errors.push("config.uploadStore.allowedMimeTypes: expected array of non-empty strings");
          changed = true;
        }
      }

      config.uploadStore = {
        ...(config.uploadStore ?? {}),
        ...uploadConfig,
      };
    }
  }

  const parseSubagentConfig = (value: unknown, pathPrefix: string): SubagentConfig | undefined => {
    if (!isRecord(value)) {
      if (value !== undefined) {
        errors.push(`${pathPrefix}: expected object`);
        changed = true;
      }
      return undefined;
    }

    const sa = value;
    const defaults = defaultSubagentConfig();
    const subagents: SubagentConfig = { ...defaults };

    const allowedSubagentKeys = new Set([
      "maxDepth",
      "autoStopWhenDone",
      "childIdleTimeoutMs",
      "startupGraceMs",
      "defaultWaitTimeoutMs",
      "modelPolicy",
    ]);

    if (strictUnknown) {
      for (const key of Object.keys(sa)) {
        if (!allowedSubagentKeys.has(key)) {
          errors.push(`${pathPrefix}.${key}: unknown key`);
        }
      }
    }

    if ("maxDepth" in sa) {
      if (typeof sa.maxDepth === "number" && Number.isInteger(sa.maxDepth) && sa.maxDepth >= 0) {
        subagents.maxDepth = sa.maxDepth;
      } else {
        errors.push(`${pathPrefix}.maxDepth: expected non-negative integer`);
        changed = true;
      }
    }

    if ("autoStopWhenDone" in sa) {
      if (typeof sa.autoStopWhenDone === "boolean") {
        subagents.autoStopWhenDone = sa.autoStopWhenDone;
      } else {
        errors.push(`${pathPrefix}.autoStopWhenDone: expected boolean`);
        changed = true;
      }
    }

    if ("childIdleTimeoutMs" in sa) {
      if (
        typeof sa.childIdleTimeoutMs === "number" &&
        Number.isInteger(sa.childIdleTimeoutMs) &&
        sa.childIdleTimeoutMs >= 1
      ) {
        subagents.childIdleTimeoutMs = sa.childIdleTimeoutMs;
      } else {
        errors.push(`${pathPrefix}.childIdleTimeoutMs: expected positive integer`);
        changed = true;
      }
    }

    if ("startupGraceMs" in sa) {
      if (
        typeof sa.startupGraceMs === "number" &&
        Number.isInteger(sa.startupGraceMs) &&
        sa.startupGraceMs >= 1
      ) {
        subagents.startupGraceMs = sa.startupGraceMs;
      } else {
        errors.push(`${pathPrefix}.startupGraceMs: expected positive integer`);
        changed = true;
      }
    }

    if ("defaultWaitTimeoutMs" in sa) {
      if (
        typeof sa.defaultWaitTimeoutMs === "number" &&
        Number.isInteger(sa.defaultWaitTimeoutMs) &&
        sa.defaultWaitTimeoutMs >= 1
      ) {
        subagents.defaultWaitTimeoutMs = sa.defaultWaitTimeoutMs;
      } else {
        errors.push(`${pathPrefix}.defaultWaitTimeoutMs: expected positive integer`);
        changed = true;
      }
    }

    if ("modelPolicy" in sa) {
      if (!isRecord(sa.modelPolicy)) {
        errors.push(`${pathPrefix}.modelPolicy: expected object`);
        changed = true;
      } else {
        const policy = sa.modelPolicy;
        const allowedPolicyKeys = new Set([
          "approvedModels",
          "defaultModel",
          "defaultThinking",
          "profiles",
        ]);

        if (strictUnknown) {
          for (const key of Object.keys(policy)) {
            if (!allowedPolicyKeys.has(key)) {
              errors.push(`${pathPrefix}.modelPolicy.${key}: unknown key`);
            }
          }
        }

        const parsedPolicy: SubagentModelPolicyConfig = {};

        if ("approvedModels" in policy) {
          if (
            Array.isArray(policy.approvedModels) &&
            policy.approvedModels.every(
              (value) => typeof value === "string" && value.trim().length > 0,
            )
          ) {
            parsedPolicy.approvedModels = Array.from(
              new Set(policy.approvedModels.map((value) => value.trim())),
            );
          } else {
            errors.push(
              `${pathPrefix}.modelPolicy.approvedModels: expected array of non-empty strings`,
            );
            changed = true;
          }
        }

        if ("defaultModel" in policy) {
          if (typeof policy.defaultModel === "string" && policy.defaultModel.trim().length > 0) {
            parsedPolicy.defaultModel = policy.defaultModel.trim();
          } else {
            errors.push(`${pathPrefix}.modelPolicy.defaultModel: expected non-empty string`);
            changed = true;
          }
        }

        if ("defaultThinking" in policy) {
          const allowedThinking = new Set(["off", "minimal", "low", "medium", "high", "xhigh"]);
          if (
            typeof policy.defaultThinking === "string" &&
            allowedThinking.has(policy.defaultThinking.trim())
          ) {
            parsedPolicy.defaultThinking = policy.defaultThinking.trim();
          } else {
            errors.push(
              `${pathPrefix}.modelPolicy.defaultThinking: expected one of off|minimal|low|medium|high|xhigh`,
            );
            changed = true;
          }
        }

        if ("profiles" in policy) {
          if (!isRecord(policy.profiles)) {
            errors.push(`${pathPrefix}.modelPolicy.profiles: expected object`);
            changed = true;
          } else {
            const profiles: Record<string, SubagentModelProfileConfig> = {};
            for (const [profileName, profileValue] of Object.entries(policy.profiles)) {
              if (!isRecord(profileValue)) {
                errors.push(`${pathPrefix}.modelPolicy.profiles.${profileName}: expected object`);
                changed = true;
                continue;
              }

              const allowedProfileKeys = new Set([
                "description",
                "model",
                "thinking",
                "guidelines",
              ]);
              if (strictUnknown) {
                for (const key of Object.keys(profileValue)) {
                  if (!allowedProfileKeys.has(key)) {
                    errors.push(
                      `${pathPrefix}.modelPolicy.profiles.${profileName}.${key}: unknown key`,
                    );
                  }
                }
              }

              const profile: SubagentModelProfileConfig = {};
              if ("description" in profileValue) {
                if (
                  typeof profileValue.description === "string" &&
                  profileValue.description.trim().length > 0
                ) {
                  profile.description = profileValue.description.trim();
                } else {
                  errors.push(
                    `${pathPrefix}.modelPolicy.profiles.${profileName}.description: expected non-empty string`,
                  );
                  changed = true;
                }
              }

              if ("model" in profileValue) {
                if (
                  typeof profileValue.model === "string" &&
                  profileValue.model.trim().length > 0
                ) {
                  profile.model = profileValue.model.trim();
                } else {
                  errors.push(
                    `${pathPrefix}.modelPolicy.profiles.${profileName}.model: expected non-empty string`,
                  );
                  changed = true;
                }
              }

              if ("thinking" in profileValue) {
                const allowedThinking = new Set([
                  "off",
                  "minimal",
                  "low",
                  "medium",
                  "high",
                  "xhigh",
                ]);
                if (
                  typeof profileValue.thinking === "string" &&
                  allowedThinking.has(profileValue.thinking.trim())
                ) {
                  profile.thinking = profileValue.thinking.trim();
                } else {
                  errors.push(
                    `${pathPrefix}.modelPolicy.profiles.${profileName}.thinking: expected one of off|minimal|low|medium|high|xhigh`,
                  );
                  changed = true;
                }
              }

              if ("guidelines" in profileValue) {
                if (
                  Array.isArray(profileValue.guidelines) &&
                  profileValue.guidelines.every(
                    (value) => typeof value === "string" && value.trim().length > 0,
                  )
                ) {
                  profile.guidelines = profileValue.guidelines.map((value) => value.trim());
                } else {
                  errors.push(
                    `${pathPrefix}.modelPolicy.profiles.${profileName}.guidelines: expected array of non-empty strings`,
                  );
                  changed = true;
                }
              }

              profiles[profileName] = profile;
            }
            parsedPolicy.profiles = profiles;
          }
        }

        const approved = parsedPolicy.approvedModels;
        if (approved && approved.length > 0) {
          if (parsedPolicy.defaultModel && !approved.includes(parsedPolicy.defaultModel)) {
            errors.push(
              `${pathPrefix}.modelPolicy.defaultModel: must be included in approvedModels`,
            );
            changed = true;
          }
          for (const [profileName, profile] of Object.entries(parsedPolicy.profiles ?? {})) {
            if (profile.model && !approved.includes(profile.model)) {
              errors.push(
                `${pathPrefix}.modelPolicy.profiles.${profileName}.model: must be included in approvedModels`,
              );
              changed = true;
            }
          }
        }

        if (Object.keys(parsedPolicy).length > 0) {
          subagents.modelPolicy = parsedPolicy;
        }
      }
    }

    return subagents;
  };

  // Extension configuration
  if ("extensions" in obj && isRecord(obj.extensions)) {
    const extensions = obj.extensions;
    const extensionConfig: NonNullable<ServerConfig["extensions"]> = {};
    const allowedExtensionKeys = new Set(["voice", "subagents"]);

    if (strictUnknown) {
      for (const key of Object.keys(extensions)) {
        if (!allowedExtensionKeys.has(key)) {
          errors.push(`config.extensions.${key}: unknown key`);
        }
      }
    }

    if ("voice" in extensions) {
      if (isRecord(extensions.voice)) {
        const voice = extensions.voice;
        const voiceConfig: NonNullable<NonNullable<ServerConfig["extensions"]>["voice"]> = {};
        const allowedVoiceKeys = new Set(["defaultVoiceId"]);

        if (strictUnknown) {
          for (const key of Object.keys(voice)) {
            if (!allowedVoiceKeys.has(key)) {
              errors.push(`config.extensions.voice.${key}: unknown key`);
            }
          }
        }

        if (typeof voice.defaultVoiceId === "string" && voice.defaultVoiceId.trim().length > 0) {
          voiceConfig.defaultVoiceId = voice.defaultVoiceId.trim();
        } else if ("defaultVoiceId" in voice && voice.defaultVoiceId !== undefined) {
          errors.push("config.extensions.voice.defaultVoiceId: expected non-empty string");
          changed = true;
        }

        if (Object.keys(voiceConfig).length > 0) {
          extensionConfig.voice = voiceConfig;
        }
      } else if (extensions.voice !== undefined) {
        errors.push("config.extensions.voice: expected object");
        changed = true;
      }
    }

    const nestedSubagents = parseSubagentConfig(
      extensions.subagents,
      "config.extensions.subagents",
    );
    if (nestedSubagents) {
      extensionConfig.subagents = nestedSubagents;
    }

    if (Object.keys(extensionConfig).length > 0) {
      config.extensions = extensionConfig;
    }
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
          log.warn("config_store.field.invalid", {
            issue: err,
            action: "using_default_for_invalid_field",
          });
        }
        for (const warning of normalized.warnings) {
          log.warn("config_store.validation.warning", {
            warning,
          });
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
        log.warn("config_store.config_parse.failed", {
          configPath: this.configPath,
          error: message,
        });
        log.warn("config_store.defaults_fallback", {
          configPath: this.configPath,
        });
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
