import { parsePiStateSnapshot, type PiStateSnapshot } from "./pi-events.js";
import type { SdkBackend } from "./sdk-backend.js";
import type { Storage } from "./storage.js";
import type { Session, ServerMessage } from "./types.js";
import { ts } from "./log-utils.js";

export interface SessionStateActiveSession {
  session: Session;
  sdkBackend: SdkBackend;
}

export interface SessionStateCoordinatorDeps {
  storage: Storage;
  getContextWindowResolver: () => ((modelId: string) => number) | null;
  sendCommandAsync: (key: string, command: Record<string, unknown>) => Promise<unknown>;
  persistSessionNow: (key: string, session: Session) => void;
  broadcast: (key: string, message: ServerMessage) => void;
}

/**
 * Compose a canonical `provider/modelId` string.
 *
 * Handles nested providers like openrouter where the model ID itself
 * contains slashes (e.g. provider="openrouter", modelId="z.ai/glm-5"
 * → "openrouter/z.ai/glm-5").  Avoids double-prefixing when the
 * model ID already starts with the provider name.
 */
export function composeModelId(provider: string, modelId: string): string {
  return modelId.startsWith(`${provider}/`) ? modelId : `${provider}/${modelId}`;
}

export class SessionStateCoordinator {
  constructor(private readonly deps: SessionStateCoordinatorDeps) {}

  async bootstrapSessionState(key: string, active: SessionStateActiveSession): Promise<void> {
    try {
      const snapshot = active.sdkBackend.getStateSnapshot();
      if (this.applyPiStateSnapshot(active.session, snapshot)) {
        this.deps.persistSessionNow(key, active.session);
      }

      await this.applyRememberedThinkingLevel(key, active);
    } catch {
      // Non-fatal; history remains recoverable from pi trace metadata/files.
    }
  }

  async refreshSessionState(
    key: string,
    active: SessionStateActiveSession,
  ): Promise<{ sessionFile?: string; sessionId?: string } | null> {
    try {
      const snapshot = active.sdkBackend.getStateSnapshot();
      if (this.applyPiStateSnapshot(active.session, snapshot)) {
        this.deps.persistSessionNow(key, active.session);
      }
      return {
        sessionFile: active.session.piSessionFile,
        sessionId: active.session.piSessionId,
      };
    } catch {
      return null;
    }
  }

  getRememberedThinkingLevel(modelId: string | undefined): string | undefined {
    const normalizedModelId = modelId?.trim();
    if (!normalizedModelId) {
      return undefined;
    }

    return this.deps.storage.getModelThinkingLevelPreference(normalizedModelId);
  }

  persistThinkingPreference(session: Session): void {
    const modelId = session.model?.trim();
    const level = session.thinkingLevel?.trim();
    if (!modelId || !level) {
      return;
    }

    this.deps.storage.setModelThinkingLevelPreference(modelId, level);
  }

  /**
   * Persist the last-used model on the workspace so new sessions
   * default to it (sticky model per workspace).
   */
  persistWorkspaceLastUsedModel(session: Session): void {
    const model = session.model?.trim();
    if (!model || !session.workspaceId) return;

    const workspace = this.deps.storage.getWorkspace(session.workspaceId);
    if (!workspace || workspace.lastUsedModel === model) return;

    workspace.lastUsedModel = model;
    workspace.updatedAt = Date.now();
    this.deps.storage.saveWorkspace(workspace);
  }

