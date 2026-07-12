/**
 * Model catalog — SDK model resolution and context window management.
 *
 * Wraps the pi SDK ModelRegistry to provide:
 * - Model ID → context window resolution (tolerant matching)
 * - Session context window healing (stale fallback repair)
 * - REST-friendly model list for iOS picker
 */

import type { ModelRegistry } from "@earendil-works/pi-coding-agent";
import type { Storage } from "./storage.js";
import type { Session } from "./types.js";
import { createLogger } from "./logger.js";
import {
  modelCandidatesFromRegistry,
  type ModelAuthKind,
  type ModelResolutionCandidate,
} from "./model-resolution.js";

// ─── Types ───

const log = createLogger({ base: { component: "model_catalog" } });

export interface ModelInfo {
  id: string;
  name: string;
  provider: string;
  contextWindow?: number;
  authKind?: ModelAuthKind;
}

type ModelAllowlist = string[] | (() => string[] | undefined);

// ─── Helpers ───

/** Normalize model labels/IDs for tolerant matching (e.g. "GPT-5.3 Codex" ~= "gpt-5.3-codex"). */
function normalizeModelToken(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]/g, "");
}

function candidateToModelInfo(candidate: ModelResolutionCandidate): ModelInfo {
  return {
    id: candidate.canonicalId,
    name: candidate.name,
    provider: candidate.provider,
    contextWindow: candidate.contextWindow || 200000,
    ...(candidate.authKind ? { authKind: candidate.authKind } : {}),
  };
}

// ─── ModelCatalog ───

export class ModelCatalog {
  private catalog: ModelInfo[] = [];
  private updatedAt = 0;
  constructor(
    private registry: ModelRegistry,
    private storage: Storage,
    private allowlist?: ModelAllowlist,
  ) {}

  private getAllowlist(): string[] | undefined {
    return typeof this.allowlist === "function" ? this.allowlist() : this.allowlist;
  }

  /** Refresh the model catalog from the SDK registry. */
  refresh(): void {
    try {
      this.registry.refresh();
      this.catalog = modelCandidatesFromRegistry(this.registry, this.getAllowlist()).map(
        candidateToModelInfo,
      );
      this.updatedAt = Date.now();

      if (this.catalog.length > 0) {
        return;
      }

      const allCount = this.registry.getAll().length;
      if (allCount > 0) {
        log.warn("models.no_authenticated_models_available", {
          hiddenModelCount: allCount,
        });
        return;
      }

      log.warn("models.registry_returned_zero", { availableModelCount: 0 });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      log.warn("models.refresh.failed", { error: message });
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
      log.info("models.context_windows.healed", {
        healedCount,
      });
    }
  }
}
