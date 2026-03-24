import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { generateId } from "../id.js";
import type { Session } from "../types.js";
import type { ConfigStore } from "./config-store.js";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export class SessionStore {
  constructor(private readonly configStore: ConfigStore) {}

  private getSessionPath(sessionId: string): string {
    return join(this.configStore.getSessionsDir(), `${sessionId}.json`);
  }

  createSession(name?: string, model?: string): Session {
    const id = generateId(8);

    const session: Session = {
      id,
      name,
      status: "starting",
      createdAt: Date.now(),
      lastActivity: Date.now(),
      model: model || this.configStore.getConfig().defaultModel,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
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

    const payload = JSON.stringify({ session }, null, 2);
    writeFileSync(path, payload, { mode: 0o600 });
  }

  getSession(sessionId: string): Session | undefined {
    const path = this.getSessionPath(sessionId);
    if (!existsSync(path)) return undefined;

    try {
      const raw = JSON.parse(readFileSync(path, "utf-8")) as unknown;
      if (!isRecord(raw)) return undefined;
      const session = raw.session as Session | undefined;
      // Backfill cache token fields for sessions persisted before cacheRead/cacheWrite existed.
      // Type says they exist but on-disk data may lack them — intentional `as` cast for migration.
      if (session?.tokens && !("cacheRead" in session.tokens)) {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const t = session.tokens as any;
        session.tokens = { input: t.input, output: t.output, cacheRead: 0, cacheWrite: 0 };
      }
      return session;
    } catch {
      return undefined;
    }
  }

  listSessions(): Session[] {
    const baseDir = this.configStore.getSessionsDir();
    if (!existsSync(baseDir)) return [];

    const sessions: Session[] = [];

    for (const file of readdirSync(baseDir)) {
      // Only load <sessionId>.json — skip auxiliary files like *.annotations.json
      if (!file.endsWith(".json")) continue;
      if (file.indexOf(".") !== file.length - 5) continue;

      const path = join(baseDir, file);
      try {
        const raw = JSON.parse(readFileSync(path, "utf-8")) as unknown;
        if (!isRecord(raw)) {
          console.error(`[storage] Corrupt session file ${path}, skipping`);
          continue;
        }

        const session = raw.session as Session | undefined;
        if (!session) {
          console.error(`[storage] Corrupt session file ${path}, skipping`);
          continue;
        }

        // Backfill cache token fields for sessions created before cache tracking
        if (session.tokens && !("cacheRead" in session.tokens)) {
          (session.tokens as Record<string, number>).cacheRead = 0;
          (session.tokens as Record<string, number>).cacheWrite = 0;
        }

        sessions.push(session);
      } catch {
        console.error(`[storage] Corrupt session file ${path}, skipping`);
      }
    }

    // Sort by last activity (most recent first)
    return sessions.sort((a, b) => b.lastActivity - a.lastActivity);
  }

  deleteSession(sessionId: string): boolean {
    const path = this.getSessionPath(sessionId);
    if (!existsSync(path)) return false;

    rmSync(path);
    return true;
  }
}
