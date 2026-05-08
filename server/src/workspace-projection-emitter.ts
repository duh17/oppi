import { createLogger } from "./logger.js";
import { buildSessionSummary, sessionSummaryFingerprint } from "./session-summary.js";
import type { WorkspaceStreamMux } from "./stream.js";
import type { Session } from "./types.js";

const log = createLogger({ base: { component: "workspace_projection_emitter" } });

/**
 * Emits cold, workspace-scoped session-list projections.
 *
 * This is deliberately separate from the legacy /stream subscription path:
 * workspace streams get idempotent SessionSummary projections, never full hot
 * timeline state.
 */
export class WorkspaceProjectionEmitter {
  private readonly lastFingerprintBySession = new Map<string, string>();

  constructor(private readonly workspaceStreamMux: WorkspaceStreamMux) {}

  emitSessionProjection(session: Session, reason: string): boolean {
    if (!session.workspaceId) {
      return false;
    }

    const summary = buildSessionSummary(session);
    const fingerprint = sessionSummaryFingerprint(summary);
    if (this.lastFingerprintBySession.get(session.id) === fingerprint) {
      log.debug("workspace_projection.skipped", {
        sessionId: session.id,
        workspaceId: session.workspaceId,
        reason,
      });
      return false;
    }

    this.lastFingerprintBySession.set(session.id, fingerprint);
    this.workspaceStreamMux.recordAndFanOutWorkspaceEvent(session.workspaceId, {
      type: "session_projection",
      summary,
      sessionId: session.id,
    });

    log.debug("workspace_projection.emitted", {
      sessionId: session.id,
      workspaceId: session.workspaceId,
      reason,
    });
    return true;
  }

  emitSessionDeleted(workspaceId: string, sessionId: string): void {
    this.lastFingerprintBySession.delete(sessionId);
    this.workspaceStreamMux.recordAndFanOutWorkspaceEvent(workspaceId, {
      type: "session_deleted",
      sessionId,
    });
  }
}
