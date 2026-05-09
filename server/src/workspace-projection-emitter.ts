import { createLogger } from "./logger.js";
import { buildSessionSummary, sessionSummaryFingerprint } from "./session-summary.js";
import type { WorkspaceStreamMux } from "./stream.js";
import type { Session } from "./types.js";

const log = createLogger({ base: { component: "workspace_projection_emitter" } });

/**
 * Emits cold, workspace-scoped session-list projections.
 *
 * This is deliberately separate from focused session streams:
 * workspace streams get idempotent SessionSummary projections, never full hot
 * timeline state.
 */
export class WorkspaceProjectionEmitter {
  private readonly lastFingerprintBySession = new Map<string, string>();
  private readonly lastEmitMsBySession = new Map<string, number>();
  private readonly pendingBySession = new Map<
    string,
    { session: Session; reason: string; timer: ReturnType<typeof setTimeout> }
  >();
  private readonly minIntervalMs: number;

  constructor(
    private readonly workspaceStreamMux: WorkspaceStreamMux,
    options: { minIntervalMs?: number } = {},
  ) {
    this.minIntervalMs = options.minIntervalMs ?? 2500;
  }

  emitSessionProjection(session: Session, reason: string): boolean {
    this.clearPendingProjection(session.id);
    return this.emitSessionProjectionNow(session, reason);
  }

  scheduleSessionProjection(session: Session, reason: string): boolean {
    if (!session.workspaceId) {
      return false;
    }

    const lastEmitMs = this.lastEmitMsBySession.get(session.id) ?? 0;
    const elapsedMs = Date.now() - lastEmitMs;
    if (elapsedMs >= this.minIntervalMs) {
      return this.emitSessionProjection(session, reason);
    }

    const existing = this.pendingBySession.get(session.id);
    if (existing) {
      existing.session = session;
      existing.reason = reason;
      return true;
    }

    const timer = setTimeout(
      () => {
        const pending = this.pendingBySession.get(session.id);
        if (!pending) return;
        this.pendingBySession.delete(session.id);
        this.emitSessionProjectionNow(pending.session, pending.reason);
      },
      Math.max(this.minIntervalMs - elapsedMs, 1),
    );
    (timer as ReturnType<typeof setTimeout> & { unref?: () => void }).unref?.();

    this.pendingBySession.set(session.id, { session, reason, timer });
    return true;
  }

  emitSessionDeleted(workspaceId: string, sessionId: string): void {
    this.clearPendingProjection(sessionId);
    this.lastFingerprintBySession.delete(sessionId);
    this.lastEmitMsBySession.delete(sessionId);
    this.workspaceStreamMux.recordAndFanOutWorkspaceEvent(workspaceId, {
      type: "session_deleted",
      sessionId,
    });
  }

  private emitSessionProjectionNow(session: Session, reason: string): boolean {
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
    this.lastEmitMsBySession.set(session.id, Date.now());
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

  private clearPendingProjection(sessionId: string): void {
    const pending = this.pendingBySession.get(sessionId);
    if (!pending) return;
    clearTimeout(pending.timer);
    this.pendingBySession.delete(sessionId);
  }
}
