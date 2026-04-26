import type { PiStateSnapshot } from "./pi-events.js";
import type { SdkBackend } from "./sdk-backend.js";
import type { Storage } from "./storage.js";
import type { Session } from "./types.js";

export interface SessionStateActiveSession {
  session: Session;
  sdkBackend: SdkBackend;
}

export interface SessionStateCoordinatorDeps {
  storage: Storage;
  getContextWindowResolver: () => ((modelId: string) => number) | null;
  persistSessionNow: (key: string, session: Session) => void;
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
    } catch {
      // Non-fatal; history remains recoverable from pi trace metadata/files.
    }
  }

  async refreshSessionState(
    key: string,
    active: SessionStateActiveSession,
  ): Promise<{ sessionFile?: string; sessionId?: string; leafId?: string | null } | null> {
    try {
      const snapshot = active.sdkBackend.getStateSnapshot();
      if (this.applyPiStateSnapshot(active.session, snapshot)) {
        this.deps.persistSessionNow(key, active.session);
      }
      return {
        sessionFile: active.session.piSessionFile,
        sessionId: active.session.piSessionId,
        leafId: active.sdkBackend.session.sessionManager.getLeafId(),
      };
    } catch {
      return null;
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
    } else if (session.ephemeral) {
      if (session.piSessionFile !== undefined) {
        session.piSessionFile = undefined;
        changed = true;
      }
      if ((session.piSessionFiles?.length ?? 0) > 0) {
        session.piSessionFiles = undefined;
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

    // Pi owns thinking defaults and per-session thinking changes. Oppi mirrors
    // the current value on Session only so clients can render the toolbar.

    return changed;
  }
}
