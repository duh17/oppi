import {
  closeSync,
  existsSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { createLogger } from "../logger.js";
import type { DevicePublicKey, ServerConfig } from "../types.js";

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

function normalizeDevicePublicKey(value: unknown): DevicePublicKey | undefined {
  if (!isRecord(value)) return undefined;
  if (value.kty !== "EC" || value.crv !== "P-256") return undefined;
  if (typeof value.x !== "string" || value.x.trim().length === 0) return undefined;
  if (typeof value.y !== "string" || value.y.trim().length === 0) return undefined;
  return { kty: "EC", crv: "P-256", x: value.x, y: value.y };
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

function createDefaultConfig(dataDir: string): ServerConfig {
  return {
    configVersion: CONFIG_VERSION,
    port: 7749,
    host: "0.0.0.0",
    dataDir,
    sessionIdleTimeoutMs: 10 * 60 * 1000,
    workspaceIdleTimeoutMs: 30 * 60 * 1000,
    maxSessionsPerWorkspace: 100,
    maxSessionsGlobal: 200,

    runtimePathEntries: defaultRuntimePathEntries(),
    runtimeEnv: {},
    oppiDocsPrompt: {
      enabled: true,
    },
    oppiCliPrompt: {
      enabled: true,
    },
    tls: { mode: "self-signed" },
    images: {
      autoResize: false,
    },
    uploadStore: {
      mode: "local",
      path: join(dataDir, "uploads"),
      maxFileBytes: 50 * 1024 * 1024,
      maxTurnBytes: 100 * 1024 * 1024,
      unusedTtlMs: 24 * 60 * 60 * 1000,
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
    "runtimePathEntries",
    "runtimeEnv",
    "oppiDocsPrompt",
    "oppiCliPrompt",
    "tls",

    "token",
    "pairingToken",
    "pairingTokenExpiresAt",
    "authDeviceTokens",
    "authMigrationMode",
    "authDevices",
    "authAccessTokens",
    "pushDeviceTokens",
    "liveActivityToken",
    "autoTitle",
    "asr",
    "images",
    "uploadStore",
    "extensions",
  ]);

  const unknownTopLevelKeys = Object.keys(obj).filter((key) => !topLevelKeys.has(key));
  if (unknownTopLevelKeys.length > 0) {
    changed = true;
  }

  if (strictUnknown) {
    for (const key of unknownTopLevelKeys) {
      errors.push(`config.${key}: unknown key`);
    }
  } else if (unknownTopLevelKeys.length > 0) {
    warnings.push(
      `config: ignored ${unknownTopLevelKeys.length} unknown top-level key${unknownTopLevelKeys.length === 1 ? "" : "s"}`,
    );
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

  if (!("oppiDocsPrompt" in obj)) {
    changed = true;
  } else if (isRecord(obj.oppiDocsPrompt)) {
    const docsPrompt = obj.oppiDocsPrompt;
    const allowedDocsPromptKeys = new Set(["enabled"]);

    if (strictUnknown) {
      for (const key of Object.keys(docsPrompt)) {
        if (!allowedDocsPromptKeys.has(key)) {
          errors.push(`config.oppiDocsPrompt.${key}: unknown key`);
        }
      }
    }

    if ("enabled" in docsPrompt) {
      if (typeof docsPrompt.enabled === "boolean") {
        config.oppiDocsPrompt = { enabled: docsPrompt.enabled };
      } else {
        errors.push("config.oppiDocsPrompt.enabled: expected boolean");
        changed = true;
      }
    }
  } else {
    errors.push("config.oppiDocsPrompt: expected object");
    changed = true;
  }

  if (!("oppiCliPrompt" in obj)) {
    changed = true;
  } else if (isRecord(obj.oppiCliPrompt)) {
    const cliPrompt = obj.oppiCliPrompt;
    const allowedCliPromptKeys = new Set(["enabled"]);

    if (strictUnknown) {
      for (const key of Object.keys(cliPrompt)) {
        if (!allowedCliPromptKeys.has(key)) {
          errors.push(`config.oppiCliPrompt.${key}: unknown key`);
        }
      }
    }

    if ("enabled" in cliPrompt) {
      if (typeof cliPrompt.enabled === "boolean") {
        config.oppiCliPrompt = { enabled: cliPrompt.enabled };
      } else {
        errors.push("config.oppiCliPrompt.enabled: expected boolean");
        changed = true;
      }
    }
  } else {
    errors.push("config.oppiCliPrompt: expected object");
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

    const allowed = new Set(["mode", "certPath", "keyPath", "caPath", "allowInsecureNetworkHttp"]);
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

    if ("allowInsecureNetworkHttp" in value) {
      if (typeof value.allowInsecureNetworkHttp !== "boolean") {
        errors.push(`${path}.allowInsecureNetworkHttp: expected boolean`);
        changed = true;
      } else {
        tls.allowInsecureNetworkHttp = value.allowInsecureNetworkHttp;
      }
    }

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

  const authMigrationMode =
    obj.authMigrationMode === "compat" || obj.authMigrationMode === "finalized"
      ? obj.authMigrationMode
      : undefined;
  if (authMigrationMode) {
    config.authMigrationMode = authMigrationMode;
  }

  if ("authDevices" in obj && Array.isArray(obj.authDevices)) {
    config.authDevices = (obj.authDevices as unknown[]).flatMap((value) => {
      if (!isRecord(value)) return [];
      if (typeof value.id !== "string" || value.id.trim().length === 0) return [];
      if (typeof value.name !== "string") return [];
      const scope = value.scope === "admin" || value.scope === "mirror" ? value.scope : "device";
      const createdAt =
        typeof value.createdAt === "number" && Number.isFinite(value.createdAt)
          ? value.createdAt
          : Date.now();
      const lastUsedAt =
        typeof value.lastUsedAt === "number" && Number.isFinite(value.lastUsedAt)
          ? value.lastUsedAt
          : undefined;
      const revokedAt =
        typeof value.revokedAt === "number" && Number.isFinite(value.revokedAt)
          ? value.revokedAt
          : undefined;
      const legacyTokenHash =
        typeof value.legacyTokenHash === "string" && value.legacyTokenHash.trim().length > 0
          ? value.legacyTokenHash
          : undefined;
      const publicKey = normalizeDevicePublicKey(value.publicKey);
      return [
        {
          id: value.id,
          name: value.name,
          ...(publicKey ? { publicKey } : {}),
          scope,
          createdAt,
          ...(lastUsedAt !== undefined ? { lastUsedAt } : {}),
          ...(revokedAt !== undefined ? { revokedAt } : {}),
          ...(legacyTokenHash ? { legacyTokenHash } : {}),
        },
      ];
    });
  }

  if ("authAccessTokens" in obj && Array.isArray(obj.authAccessTokens)) {
    config.authAccessTokens = (obj.authAccessTokens as unknown[]).flatMap((value) => {
      if (!isRecord(value)) return [];
      if (typeof value.id !== "string" || value.id.trim().length === 0) return [];
      if (typeof value.tokenHash !== "string" || value.tokenHash.trim().length === 0) return [];
      if (typeof value.deviceId !== "string" || value.deviceId.trim().length === 0) return [];
      const scope = value.scope === "admin" || value.scope === "mirror" ? value.scope : "device";
      const createdAt =
        typeof value.createdAt === "number" && Number.isFinite(value.createdAt)
          ? value.createdAt
          : Date.now();
      const expiresAt =
        typeof value.expiresAt === "number" && Number.isFinite(value.expiresAt)
          ? value.expiresAt
          : createdAt;
      const lastUsedAt =
        typeof value.lastUsedAt === "number" && Number.isFinite(value.lastUsedAt)
          ? value.lastUsedAt
          : undefined;
      return [
        {
          id: value.id,
          tokenHash: value.tokenHash,
          deviceId: value.deviceId,
          scope,
          createdAt,
          expiresAt,
          ...(lastUsedAt !== undefined ? { lastUsedAt } : {}),
        },
      ];
    });
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

  // ASR / dictation pipeline config
  if ("asr" in obj && isRecord(obj.asr)) {
    const asr = obj.asr;
    const allowedAsrKeys = new Set(["sttEndpoint", "backend"]);
    const retiredAsrKeys = new Set(["extension"]);

    if ("extension" in asr) {
      warnings.push("config.asr.extension: ignored; Pi-extension STT is no longer supported");
      changed = true;
    }

    if (strictUnknown) {
      for (const key of Object.keys(asr)) {
        if (!allowedAsrKeys.has(key) && !retiredAsrKeys.has(key)) {
          errors.push(`config.asr.${key}: unknown key`);
        }
      }
    }

    const asrConfig: NonNullable<ServerConfig["asr"]> = {};

    if ("backend" in asr) {
      if (asr.backend === "http") {
        asrConfig.backend = "http";
      } else if (asr.backend === "pi-extension") {
        if (strictUnknown) {
          errors.push("config.asr.backend: expected http");
        } else {
          warnings.push(
            "config.asr.backend: ignored pi-extension; server dictation is HTTP/Yuwp only",
          );
        }
        changed = true;
      } else {
        errors.push("config.asr.backend: expected http");
        changed = true;
      }
    }

    if (typeof asr.sttEndpoint === "string" && asr.sttEndpoint.trim().length > 0) {
      asrConfig.sttEndpoint = asr.sttEndpoint.trim();
    }
    if (Object.keys(asrConfig).length > 0) {
      config.asr = asrConfig;
    }
  }

  // Image attachment preprocessing configuration
  if ("images" in obj) {
    if (!isRecord(obj.images)) {
      errors.push("config.images: expected object");
      changed = true;
    } else {
      const images = obj.images;
      const allowedImageKeys = new Set(["autoResize"]);

      if (strictUnknown) {
        for (const key of Object.keys(images)) {
          if (!allowedImageKeys.has(key)) {
            errors.push(`config.images.${key}: unknown key`);
          }
        }
      }

      const imageConfig: NonNullable<ServerConfig["images"]> = {};
      if ("autoResize" in images) {
        if (typeof images.autoResize === "boolean") {
          imageConfig.autoResize = images.autoResize;
        } else {
          errors.push("config.images.autoResize: expected boolean");
          changed = true;
        }
      }

      config.images = {
        ...(config.images ?? {}),
        ...imageConfig,
      };
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

  // Extension configuration
  if ("extensions" in obj && isRecord(obj.extensions)) {
    const extensions = obj.extensions;
    const extensionConfig: NonNullable<ServerConfig["extensions"]> = {};
    const allowedExtensionKeys = new Set(["voice"]);

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

    if (Object.keys(extensionConfig).length > 0) {
      config.extensions = extensionConfig;
    }
  }

  return { valid: errors.length === 0, errors, warnings, config, changed };
}

export class ConfigStore {
  private readonly dataDir: string;
  private readonly configPath: string;
  private readonly workspacesDir: string;
  private config: ServerConfig;

  constructor(dataDir: string = DEFAULT_DATA_DIR) {
    this.dataDir = dataDir;
    this.configPath = join(this.dataDir, "config.json");
    this.workspacesDir = join(this.dataDir, "workspaces");

    this.ensureDirectories();
    this.config = this.loadConfig();
  }

  private ensureDirectories(): void {
    for (const dir of [this.dataDir, this.workspacesDir]) {
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
        throw new Error(`${this.configPath}: invalid JSON (${message})`, { cause: err });
      }
    }

    this.saveConfig(defaults);
    return defaults;
  }

  private saveConfig(config: ServerConfig): void {
    const temporaryPath = join(this.dataDir, `.config.${process.pid}.${randomUUID()}.tmp`);
    let fileDescriptor: number | undefined;
    let directoryDescriptor: number | undefined;
    try {
      fileDescriptor = openSync(temporaryPath, "wx", 0o600);
      writeFileSync(fileDescriptor, JSON.stringify(config, null, 2));
      fsyncSync(fileDescriptor);
      closeSync(fileDescriptor);
      fileDescriptor = undefined;

      renameSync(temporaryPath, this.configPath);
      directoryDescriptor = openSync(this.dataDir, "r");
      fsyncSync(directoryDescriptor);
      closeSync(directoryDescriptor);
      directoryDescriptor = undefined;
    } catch (error) {
      if (fileDescriptor !== undefined) closeSync(fileDescriptor);
      if (directoryDescriptor !== undefined) closeSync(directoryDescriptor);
      rmSync(temporaryPath, { force: true });
      throw error;
    }
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

  getWorkspacesDir(): string {
    return this.workspacesDir;
  }

  updateConfig(updates: Partial<ServerConfig>): void {
    const merged: ServerConfig = {
      ...this.config,
      ...updates,
    };

    const normalized = normalizeConfig(merged, this.dataDir, true);
    if (!normalized.valid) {
      throw new Error(`Invalid config update: ${normalized.errors.join("; ")}`);
    }
    this.saveConfig(normalized.config);
    this.config = normalized.config;
  }
}
