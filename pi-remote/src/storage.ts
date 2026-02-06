/**
 * Persistent storage for pi-remote
 * 
 * Data directory structure:
 * ~/.config/pi-remote/
 * ├── config.json       # Server config
 * ├── users.json        # User accounts & tokens
 * └── sessions/
 *     └── <userId>/
 *         └── <sessionId>.json  # Session state & messages
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { nanoid } from "nanoid";
import type { User, Session, SessionMessage, ServerConfig } from "./types.js";

const DEFAULT_DATA_DIR = join(homedir(), ".config", "pi-remote");

export class Storage {
  private dataDir: string;
  private configPath: string;
  private usersPath: string;
  private sessionsDir: string;
  
  private config: ServerConfig;
  private users: Map<string, User> = new Map();
  private tokenToUser: Map<string, User> = new Map();

  constructor(dataDir?: string) {
    this.dataDir = dataDir || DEFAULT_DATA_DIR;
    this.configPath = join(this.dataDir, "config.json");
    this.usersPath = join(this.dataDir, "users.json");
    this.sessionsDir = join(this.dataDir, "sessions");
    
    this.ensureDirectories();
    this.config = this.loadConfig();
    this.loadUsers();
  }

  private ensureDirectories(): void {
    if (!existsSync(this.dataDir)) {
      mkdirSync(this.dataDir, { recursive: true, mode: 0o700 });
    }
    if (!existsSync(this.sessionsDir)) {
      mkdirSync(this.sessionsDir, { recursive: true });
    }
  }

  // ─── Config ───

  private loadConfig(): ServerConfig {
    const defaults: ServerConfig = {
      port: 7749,
      host: "0.0.0.0",
      dataDir: this.dataDir,
      defaultModel: "anthropic/claude-sonnet-4-0",
      sessionTimeout: 60 * 60 * 1000, // 1 hour
    };

    if (existsSync(this.configPath)) {
      try {
        const loaded = JSON.parse(readFileSync(this.configPath, "utf-8"));
        // Merge with defaults to handle new fields
        const config = { ...defaults, ...loaded };
        // Save if we added new fields
        if (Object.keys(loaded).length !== Object.keys(config).length) {
          this.saveConfig(config);
        }
        return config;
      } catch {
        // Fall through to defaults
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

  updateConfig(updates: Partial<ServerConfig>): void {
    this.config = { ...this.config, ...updates };
    this.saveConfig(this.config);
  }

  // ─── Users ───

  private loadUsers(): void {
    if (!existsSync(this.usersPath)) {
      this.saveUsers();
      return;
    }

    try {
      const data = JSON.parse(readFileSync(this.usersPath, "utf-8")) as User[];
      for (const user of data) {
        this.users.set(user.id, user);
        this.tokenToUser.set(user.token, user);
      }
    } catch {
      // Start fresh
    }
  }

  private saveUsers(): void {
    const data = Array.from(this.users.values());
    writeFileSync(this.usersPath, JSON.stringify(data, null, 2), { mode: 0o600 });
  }

  createUser(name: string): User {
    const id = nanoid(8);
    const token = `sk_${nanoid(24)}`;
    
    const user: User = {
      id,
      name,
      token,
      createdAt: Date.now(),
    };

    this.users.set(id, user);
    this.tokenToUser.set(token, user);
    this.saveUsers();

    // Create user's session directory
    mkdirSync(join(this.sessionsDir, id), { recursive: true });

    return user;
  }

  getUserByToken(token: string): User | undefined {
    return this.tokenToUser.get(token);
  }

  getUserById(id: string): User | undefined {
    return this.users.get(id);
  }

  listUsers(): User[] {
    return Array.from(this.users.values());
  }

  removeUser(id: string): boolean {
    const user = this.users.get(id);
    if (!user) return false;

    this.users.delete(id);
    this.tokenToUser.delete(user.token);
    this.saveUsers();

    // Remove user's sessions
    const userSessionsDir = join(this.sessionsDir, id);
    if (existsSync(userSessionsDir)) {
      rmSync(userSessionsDir, { recursive: true });
    }

    return true;
  }

  regenerateToken(userId: string): User | undefined {
    const user = this.users.get(userId);
    if (!user) return undefined;

    // Remove old token mapping
    this.tokenToUser.delete(user.token);

    // Generate new token
    user.token = `sk_${nanoid(24)}`;
    this.tokenToUser.set(user.token, user);
    this.saveUsers();

    return user;
  }

  updateUserLastSeen(userId: string): void {
    const user = this.users.get(userId);
    if (user) {
      user.lastSeen = Date.now();
      this.saveUsers();
    }
  }

  // ─── Sessions ───

  private getSessionPath(userId: string, sessionId: string): string {
    return join(this.sessionsDir, userId, `${sessionId}.json`);
  }

  createSession(userId: string, name?: string, model?: string): Session {
    const id = nanoid(8);
    
    const session: Session = {
      id,
      userId,
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
    const path = this.getSessionPath(session.userId, session.id);
    const dir = join(this.sessionsDir, session.userId);
    
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }

    // Load existing to preserve messages
    let messages: SessionMessage[] = [];
    if (existsSync(path)) {
      try {
        const existing = JSON.parse(readFileSync(path, "utf-8"));
        messages = existing.messages || [];
      } catch {}
    }

    writeFileSync(path, JSON.stringify({ session, messages }, null, 2));
  }

  getSession(userId: string, sessionId: string): Session | undefined {
    const path = this.getSessionPath(userId, sessionId);
    if (!existsSync(path)) return undefined;

    try {
      const data = JSON.parse(readFileSync(path, "utf-8"));
      return data.session;
    } catch {
      return undefined;
    }
  }

  listUserSessions(userId: string): Session[] {
    const userDir = join(this.sessionsDir, userId);
    if (!existsSync(userDir)) return [];

    const sessions: Session[] = [];
    
    for (const file of readdirSync(userDir)) {
      if (!file.endsWith(".json")) continue;
      
      try {
        const data = JSON.parse(readFileSync(join(userDir, file), "utf-8"));
        if (data.session) {
          sessions.push(data.session);
        }
      } catch {}
    }

    // Sort by last activity (most recent first)
    return sessions.sort((a, b) => b.lastActivity - a.lastActivity);
  }

  getSessionMessages(userId: string, sessionId: string): SessionMessage[] {
    const path = this.getSessionPath(userId, sessionId);
    if (!existsSync(path)) return [];

    try {
      const data = JSON.parse(readFileSync(path, "utf-8"));
      return data.messages || [];
    } catch {
      return [];
    }
  }

  addSessionMessage(userId: string, sessionId: string, message: Omit<SessionMessage, "id" | "sessionId">): SessionMessage {
    const path = this.getSessionPath(userId, sessionId);
    
    let data = { session: null as Session | null, messages: [] as SessionMessage[] };
    if (existsSync(path)) {
      try {
        data = JSON.parse(readFileSync(path, "utf-8"));
      } catch {}
    }

    const fullMessage: SessionMessage = {
      ...message,
      id: nanoid(8),
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

    writeFileSync(path, JSON.stringify(data, null, 2));
    return fullMessage;
  }

  deleteSession(userId: string, sessionId: string): boolean {
    const path = this.getSessionPath(userId, sessionId);
    if (!existsSync(path)) return false;
    
    rmSync(path);
    return true;
  }

  // ─── Helpers ───

  getDataDir(): string {
    return this.dataDir;
  }
}
