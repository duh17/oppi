import { existsSync } from "node:fs";
import { join } from "node:path";

import { ConfigStore, DEFAULT_DATA_DIR } from "../storage/config-store.js";
import type { ServerConfig } from "../types.js";
import type { LocalApiConnection } from "./local-api-client.js";

export interface CliConnectionConfig extends LocalApiConnection {
  getConfigPath(): string;
  isPaired(): boolean;
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

export function createCliConnectionConfig(dataDir?: string): CliConnectionConfig {
  return new FileCliConnectionConfig(dataDir ?? process.env.OPPI_DATA_DIR ?? DEFAULT_DATA_DIR);
}
