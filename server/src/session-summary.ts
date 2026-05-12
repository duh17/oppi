import { isAbsolute } from "node:path";

import type { Session, SessionSummary, SessionSummaryChangeStats } from "./types.js";

/**
 * Build the mobile/session-list projection for a Session.
 *
 * This intentionally excludes runtime-only trace paths and other heavy or
 * non-list fields. Live timeline events should not force a full Session
 * snapshot through the workspace list path.
 */
export function buildSessionSummary(session: Session): SessionSummary {
  return {
    id: session.id,
    workspaceId: session.workspaceId,
    workspaceName: session.workspaceName,
    name: session.name,
    status: session.status,
    createdAt: session.createdAt,
    lastActivity: session.lastActivity,
    lastAgentReplyAt: session.lastAgentReplyAt,
    currentTurnStartedAt: session.currentTurnStartedAt,
    model: session.model,
    messageCount: session.messageCount,
    tokens: { ...session.tokens },
    cost: session.cost,
    changeStats: buildSessionSummaryChangeStats(session.changeStats),
    contextTokens: session.contextTokens,
    contextWindow: session.contextWindow,
    firstMessage: session.firstMessage,
    lastMessage: session.lastMessage,
    thinkingLevel: session.thinkingLevel,
    ephemeral: session.ephemeral,
    parentSessionId: session.parentSessionId,
  };
}

function buildSessionSummaryChangeStats(
  stats: Session["changeStats"],
): SessionSummaryChangeStats | undefined {
  if (!stats) {
    return undefined;
  }

  const changedFiles = stats.changedFiles.filter(isSummarySafeChangedFile);
  const changedFilesOverflow = Math.max(
    stats.changedFilesOverflow ?? 0,
    stats.filesChanged - changedFiles.length,
    0,
  );

  return {
    mutatingToolCalls: stats.mutatingToolCalls,
    ...(stats.compactionCount && stats.compactionCount > 0
      ? { compactionCount: stats.compactionCount }
      : {}),
    filesChanged: stats.filesChanged,
    changedFiles,
    ...(changedFilesOverflow > 0 ? { changedFilesOverflow } : {}),
    addedLines: stats.addedLines,
    removedLines: stats.removedLines,
  };
}

function isSummarySafeChangedFile(file: string): boolean {
  const trimmed = file.trim();
  return trimmed.length > 0 && !isAbsolute(trimmed) && !trimmed.startsWith("~");
}

/** Stable digest used to suppress no-op summary fanout. */
export function sessionSummaryFingerprint(summary: SessionSummary): string {
  return JSON.stringify(summary);
}
