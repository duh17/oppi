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

import { dirname } from "node:path";
import { AuthStore } from "./storage/auth-store.js";
import {
  ConfigStore,
  DEFAULT_DATA_DIR,
  type ConfigValidationResult,
} from "./storage/config-store.js";
import { PreferenceStore } from "./storage/preference-store.js";
import { SessionStore } from "./storage/session-store.js";
import { WorkspaceStore } from "./storage/workspace-store.js";
import type {
  CreateWorkspaceRequest,
  ServerConfig,
  Session,
  UpdateWorkspaceRequest,
  Workspace,
} from "./types.js";

export type { ConfigValidationResult };

export class Storage {
  private readonly configStore: ConfigStore;
  private readonly authStore: AuthStore;
  private readonly preferenceStore: PreferenceStore;
  private readonly sessionStore: SessionStore;
  private readonly workspaceStore: WorkspaceStore;

  constructor(dataDir?: string) {
    this.configStore = new ConfigStore(dataDir ?? DEFAULT_DATA_DIR);
    this.authStore = new AuthStore(this.configStore);
    this.preferenceStore = new PreferenceStore(this.configStore);
    this.sessionStore = new SessionStore(this.configStore);
    this.workspaceStore = new WorkspaceStore(this.configStore);
  }

  // ─── Config ───

  static getDefaultConfig(dataDir: string = DEFAULT_DATA_DIR): ServerConfig {
    return ConfigStore.getDefaultConfig(dataDir);
  }

  static validateConfig(
    raw: unknown,
    dataDir: string = DEFAULT_DATA_DIR,
    strictUnknown: boolean = true,
  ): ConfigValidationResult {
    return ConfigStore.validateConfig(raw, dataDir, strictUnknown);
  }

  static validateConfigFile(
    configPath: string,
    dataDir: string = dirname(configPath),
    strictUnknown: boolean = true,
  ): ConfigValidationResult {
    return ConfigStore.validateConfigFile(configPath, dataDir, strictUnknown);
  }

  getConfig(): ServerConfig {
    return this.configStore.getConfig();
  }

  getConfigPath(): string {
    return this.configStore.getConfigPath();
  }

  updateConfig(updates: Partial<ServerConfig>): void {
    this.configStore.updateConfig(updates);
  }

  // ─── Pairing / auth / push tokens ───

  isPaired(): boolean {
    return this.authStore.isPaired();
  }

  getToken(): string | undefined {
    return this.authStore.getToken();
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

  consumePairingToken(candidate: string): string | null {
    return this.authStore.consumePairingToken(candidate);
  }

  getOwnerName(): string {
    return this.authStore.getOwnerName();
  }

  addAuthDeviceToken(token: string): void {
    this.authStore.addAuthDeviceToken(token);
  }

  removeAuthDeviceToken(token: string): void {
    this.authStore.removeAuthDeviceToken(token);
  }

  getAuthDeviceTokens(): string[] {
    return this.authStore.getAuthDeviceTokens();
  }

  addPushDeviceToken(token: string): void {
    this.authStore.addPushDeviceToken(token);
  }

  removePushDeviceToken(token: string): void {
    this.authStore.removePushDeviceToken(token);
  }

  getPushDeviceTokens(): string[] {
    return this.authStore.getPushDeviceTokens();
  }

  setLiveActivityToken(token: string | null): void {
    this.authStore.setLiveActivityToken(token);
  }

  getLiveActivityToken(): string | undefined {
    return this.authStore.getLiveActivityToken();
  }

  // ─── Thinking Preferences ───

  getModelThinkingLevelPreference(modelId: string): string | undefined {
    return this.preferenceStore.getModelThinkingLevelPreference(modelId);
  }

  setModelThinkingLevelPreference(modelId: string, level: string): void {
    this.preferenceStore.setModelThinkingLevelPreference(modelId, level);
  }

  // ─── Sessions ───

  createSession(name?: string, model?: string): Session {
    return this.sessionStore.createSession(name, model);
  }

  saveSession(session: Session): void {
    this.sessionStore.saveSession(session);
  }

  getSession(sessionId: string): Session | undefined {
    return this.sessionStore.getSession(sessionId);
  }

  listSessions(): Session[] {
    return this.sessionStore.listSessions();
  }

  deleteSession(sessionId: string): boolean {
    return this.sessionStore.deleteSession(sessionId);
  }

  // ─── Workspaces ───

  createWorkspace(req: CreateWorkspaceRequest): Workspace {
    return this.workspaceStore.createWorkspace(req);
  }

  saveWorkspace(workspace: Workspace): void {
    this.workspaceStore.saveWorkspace(workspace);
  }

  getWorkspace(workspaceId: string): Workspace | undefined {
    return this.workspaceStore.getWorkspace(workspaceId);
  }

  listWorkspaces(): Workspace[] {
    return this.workspaceStore.listWorkspaces();
  }

  updateWorkspace(workspaceId: string, updates: UpdateWorkspaceRequest): Workspace | undefined {
    return this.workspaceStore.updateWorkspace(workspaceId, updates);
  }

  deleteWorkspace(workspaceId: string): boolean {
    return this.workspaceStore.deleteWorkspace(workspaceId);
  }

  ensureDefaultWorkspaces(): void {
    this.workspaceStore.ensureDefaultWorkspaces();
  }

  // ─── Helpers ───

  getDataDir(): string {
    return this.configStore.getDataDir();
  }
}
