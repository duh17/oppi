/**
 * Model catalog — SDK model resolution and context window management.
 *
 * Wraps the pi SDK ModelRegistry to provide:
 * - Model ID → context window resolution (tolerant matching)
 * - Session context window healing (stale fallback repair)
 * - REST-friendly model list for iOS picker
 */

import type { ModelRegistry } from "@mariozechner/pi-coding-agent";
import type { Storage } from "./storage.js";
import type { Session } from "./types.js";
import { ts } from "./log-utils.js";

// ─── Types ───

export interface ModelInfo {
  id: string;
  name: string;
  provider: string;
  contextWindow?: number;
}

// ─── Helpers ───

/** Normalize model labels/IDs for tolerant matching (e.g. "GPT-5.3 Codex" ~= "gpt-5.3-codex"). */
function normalizeModelToken(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]/g, "");
}

/**
 * Map SDK Model objects to the simplified ModelInfo shape for REST responses.
 * Deduplicates by canonical `provider/modelId`.
 */
function sdkModelsToModelInfo(
  sdkModels: Array<{ id: string; name: string; provider: string; contextWindow: number }>,
): ModelInfo[] {
  const seen = new Set<string>();
  const result: ModelInfo[] = [];
  for (const m of sdkModels) {
    const id = `${m.provider}/${m.id}`;
    if (seen.has(id)) continue;
    seen.add(id);
    result.push({
      id,
      name: m.name || m.id,
      provider: m.provider,
      contextWindow: m.contextWindow || 200000,
    });
  }
  return result;
}

// ─── ModelCatalog ───

export class ModelCatalog {
  private catalog: ModelInfo[] = [];
  private updatedAt = 0;

  constructor(
    private registry: ModelRegistry,
    private storage: Storage,
  ) {}

  /** Refresh the model catalog from the SDK registry. */
  refresh(): void {
    try {
      this.registry.refresh();
      const available = this.registry.getAvailable();
      if (available.length > 0) {
        this.catalog = sdkModelsToModelInfo(available);
        this.updatedAt = Date.now();
        return;
      }

      // Fall back to all registered models (includes those without auth)
      const all = this.registry.getAll();
      if (all.length > 0) {
        this.catalog = sdkModelsToModelInfo(all);
        this.updatedAt = Date.now();
        return;
      }

      console.warn(`${ts()} [models] SDK ModelRegistry returned 0 models`);
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      console.warn(`${ts()} [models] failed to refresh model catalog: ${message}`);
    }
  }

  /** Return the current model catalog. */
  getAll(): ModelInfo[] {
    return this.catalog;
  }

  /** Timestamp of the last successful refresh. */
  getUpdatedAt(): number {
    return this.updatedAt;
  }

  /**
   * Resolve the context window size for a model ID.
   *
   * Uses tolerant matching: exact ID, tail segment, normalized tokens.
   * Falls back to parsing "...NNNk" suffixes, then 200k default.
   */
  getContextWindow(modelId: string): number {
    const trimmed = modelId.trim();
    const tail = trimmed.includes("/") ? trimmed.substring(trimmed.lastIndexOf("/") + 1) : trimmed;

    const candidates = new Set<string>([trimmed, tail].filter((v) => v.length > 0));
    const normalizedCandidates = new Set(
      Array.from(candidates)
        .map((v) => normalizeModelToken(v))
        .filter((v) => v.length > 0),
    );

    const known = this.catalog.find((m) => {
      if (candidates.has(m.id) || candidates.has(m.name)) {
        return true;
      }

      for (const candidate of candidates) {
        if (m.id.endsWith(`/${candidate}`)) {
          return true;
        }
      }

      const normalizedId = normalizeModelToken(m.id);
      const normalizedName = normalizeModelToken(m.name);
      const normalizedTail = normalizeModelToken(m.id.substring(m.id.lastIndexOf("/") + 1));

      for (const candidate of normalizedCandidates) {
        if (
          candidate === normalizedId ||
          candidate === normalizedName ||
          candidate === normalizedTail
        ) {
          return true;
        }
      }

      return false;
    })?.contextWindow;

    if (known) {
      return known;
    }

    // Generic model-id fallback, e.g. "...-272k" / "..._128k".
    const match = trimmed.match(/(\d{2,4})k\b/i);
    if (match) {
      const thousands = Number.parseInt(match[1], 10);
      if (Number.isFinite(thousands) && thousands > 0) {
        return thousands * 1000;
      }
    }

    return 200000;
  }

  /**
   * Ensure a session has a valid context window value.
   * Persists the fix if the value changed.
   */
  ensureSessionContextWindow(session: Session): Session {
    let changed = false;

    const resolved = this.getContextWindow(session.model || "");
    const current = session.contextWindow;

    if (!current || current <= 0) {
      session.contextWindow = resolved;
      changed = true;
    } else if (current !== resolved && current === 200000) {
      // Heal stale fallback values after model-ID normalization fixes.
      session.contextWindow = resolved;
      changed = true;
    }

    if (changed) {
      this.storage.saveSession(session);
    }

    return session;
  }

  /**
   * Heal stale context window fallbacks across all persisted sessions.
   * Called once at startup before clients connect.
   */
  healPersistedSessionContextWindows(): void {
    const sessions = this.storage.listSessions();
    let healedCount = 0;

    for (const session of sessions) {
      const before = session.contextWindow;
      this.ensureSessionContextWindow(session);
      if (session.contextWindow !== before) {
        healedCount += 1;
      }
    }

    if (healedCount > 0) {
      console.log(
        `${ts()} [models] healed context windows for ${healedCount} persisted session(s)`,
      );
    }
  }
}
