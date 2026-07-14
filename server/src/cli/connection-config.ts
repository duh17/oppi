import { existsSync } from "node:fs";
import { join } from "node:path";

import { AuthStore } from "../storage/auth-store.js";
import { ConfigStore, DEFAULT_DATA_DIR } from "../storage/config-store.js";
import type { ServerConfig } from "../types.js";
import type { LocalApiConnection } from "./local-api-client.js";

export interface CliConnectionConfig extends LocalApiConnection {
  getConfigPath(): string;
  isPaired(): boolean;
}

export interface CliConfigStorage extends CliConnectionConfig {
  updateConfig(updates: Partial<ServerConfig>): void;
  ensurePaired(): string;
  rotateToken(): string;
  issuePairingToken(ttlMs?: number): string;
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

export class FileCliConfigStorage implements CliConfigStorage {
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

  issuePairingToken(ttlMs?: number): string {
    return this.authStore.issuePairingToken(ttlMs);
  }
}

export function createCliConnectionConfig(dataDir?: string): CliConnectionConfig {
  return new FileCliConnectionConfig(dataDir ?? process.env.OPPI_DATA_DIR ?? DEFAULT_DATA_DIR);
}

export function createCliConfigStorage(dataDir?: string): CliConfigStorage {
  return new FileCliConfigStorage(dataDir ?? process.env.OPPI_DATA_DIR ?? DEFAULT_DATA_DIR);
}
