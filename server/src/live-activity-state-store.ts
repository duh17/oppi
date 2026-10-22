import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { randomUUID } from "node:crypto";

import { createLogger } from "./logger.js";
import { safeErrorMessage } from "./log-utils.js";

const log = createLogger({ base: { component: "live_activity" } });

const STORE_VERSION = 1;

/** A card this server believes is up on a device. */
export interface PersistedCard {
  activity: "live" | "unknown";
  /** The earliest the card can have started (epoch ms); its 8-hour restart counts from here. */
  startedAt: number;
}

/** Where `LiveActivityNotifier` keeps its cards across a server restart. */
export interface LiveActivityStateStore {
  /** Never throws: a missing, unreadable, or malformed file is no state. */
  load(): Map<string, PersistedCard>;
  save(cards: ReadonlyMap<string, PersistedCard>): void;
}

export function liveActivityStatePath(dataDir: string): string {
  return join(dataDir, "live-activity-state.json");
}

/**
 * The cards `LiveActivityNotifier` believes are up, as a small JSON file in the data directory
 * (not `config.json`). A restarted server reads it to keep updating a card instead of ending
 * and restarting it, which shows Apple's "Agents are working." alert on the phone.
 */
export class FileLiveActivityStateStore implements LiveActivityStateStore {
  constructor(private readonly path: string) {}

  load(): Map<string, PersistedCard> {
    const cards = new Map<string, PersistedCard>();
    let parsed: unknown;
    try {
      parsed = JSON.parse(readFileSync(this.path, "utf8"));
    } catch (err: unknown) {
      if ((err as NodeJS.ErrnoException).code !== "ENOENT") {
        log.warn("live_activity.state_unreadable", { error: safeErrorMessage(err) });
      }
      return cards;
    }
    const record = parsed as { version?: unknown; cards?: unknown } | null;
    if (
      !record ||
      typeof record !== "object" ||
      record.version !== STORE_VERSION ||
      !record.cards ||
      typeof record.cards !== "object" ||
      Array.isArray(record.cards)
    ) {
      log.warn("live_activity.state_unreadable", { error: "unexpected shape" });
      return cards;
    }
    for (const [deviceId, value] of Object.entries(record.cards)) {
      const card = value as Partial<PersistedCard> | null;
      if (
        card &&
        (card.activity === "live" || card.activity === "unknown") &&
        typeof card.startedAt === "number" &&
        Number.isFinite(card.startedAt)
      ) {
        cards.set(deviceId, { activity: card.activity, startedAt: card.startedAt });
      }
    }
    return cards;
  }

  /** Write to a temporary file and rename it over the old one, so a crash leaves one whole file. */
  save(cards: ReadonlyMap<string, PersistedCard>): void {
    mkdirSync(dirname(this.path), { recursive: true, mode: 0o700 });
    const payload = `${JSON.stringify({ version: STORE_VERSION, cards: Object.fromEntries(cards) })}\n`;
    const temporaryPath = `${this.path}.${process.pid}.${randomUUID()}.tmp`;
    writeFileSync(temporaryPath, payload, { mode: 0o600, flag: "wx", flush: true });
    try {
      renameSync(temporaryPath, this.path);
    } finally {
      rmSync(temporaryPath, { force: true });
    }
  }
}
