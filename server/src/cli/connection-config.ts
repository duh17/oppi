import { existsSync } from "node:fs";
import { join } from "node:path";

import { AuthStore } from "../storage/auth-store.js";
import {
  ConfigStore,
  DEFAULT_DATA_DIR,
  type ConfigValidationResult,
} from "../storage/config-store.js";
import type { AuthTransport, ServerConfig } from "../types.js";
import type { LocalApiConnection } from "./local-api-client.js";

export interface CliConnectionConfig extends LocalApiConnection {
  getConfigPath(): string;
  isPaired(): boolean;
}

export interface CliConfigStorage extends CliConnectionConfig {
  updateConfig(updates: Partial<ServerConfig>): void;
  ensurePaired(): string;
  rotateToken(): string;
  issuePairingToken(ttlMs?: number, options?: { allowedTransports?: AuthTransport[] }): string;
}

/**
 * Config-capable storage for `oppi config` commands. Kept off the base
 * interface so full app `Storage` keeps matching `CliConfigStorage` in
 * serve/pair flows; only the config command needs the extra surface.
 */
export interface CliConfigCommandStorage extends CliConfigStorage {
  /** Default config for the current data dir, without reading or validating a file. */
  getDefaultConfig(): ServerConfig;
  /** Validate a config file at an explicit path, defaulting to the storage config path. */
  validateConfigFile(target?: string): ConfigValidationResult;
}

export class FileCliConnectionConfig implements CliConnectionConfig {
  private readonly dataDir: string;
  private readonly configPath: string;
  private config: ServerConfig | undefined;

  constructor(dataDir = process.env.OPPI_DATA_DIR || DEFAULT_DATA_DIR) {
    this.dataDir = dataDir;
    this.configPath = join(dataDir, "config.json");
  }

  getConfig(): ServerConfig {
    if (!this.config) {
      this.config = this.loadConfig();
    }
    return this.config;
  }

  getToken(): string | undefined {
    return this.getConfig().token;
  }

  getDataDir(): string {
    return this.dataDir;
  }

  getConfigPath(): string {
    return this.configPath;
  }

  isPaired(): boolean {
    return !!this.getToken();
  }

  private loadConfig(): ServerConfig {
    if (!existsSync(this.configPath)) {
      return ConfigStore.getDefaultConfig(this.dataDir);
    }

    const result = ConfigStore.validateConfigFile(this.configPath, this.dataDir, false);
    if (!result.valid || !result.config) {
      throw new Error(`Invalid Oppi config: ${result.errors.join("; ")}`);
    }
    return result.config;
  }
}

export class FileCliConfigStorage implements CliConfigCommandStorage {
  private readonly configStore: ConfigStore;
  private readonly authStore: AuthStore;

  constructor(dataDir = process.env.OPPI_DATA_DIR || DEFAULT_DATA_DIR) {
    this.configStore = new ConfigStore(dataDir);
    this.authStore = new AuthStore(this.configStore);
  }

  getConfig(): ServerConfig {
    return this.configStore.getConfig();
  }

  getToken(): string | undefined {
    return this.authStore.getToken();
  }

  getDataDir(): string {
    return this.configStore.getDataDir();
  }

  getConfigPath(): string {
    return this.configStore.getConfigPath();
  }

  updateConfig(updates: Partial<ServerConfig>): void {
    this.configStore.updateConfig(updates);
  }

  isPaired(): boolean {
    return this.authStore.isPaired();
  }

  ensurePaired(): string {
    return this.authStore.ensurePaired();
  }

  rotateToken(): string {
    return this.authStore.rotateToken();
  }

  issuePairingToken(ttlMs?: number, options?: { allowedTransports?: AuthTransport[] }): string {
    return this.authStore.issuePairingToken(ttlMs, options);
  }

  getDefaultConfig(): ServerConfig {
    return ConfigStore.getDefaultConfig(this.getDataDir());
  }

  validateConfigFile(target?: string): ConfigValidationResult {
    return ConfigStore.validateConfigFile(target ?? this.getConfigPath());
  }
}

export function createCliConnectionConfig(dataDir?: string): CliConnectionConfig {
  return new FileCliConnectionConfig(dataDir ?? process.env.OPPI_DATA_DIR ?? DEFAULT_DATA_DIR);
}

export function createCliConfigStorage(dataDir?: string): CliConfigCommandStorage {
  return new FileCliConfigStorage(dataDir ?? process.env.OPPI_DATA_DIR ?? DEFAULT_DATA_DIR);
}
