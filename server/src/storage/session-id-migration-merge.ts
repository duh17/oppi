/**
 * Field-authority duplicate merge rule (2026-08-17).
 *
 * Inventory never applies this automatically and never selects a survivor.
 * A caller may compute dispositions from this rule and pass them into the
 * planner. If a later executor merges rows, it must preserve these fields.
 *
 * Survivor selection:
 * 1. Every member must share one current Pi UUID.
 * 2. Prefer the unique member whose piSessionFile is the current identity's
 *    canonical file. If every member shares that file, this does not break ties.
 * 3. Prefer latest lastActivity (newest projection).
 * 4. Tie-break by earliest createdAt, then lexicographic sourceRowId.
 *
 * Field merge authority:
 * - identity: the shared current Pi UUID
 * - createdAt: earliest
 * - lastActivity: latest
 * - lastAgentReplyAt: latest present value
 * - piSessionFile: the agreed current canonical file
 * - piSessionFiles / warnings: unique union, deterministic sort
 * - name: latest-activity nonempty name, else any nonempty name in survivor order
 * - messageCount: maximum across members
 * - workspaceId / worktreeId / runtime: latest-activity present value
 *
 * Fail closed when members disagree on the current Pi UUID, the current file,
 * or nonempty workspace/worktree/runtime values.
 */

import type { SessionIdMigrationDuplicateDispositionInput } from "./session-id-migration-planner.js";

export const FIELD_AUTHORITY_DUPLICATE_REASON_ID =
  "field-authority:current-pi-identity,earliest-createdAt,latest-activity,unique-files-warnings" as const;

export interface SessionIdMigrationMergeMember {
  sourceRowId: string;
  targetSessionId: string;
  createdAt: number;
  lastActivity: number;
  lastAgentReplyAt?: number;
  name?: string;
  messageCount?: number;
  piSessionFile?: string;
  piSessionFiles?: readonly string[];
  warnings?: readonly string[];
  workspaceId?: string;
  worktreeId?: string;
  runtime?: string;
}

export interface SessionIdMigrationMergedFields {
  targetSessionId: string;
  createdAt: number;
  lastActivity: number;
  lastAgentReplyAt?: number;
  name?: string;
  messageCount?: number;
  piSessionFile?: string;
  piSessionFiles: string[];
  warnings: string[];
  workspaceId?: string;
  worktreeId?: string;
  runtime?: string;
}

export type SessionIdMigrationFieldAuthorityMergeResult =
  | {
      ok: true;
      disposition: SessionIdMigrationDuplicateDispositionInput;
      merged: SessionIdMigrationMergedFields;
    }
  | { ok: false; detail: string };

export function decideFieldAuthorityDuplicateMerge(
  members: readonly SessionIdMigrationMergeMember[],
  decisionId: string,
): SessionIdMigrationFieldAuthorityMergeResult {
  if (members.length < 2) {
    return { ok: false, detail: "field-authority merge requires at least two members" };
  }
  if (!decisionId.trim()) {
    return { ok: false, detail: "decisionId must be present" };
  }

  const targetSessionId = members[0]?.targetSessionId;
  if (!targetSessionId || members.some((member) => member.targetSessionId !== targetSessionId)) {
    return { ok: false, detail: "members must share one current Pi UUID" };
  }
  if (new Set(members.map((member) => member.sourceRowId)).size !== members.length) {
    return { ok: false, detail: "member sourceRowId values must be unique" };
  }

  const currentFiles = uniquePresent(members.map((member) => member.piSessionFile));
  if (currentFiles.length > 1) {
    return { ok: false, detail: "members disagree on the current canonical Pi file" };
  }
  const workspaceIds = uniquePresent(members.map((member) => member.workspaceId));
  if (workspaceIds.length > 1) {
    return { ok: false, detail: "members disagree on nonempty workspaceId" };
  }
  const worktreeIds = uniquePresent(members.map((member) => member.worktreeId));
  if (worktreeIds.length > 1) {
    return { ok: false, detail: "members disagree on nonempty worktreeId" };
  }
  const runtimes = uniquePresent(members.map((member) => member.runtime));
  if (runtimes.length > 1) {
    return { ok: false, detail: "members disagree on nonempty runtime" };
  }

  const canonicalFile = currentFiles[0];
  const holdersOfCanonicalFile = canonicalFile
    ? members.filter((member) => member.piSessionFile === canonicalFile)
    : members;
  const uniqueCanonicalHolder =
    holdersOfCanonicalFile.length === 1 ? holdersOfCanonicalFile[0] : undefined;

  const ordered = [...members].sort((left, right) => {
    if (uniqueCanonicalHolder) {
      if (left.sourceRowId === uniqueCanonicalHolder.sourceRowId) return -1;
      if (right.sourceRowId === uniqueCanonicalHolder.sourceRowId) return 1;
    }
    return (
      right.lastActivity - left.lastActivity ||
      left.createdAt - right.createdAt ||
      compareDeterministic(left.sourceRowId, right.sourceRowId)
    );
  });
  const survivor = ordered[0];
  if (!survivor) {
    return { ok: false, detail: "no survivor could be selected" };
  }

  const createdAt = Math.min(...members.map((member) => member.createdAt));
  const lastActivity = Math.max(...members.map((member) => member.lastActivity));
  const replyTimes = members.flatMap((member) =>
    member.lastAgentReplyAt === undefined ? [] : [member.lastAgentReplyAt],
  );
  const name =
    ordered.find((member) => member.name?.trim())?.name ??
    members.find((member) => member.name?.trim())?.name;
  const messageCounts = members.flatMap((member) =>
    member.messageCount === undefined ? [] : [member.messageCount],
  );

  return {
    ok: true,
    disposition: {
      targetSessionId,
      survivorSourceRowId: survivor.sourceRowId,
      decisionId,
      reasonId: FIELD_AUTHORITY_DUPLICATE_REASON_ID,
    },
    merged: {
      targetSessionId,
      createdAt,
      lastActivity,
      ...(replyTimes.length > 0 ? { lastAgentReplyAt: Math.max(...replyTimes) } : {}),
      ...(name ? { name } : {}),
      ...(messageCounts.length > 0 ? { messageCount: Math.max(...messageCounts) } : {}),
      ...(canonicalFile ? { piSessionFile: canonicalFile } : {}),
      piSessionFiles: uniqueStrings(members.flatMap((member) => member.piSessionFiles ?? [])),
      warnings: uniqueStrings(members.flatMap((member) => member.warnings ?? [])),
      ...(workspaceIds[0] ? { workspaceId: workspaceIds[0] } : {}),
      ...(worktreeIds[0] ? { worktreeId: worktreeIds[0] } : {}),
      ...(runtimes[0] ? { runtime: runtimes[0] } : {}),
    },
  };
}

function uniquePresent(values: Array<string | undefined>): string[] {
  return uniqueStrings(values.flatMap((value) => (value?.trim() ? [value] : [])));
}

function uniqueStrings(values: readonly string[]): string[] {
  return [...new Set(values)].sort(compareDeterministic);
}

function compareDeterministic(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}