  async applyRememberedThinkingLevel(
    key: string,
    active: SessionStateActiveSession,
  ): Promise<boolean> {
    const preferred = this.getRememberedThinkingLevel(active.session.model);
    if (!preferred) {
      return false;
    }

    if (active.session.thinkingLevel === preferred) {
      return false;
    }

    try {
      await this.deps.sendCommandAsync(key, { type: "set_thinking_level", level: preferred });

      try {
        const state = await this.deps.sendCommandAsync(key, { type: "get_state" });
        const snapshot = parsePiStateSnapshot(state);
        if (snapshot && this.applyPiStateSnapshot(active.session, snapshot)) {
          this.deps.persistSessionNow(key, active.session);
        }
      } catch {
        active.session.thinkingLevel = preferred;
        this.deps.persistSessionNow(key, active.session);
      }

      this.persistThinkingPreference(active.session);

      // Broadcast corrected session so iOS subscribers see the restored level.
      this.deps.broadcast(key, { type: "state", session: active.session });

      return true;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      console.warn(
        `${ts()} [session:${active.session.id}] failed to apply remembered thinking level: ${message}`,
      );
      return false;
    }
  }

  /**
   * Apply fields we care about from pi `get_state` response payload.
   * Returns true if the session object changed.
   */
  applyPiStateSnapshot(session: Session, state: PiStateSnapshot | null | undefined): boolean {
    if (!state) {
      return false;
    }

    let changed = false;

    if (typeof state.sessionFile === "string" && state.sessionFile.length > 0) {
      if (session.piSessionFile !== state.sessionFile) {
        session.piSessionFile = state.sessionFile;
        changed = true;
      }

      const knownFiles = new Set(session.piSessionFiles || []);
      if (!knownFiles.has(state.sessionFile)) {
        session.piSessionFiles = [...knownFiles, state.sessionFile];
        changed = true;
      }
    }

    if (typeof state.sessionId === "string" && state.sessionId.length > 0) {
      if (session.piSessionId !== state.sessionId) {
        session.piSessionId = state.sessionId;
        changed = true;
      }
    }

    if (typeof state.sessionName === "string") {
      const nextName = state.sessionName.trim();
      if (nextName.length > 0 && session.name !== nextName) {
        session.name = nextName;
        changed = true;
      }
    }

    const rawModelId = state.model?.id;
    const rawProvider = state.model?.provider;
    const fullModelId =
      typeof rawProvider === "string" && typeof rawModelId === "string"
        ? composeModelId(rawProvider, rawModelId)
        : rawModelId;
    if (typeof fullModelId === "string" && fullModelId.length > 0) {
      let effectiveModelId = fullModelId;
      const contextWindowResolver = this.deps.getContextWindowResolver();
      if (contextWindowResolver && typeof session.model === "string" && session.model.length > 0) {
        const candidateWindow = contextWindowResolver(fullModelId);
        const existingWindow = contextWindowResolver(session.model);

        // Guard against malformed SDK model payloads (e.g. provider/model both
        // reported as display labels) that would downgrade a known non-200k
        // model back to fallback 200k on reconnect.
        if (candidateWindow === 200000 && existingWindow !== 200000) {
          effectiveModelId = session.model;
        }
      }

      if (session.model !== effectiveModelId) {
        session.model = effectiveModelId;
        this.persistWorkspaceLastUsedModel(session);
        changed = true;
      }

      if (contextWindowResolver) {
        const resolved = contextWindowResolver(effectiveModelId);
        const current = session.contextWindow;
        if (
          current !== resolved &&
          (resolved !== 200000 || !current || current <= 0 || current === 200000)
        ) {
          session.contextWindow = resolved;
          changed = true;
        }
      }
    }

    const observedThinkingLevel =
      typeof state.thinkingLevel === "string" && state.thinkingLevel.trim().length > 0
        ? state.thinkingLevel.trim()
        : undefined;

    if (observedThinkingLevel && observedThinkingLevel !== session.thinkingLevel) {
      session.thinkingLevel = observedThinkingLevel;
      changed = true;
    }

    // NOTE: Do NOT persist thinking preference here. This method is called
    // during bootstrap (get_state) when pi reports its factory-default level.
    // Persisting would clobber the user's real preference with the default,
    // making applyRememberedThinkingLevel a permanent no-op.
    // Callers that handle user-initiated changes (forwardClientCommand for
    // set_thinking_level/cycle_thinking_level/cycle_model) persist explicitly.

    return changed;
  }
}
